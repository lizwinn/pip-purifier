# pip-purifier

pip-purifier builds pip projects in the Nix sandbox. `pip-purifier lock`
runs `pip install` once, through a recording package index on localhost,
and writes `pip-purifier.lock.json` beside the project's requirements. The
lockfile records every file pip downloaded, including what the isolated
build environments of sdists downloaded, and every output the project
makes. Nix then builds the project offline from it. You commit the lockfile
and no generated Nix files.

pip-purifier is part of [nix-purifiers](https://nix-purifiers.github.io).

## What a lock covers

pip-purifier records the arguments of `pip install` and runs them as they
are. Without arguments, it uses `-r pylock.toml`, `-r requirements.txt` or
`.`, whichever the project has first. These inputs work:

- requirements files, with nested `-r` and `-c` files, `--hash` pins (as
  pip-compile writes them), environment markers and index options;
- `pylock.toml` files ([PEP 751](https://peps.python.org/pep-0751/)), as
  `pip lock` writes them;
- the dependencies of a script ([PEP 723](https://peps.python.org/pep-0723/)),
  with `--requirements-from-script`;
- local projects, editable or not, inside the project directory or beside
  it;
- requirements from git, Mercurial, Subversion and Bazaar repositories, and
  from URLs of wheels and sdists;
- a repository or URL that another package names as a source in its own
  metadata. pip clones or downloads those itself, so the offline install
  answers it: git through `url.<local clone>.insteadOf`, Mercurial,
  Subversion and Bazaar through stand-in commands that copy the locked
  checkout, and URLs through `mitm-cache replay`, an HTTPS proxy that
  serves the locked files;
- sdists, which pip builds with the build requirements the lock run
  recorded.

The lock run records the versions pip resolved for x86_64-linux and
aarch64-linux, and the wheels each system installs. The index comes from
`PIP_INDEX_URL` and `PIP_EXTRA_INDEX_URL`, from pip's configuration files, or
from the index options of the requirements.

## Use

Run the lock in the project directory, and commit the lockfile:

```zsh
nix run github:nix-purifiers/pip-purifier -- lock
```

A relock keeps the files of the existing lockfile: for each package the
lockfile already has, including the build requirements of sdists, the lock
run offers pip only those files. An unchanged project relocks to the same
file byte for byte, and adding a requirement leaves the other versions
alone. `lock --upgrade` resolves everything afresh. When a changed
requirement needs a version the lockfile does not have, the lock run says so
and resolves afresh.

To lock other arguments, give them after `--`:

```zsh
nix run github:nix-purifiers/pip-purifier -- lock -- -r requirements/prod.txt -e .
```

The flake's `overlays.default` adds `buildPipProject` to a package set:

```nix
{
  inputs.pip-purifier.url = "github:nix-purifiers/pip-purifier";
  inputs.nixpkgs.follows = "pip-purifier/nixpkgs";

  outputs = { nixpkgs, pip-purifier, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ pip-purifier.overlays.default ];
      };
      project = pkgs.buildPipProject { src = ./.; };
    in
    {
      packages.x86_64-linux = {
        default = project.environment;
        greet = project.programs.greet;
        dist = project.packages.greet;
      };
    };
}
```

`buildPipProject` gives:

- `environment`, a virtual environment with everything the recorded
  `pip install` installs, with editable installs made plain;
- `programs.<name>`, each program that environment has, for `nix run`;
- `packages.<name>`, the sdist and wheel of each local project, with their
  file names as `.sdist` and `.wheel`, and their paths under `.files`;
- `inputs`, the locked downloads for this system;
- `check`, when you give `checkPhase`: that command run in a copy of the
  source, with the environment's programs on `PATH`.

The lockfile names every output, so Nix knows them at evaluation time.

`buildPipProject` also takes `python` (its version has to be the one the
lock was made with), `nativeBuildInputs` and `buildInputs` for native
dependencies of sdists, `pathSources` for local projects outside `src`, and
`fetchurl`, which replaces the file fetcher, for credentials or mirrors.

## Working offline

`pip-purifier install` builds the locked downloads with Nix and installs the
project into `.venv` offline, with editable installs left editable.
`pip-purifier pip` runs any pip command offline against the same files:

```zsh
pip-purifier install
pip-purifier pip --python .venv/bin/python list
```

Both refuse to run when the requirements have changed since the lock.

## When something fails

- **"does not match … any more. Run `pip-purifier lock`."** A requirements
  file, pylock.toml, script or `pyproject.toml` changed after the lock.
  Relock.
- **"the lockfile has no file for <name> … run `pip-purifier lock`."** pip
  needs a package the lock run did not see, for example after you added a
  requirement and ran `pip-purifier pip install` before relocking.
- **"hash mismatch in fixed-output derivation"** from Nix. A hash in
  `pip-purifier.lock.json` was edited, or the server now serves different
  bytes under the same URL. Relock, and check the change in review.
- **"is not a pip-purifier lockfile"** or **"has lock format version …"**.
  The lockfile is damaged, or comes from another version of pip-purifier.
  Relock.
- **"was made for Python …"**. Pass `buildPipProject` the `python` of the
  version the lock names, or relock with `--python`.

## Publishing

`pip-purifier publish` uploads the sdist and wheel that Nix built, with
`uv publish`, which accepts the metadata 2.5 that current build backends
write. The arguments after `--` go to `uv publish`, and `--dry-run` checks
the upload without making it:

```zsh
pip-purifier publish -- --publish-url https://test.pypi.org/legacy/
```

## Limits

- **Systems.** A lock covers x86_64-linux and aarch64-linux.
- **One Python version.** The wheels of a lock are those of the Python
  version the lock run used. A build with another version is refused.
- **Credentials.** The lockfile records URLs without their credentials. A
  private index needs a `fetchurl` that supplies them, such as nixpkgs'
  `fetchurl` with `netrcPhase`.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
