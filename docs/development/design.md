# Design

## The lock run (`src/pip_purifier.py`)

`pip-purifier lock` starts a package index on localhost (`Proxy`) in front
of the real indexes. `/i/<n>/<path>` serves page `<path>` of upstream index
`n` with every link rewritten to `/f/<url>/<file name>`, and `/f/` serves
the file and records its URL and SHA-256. pip runs with `PIP_INDEX_URL`
pointing at the proxy, so the isolated environments in which it builds
sdists use the proxy too, and their build requirements are recorded.

The lock run then:

1. rewrites the pip arguments and every file they name (`nix/lib/pip_inputs.py`,
   "lock" mode), so index options point at the proxy;
2. runs `pip install --report` into a scratch venv, which resolves,
   downloads and builds everything for this system;
3. records each VCS requirement's commit with the hash nixpkgs' fetcher
   computes, each URL requirement's file, and each git repository that a
   package names in its own metadata, as a clone with `.git`;
4. records the outputs: the programs of the venv, and the sdist and wheel
   of each local project, built with `pip wheel` and `python -m build`;
5. for each other system, resolves with `--platform` and
   `--only-binary=:all:`, and keeps this system's versions when that fails
   (an sdist-only package, or a pylock.toml);
6. for every package version any system uses, fetches a wheel for each
   system's CPU, or the sdist when no such wheel exists.

## The lockfile

`version`, `pip` and `python` identify the lock. `args` are the pip install
arguments. `inputs` maps each file the arguments name (and the
`pyproject.toml`, `setup.py` and `setup.cfg` of each local project) to its
SHA-256; the Nix library and the CLI refuse a lock whose inputs changed.
`pins` holds `name==version` for each system. `versions` holds the version
of each package built from a checkout (by requirement URL) or a local
directory (by path). `outputs` names programs and packages. `sources` maps
each VCS or URL requirement to its download, `repositories` lists the git
repositories named in package metadata, and `artifacts` holds every
download in the entry shapes of the nix-purifiers/purifier library, which
`nix/lib/fetch.nix` fetches until that library is published.

## The offline install (`nix/lib/offline.py`)

The Nix build and `pip-purifier install` both rewrite the recorded
arguments in "offline" mode: index options go away, and each VCS or URL
requirement points at its local copy. pip runs with `--no-index`, the
wheelhouse as find-links, and the pins as constraints.

pip builds a local directory in place, so each checkout is copied to a
writable directory first. The copy, and in the Nix build each local project
without `.git`, becomes a one-commit git repository tagged with the
recorded version, so setuptools-scm and hatch-vcs derive the same version
as in the lock run. A repository named in package metadata is served to the
git that pip runs through `url.<copy>.insteadOf`, with the revision pip
asks for as a tag on the locked commit.
