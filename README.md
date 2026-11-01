# pip-purifier

pip-purifier builds pip projects in the Nix sandbox. `pip-purifier lock`
runs `pip install` once, through a recording package index on localhost,
and writes `pip-purifier.lock.json`. The lockfile records every file pip
downloaded, including what the isolated build environments of sdists
downloaded, and every output the project makes. Nix then builds the project
offline from it. You commit the lockfile, and no generated Nix files.

pip has no lockfile that records downloads for every system, so
pip-purifier writes its own. Where a project has a `pylock.toml` or a
requirements file with `--hash` pins, those versions are the versions that
pip-purifier locks, and they also constrain the environments in which pip
builds sdists, through pip's `--build-constraint`. The files that a
`pylock.toml` names, with their URLs and hashes, are read from it and not
repeated in `pip-purifier.lock.json`.

pip-purifier is part of [nix-purifiers](https://nix-purifiers.github.io),
and meets the [purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).

## Quickstart

Run the lock in the project directory, and commit the lockfile:

```zsh
nix run github:nix-purifiers/pip-purifier -- lock
```

Without arguments, the lock runs `pip install -r pylock.toml`,
`pip install -r requirements.txt` or `pip install .`, whichever the
project has first. To lock other arguments, give them after `--`:

```zsh
nix run github:nix-purifiers/pip-purifier -- lock -- -r requirements/dev.txt -e .
```

Then build the project with the flake library:

```nix
{
  inputs.pip-purifier.url = "github:nix-purifiers/pip-purifier";
  inputs.nixpkgs.follows = "pip-purifier/nixpkgs";

  outputs = { nixpkgs, pip-purifier, ... }:
    let
      project = pip-purifier.lib.pip-purifier.buildPipProject {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        src = ./.;
      };
    in
    {
      packages.x86_64-linux = {
        default = project.environment;
        greet = project.programs.greet;
        release = project.release;
      };
      checks.x86_64-linux.tests = project.tests;
    };
}
```

`buildPipProject` takes `pkgs` and `src`, and gives:

- `packages.<name>`, the sdist and wheel of each local project, with their
  file names as `.sdist` and `.wheel` and their paths under `.files`;
- `tests`, the project's tests in the sandbox: `checkPhase` when you give
  it, else `pytest` when the environment has it, run in a copy of the
  source with the environment's programs on `PATH`;
- `release`, every sdist and wheel of `packages`, which
  `pip-purifier publish` uploads;
- `fetches`, the download entries of the lock, for SBOM, license and
  vulnerability tools;
- `environment`, a virtual environment with everything the recorded
  `pip install` installs, with editable installs made plain;
- `programs.<name>`, each program of that environment, for `nix run`;
- `inputs`, the locked downloads for this system.

The lockfile names every output, so Nix knows them at evaluation time.

`buildPipProject` also takes `fetchers`, nixpkgs fetchers to use in place of
the defaults, such as a `fetchurl` that sends credentials; `lockFile`, for a
lockfile outside `src`; `python`, whose version has to be the one the lock
was made with; `nativeBuildInputs` and `buildInputs`, for native
dependencies of sdists; `pathSources`, for local projects outside `src`;
and `checkPhase`. `lib.pip-purifier.readLock { src; }` reads the lockfile
into the lock shape that every purifier gives.

## Everyday loop

`pip-purifier prefetch` installs the project into `.venv` offline, with
editable installs left editable. Then work in `.venv` as usual: an edit to
the project's source shows in the next run without a reinstall.

```zsh
pip-purifier prefetch
.venv/bin/pytest
```

`pip-purifier pip` runs any pip command offline against the locked files:

```zsh
pip-purifier pip --python .venv/bin/python list
```

After a change to the requirements, `pip-purifier lock` relocks. A relock
keeps the files of the existing lockfile: for each package that the
lockfile has, including the build requirements of sdists, the lock run
offers pip only those files. An unchanged project relocks to the same file
byte for byte, and adding a requirement leaves the other versions alone.
When a changed requirement needs a version that the lockfile does not have,
the lock run says so and resolves afresh.

`pip-purifier update` resolves every package afresh, and
`pip-purifier update <package>...` resolves only the named ones, with the
`pip install` arguments that the lockfile records. A `pylock.toml` pins
every version itself, so for such a project, run `pip lock` to update it,
then `pip-purifier lock`.

## Offline work

`prefetch` keeps everything the everyday loop needs alive with
garbage-collector roots in `.pip-purifier/`, beside the lockfile: the
locked downloads for this system, and the `pip-purifier` command with its
Python, pip, nixpkgs and purifier library. After a prefetch, `.venv`, the
editor and `pip-purifier pip` work with the network cut off. Keep the
command itself installed, for example in a dev shell, so that it does not
need a download either.

A project can keep its build outside its tree, such as in a packaging flake
for a project whose author does not use pip-purifier. Give the lockfile's
path to each command with `--lockfile`, or set `PIP_PURIFIER_LOCKFILE`, and
pass the same path to `buildPipProject` as `lockFile`:

```zsh
PIP_PURIFIER_LOCKFILE=../packaging/pip-purifier.lock.json pip-purifier lock
```

## Editor

Point the editor at `.venv`, as for any virtual environment. For pyright
and basedpyright, `prefetch` makes `.venv` in the project root, where they
look for it by default. The packages in `.venv` hold their sources, so
go-to-definition and type information work offline. The language server
itself comes from your editor setup, such as nixpkgs' `pyright`.

## Errors and fixes

- **"does not match … any more. Run `pip-purifier lock`."** A requirements
  file, `pylock.toml`, script or `pyproject.toml` changed after the lock.
  Relock.
- **"was changed after `pip-purifier lock` wrote it"**. The lockfile holds
  a hash of its own content, and an edit by hand changed the content.
  Relock, and check the change in review.
- **"is not a pip-purifier lockfile"**, **"is not valid JSON"** or **"has
  lock format version …"**. The lockfile is damaged, or comes from another
  version of pip-purifier. Relock.
- **"the lockfile has no file for <name> … run `pip-purifier lock`."** pip
  needs a package that the lock run did not see, for example after you
  added a requirement and ran `pip-purifier pip install` before relocking.
- **"hash mismatch in fixed-output derivation"** from Nix. The server now
  serves different bytes under a locked URL. Relock, and check the change
  in review.
- **"was made for Python …"**. Pass `buildPipProject` the `python` of the
  version that the lock names, or relock with `--python`.
- **"has no lock for <system>"**. The lock covers x86_64-linux and
  aarch64-linux. Relock with `--system` for another.

## Sources supported and refused

These inputs work:

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
- sdists, which pip builds with the build requirements that the lock run
  recorded.

The index comes from `PIP_INDEX_URL` and `PIP_EXTRA_INDEX_URL`, from pip's
configuration files, or from the index options of the requirements.

These are refused:

- **Other systems.** A lock covers x86_64-linux and aarch64-linux. macOS
  and Windows wheels are not locked.
- **Another Python version.** The wheels of a lock are those of the Python
  version that the lock run used, and a build with another version is
  refused.
- **Credentials in the lockfile.** The lockfile records URLs without their
  credentials. A private index needs a `fetchers.fetchurl` that supplies
  them, such as nixpkgs' `fetchurl` with `netrcPhase`.

## Examples

[pallets/click](https://github.com/pallets/click) installs its test
dependencies with `pip install -r requirements/tests.txt -e .`. In a clone
of it, lock those arguments, and work offline from `.venv`:

```zsh
nix run github:nix-purifiers/pip-purifier -- lock -- -r requirements/tests.txt -e .
nix run github:nix-purifiers/pip-purifier -- prefetch
.venv/bin/pytest tests
```

Then add a `flake.nix` that builds its sdist and wheel and runs its tests in
the sandbox:

```nix
{
  inputs.pip-purifier.url = "github:nix-purifiers/pip-purifier";
  inputs.nixpkgs.follows = "pip-purifier/nixpkgs";

  outputs = { nixpkgs, pip-purifier, ... }:
    let
      project = pip-purifier.lib.pip-purifier.buildPipProject {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        src = ./.;
        checkPhase = "pytest tests";
      };
    in
    {
      packages.x86_64-linux.default = project.packages.click;
      checks.x86_64-linux.tests = project.tests;
    };
}
```

`nix build` makes the sdist and wheel, and `nix flake check` runs the
tests. Commit `pip-purifier.lock.json` and `flake.nix` with the project.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
