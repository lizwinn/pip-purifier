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
- a git repository that another package names as its source in its own
  metadata;
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

## Publishing

`pip-purifier publish` uploads the sdist and wheel that Nix built, with
twine. The arguments after `--` go to `twine upload`, and `--dry-run` only
runs `twine check`:

```zsh
pip-purifier publish -- --repository testpypi
```

## Limits

- **Systems.** A lock covers x86_64-linux and aarch64-linux.
- **One Python version.** The wheels of a lock are those of the Python
  version the lock run used. A build with another version is refused.
- **Other sources in package metadata.** A package that names a URL, or a
  Mercurial, Subversion or Bazaar repository, as the source of one of its
  own dependencies fails the lock run. pip downloads such a URL directly
  over HTTPS, and clones such a repository with a tool that has no setting
  to serve it from a local copy, so the build cannot answer either from the
  lockfile. Naming that dependency in the requirements yourself works,
  because pip-purifier then rewrites it to a local copy. PyPI refuses
  uploads with such dependencies, so they only occur in packages from
  repositories and local directories.
- **Credentials.** The lockfile records URLs without their credentials. A
  private index needs a `fetchurl` that supplies them, such as nixpkgs'
  `fetchurl` with `netrcPhase`.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## License

MIT
