# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildPipProject.
  overlay,
  cli,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildPipProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildPipProject runCommand;

  # A local setuptools project installed with `-e .`, with a console
  # script, a wheel, an sdist-only dependency (docopt, built with the locked
  # setuptools) and a dependency with platform wheels (PyYAML).
  project = buildPipProject { src = ./fixtures/project; };

  # A git requirement whose version comes from git (attrs, with hatch-vcs),
  # a URL archive (six), a local directory and a nested requirements file.
  # The local directory depends on a git repository (iniconfig, also
  # versioned with hatch-vcs) and on a URL (pyparsing) through its own
  # metadata.
  sources = buildPipProject { src = ./fixtures/sources; };

  # A pylock.toml that `pip lock` wrote.
  pylock = buildPipProject { src = ./fixtures/pylock; };

  # The PEP 723 dependencies of a script, tested with `checkPhase`.
  script = buildPipProject {
    src = ./fixtures/script;
    checkPhase = ''
      output=$(python app.py)
      echo "$output"
      [ "$output" = "script six=1.17.0 packaging=25.0" ]
    '';
  };

  # A requirements file with --hash pins, as pip-compile writes it.
  hashed = buildPipProject { src = ./fixtures/hashed; };

  # Runs a program and compares what it prints.
  runs =
    name: program: expected:
    runCommand "pip-purifier-test-${name}" { } ''
      output=$(${lib.getExe program})
      echo "$output"
      if [ "$output" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected} >&2
        exit 1
      fi
      touch $out
    '';

  # Runs a Python snippet in an environment and compares what it prints.
  imports =
    name: environment: code: expected:
    runCommand "pip-purifier-test-${name}" { } ''
      output=$(${environment}/bin/python -c ${lib.escapeShellArg code})
      echo "$output"
      if [ "$output" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected} >&2
        exit 1
      fi
      touch $out
    '';

  # Runs `pip-purifier install` in a copy of a fixture, with the inputs Nix
  # built for it, then runs a program of the .venv. `edit` changes the
  # source afterwards: an editable install prints the change.
  installs =
    name: fixture: inputs: program: expected: edit: edited:
    runCommand "pip-purifier-test-install-${name}" { nativeBuildInputs = [ cli ]; } ''
      cp -r ${fixture} project
      chmod -R u+w project
      cd project
      export HOME=$TMPDIR
      pip-purifier install --inputs ${inputs}
      check() {
        output=$(.venv/bin/${program})
        echo "$output"
        if [ "$output" != "$1" ]; then
          echo "expected: $1" >&2
          exit 1
        fi
      }
      check ${lib.escapeShellArg expected}
      ${edit}
      check ${lib.escapeShellArg edited}
      touch $out
    '';
in
{
  project = runs "project" project.programs.greet "hello attrs=25.3.0 docopt=0.6.2 yaml=6.0.3";

  # The local project's sdist and wheel, under the names the lockfile
  # gives them.
  project-package = runCommand "pip-purifier-test-project-package" { } ''
    test -f ${project.packages.greet.files."greet-0.1.0-py3-none-any.whl"}
    test -f ${project.packages.greet.files."greet-0.1.0.tar.gz"}
    touch $out
  '';

  install-project =
    installs "project" ./fixtures/project project.inputs "greet"
      "hello attrs=25.3.0 docopt=0.6.2 yaml=6.0.3"
      "sed -i 's/hello/howdy/' src/greet/__init__.py"
      "howdy attrs=25.3.0 docopt=0.6.2 yaml=6.0.3";

  sources =
    runs "sources" sources.programs.sources
      "attrs=25.3.0 six=1.17.0 idna=3.10 iniconfig=2.1.0 pyparsing=3.2.3 localdir=0.3.0";

  pylock =
    imports "pylock" pylock.environment
      "import six, packaging; print(six.__version__, packaging.__version__)"
      "1.17.0 25.0";

  script = script.check;

  hashed = imports "hashed" hashed.environment "import idna; print(idna.__version__)" "3.10";

  cli = runCommand "pip-purifier-test-cli" { } ''
    ${lib.getExe cli} --help
    ${lib.getExe cli} lock --help
    ${lib.getExe cli} install --help
    ${lib.getExe cli} publish --help
    touch $out
  '';
}
