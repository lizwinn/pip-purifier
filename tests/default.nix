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

  # A local package that names a Mercurial, a Subversion and a Bazaar
  # repository as sources in its own metadata, installed offline with the
  # shims answering pip's clones from locked checkouts. The checkouts are
  # built here, and the setuptools wheel comes from the project fixture.
  shimPackage =
    name:
    pkgs.writeTextDir "pyproject.toml" ''
      [build-system]
      requires = ["setuptools>=70"]
      build-backend = "setuptools.build_meta"

      [project]
      name = "${name}"
      version = "1.0"

      [tool.setuptools]
      py-modules = []
    '';
  shimInputs = runCommand "pip-purifier-test-shim-inputs" { } ''
    mkdir -p $out/user
    ln -s ${project.inputs}/wheelhouse $out/wheelhouse
    cat > $out/user/pyproject.toml <<'EOF'
    [build-system]
    requires = ["setuptools>=70"]
    build-backend = "setuptools.build_meta"

    [project]
    name = "shimuser"
    version = "1.0"
    dependencies = [
      "shimhg @ hg+https://hg.example.invalid/shimhg@0123456789abcdef0123456789abcdef01234567",
      "shimsvn @ svn+https://svn.example.invalid/shimsvn@7",
      "shimbzr @ bzr+https://bzr.example.invalid/shimbzr@3",
    ]

    [tool.setuptools]
    py-modules = []
    EOF
    # The user package, and a top-level Subversion requirement, which the
    # rewriter points at its locked checkout.
    echo '["./user", "shimtop @ svn+https://svn.example.invalid/shimtop@5"]' > $out/args.json
    echo '{"svn+https://svn.example.invalid/shimtop@5": "${shimPackage "shimtop"}"}' > $out/sources.json
    echo '{}' > $out/versions.json
    echo '[]' > $out/repositories.json
    touch $out/pins.txt
    cat > $out/shims.json <<'EOF'
    [
      {"vcs": "hg", "url": "https://hg.example.invalid/shimhg", "rev": "0123456789abcdef0123456789abcdef01234567", "version": "1.0", "path": "${shimPackage "shimhg"}"},
      {"vcs": "svn", "url": "https://svn.example.invalid/shimsvn", "rev": "7", "version": "1.0", "path": "${shimPackage "shimsvn"}"},
      {"vcs": "bzr", "url": "https://bzr.example.invalid/shimbzr", "rev": "3", "version": "1.0", "path": "${shimPackage "shimbzr"}"}
    ]
    EOF
  '';
  shims =
    runCommand "pip-purifier-test-shims"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (ps: [ ps.pip ]))
          pkgs.git
        ];
      }
      ''
        export HOME=$TMPDIR
        cp -r ${shimInputs}/user user
        chmod -R u+w user
        python -m venv --without-pip venv
        python ${../nix/lib}/offline.py --project $PWD --inputs ${shimInputs} --venv venv --no-editable
        # Each package is installed, and pip recorded the locked revision
        # that the shim reported.
        venv/bin/python - <<'EOF'
        import importlib.metadata as m
        import json

        for name, rev in [
            ("shimhg", "0123456789abcdef0123456789abcdef01234567"),
            ("shimsvn", "7"),
            ("shimbzr", "3"),
        ]:
            direct = json.loads(m.distribution(name).read_text("direct_url.json"))
            print(name, m.version(name), direct["vcs_info"])
            assert direct["vcs_info"]["commit_id"] == rev, direct
        print("shimtop", m.version("shimtop"))
        EOF
        touch $out
      '';

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

  inherit shims;

  # The unit tests of the lock tool, the input rewriter, the git rebuild and
  # the VCS shims (tests/unit).
  unit =
    runCommand "pip-purifier-test-unit"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.git
        ];
      }
      ''
        export HOME=$TMPDIR
        export PIP_PURIFIER_NIX_LIB=${../nix/lib}
        export PIP_PURIFIER_PYTHON=${pkgs.python3.interpreter}
        export PIP_PURIFIER_NIXPKGS=${pkgs.path}
        export PYTHONPATH=${../nix/lib}:${../src}
        python -m unittest discover -s ${./unit} -v
        touch $out
      '';

  inherit (import ./negative.nix { inherit pkgs buildPipProject; })
    evaluation
    missing-entry
    ;

  hashed = imports "hashed" hashed.environment "import idna; print(idna.__version__)" "3.10";

  cli = runCommand "pip-purifier-test-cli" { } ''
    ${lib.getExe cli} --help
    ${lib.getExe cli} lock --help
    ${lib.getExe cli} install --help
    ${lib.getExe cli} publish --help
    touch $out
  '';
}
