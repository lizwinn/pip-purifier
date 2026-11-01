# SPDX-License-Identifier: MIT
#
# buildPipProject: builds a pip project in the Nix sandbox from
# pip-purifier.lock.json, which `pip-purifier lock` writes. The lockfile
# names every download and every output, so Nix knows the outputs when it
# evaluates, with no generated Nix files and no import from derivation.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# pip-purifier overlay (`overlays.default`) adds it to the package set as
# `buildPipProject`, so a package written for callPackage takes it like any
# other dependency, and `buildPipProject.override` replaces what it takes
# from the set. The builder returns
#
#   (buildPipProject { src = ./.; }).packages.<name>
#     the sdist and the wheel of each local project, with the file names
#     as `.sdist` and `.wheel` and every file under `.files`;
#   .tests
#     `checkPhase` run in a copy of the source with the environment's
#     programs on PATH; without `checkPhase`, pytest when the environment
#     has it;
#   .release
#     every sdist and wheel of `packages`, which `pip-purifier publish`
#     uploads;
#   .fetches
#     the download entries of the lock (readLock), for every system;
#   .environment
#     a virtual environment with everything `pip install <recorded args>`
#     installs, built offline;
#   .programs.<name>
#     each program that environment installs, for `nix run`;
#   .inputs
#     the locked downloads for this system, which `pip-purifier prefetch`
#     and `pip-purifier pip` read.
{
  lib,
  stdenv,
  git,
  mitm-cache,
  openssl,
  runCommand,
  writeText,
  symlinkJoin,
  python3,
  # The package set, which the purifier library fetches with: its
  # fetchers, and the tools that unpack archives and rebuild .git.
  pkgs,
  # The library the nix-purifiers share (github:nix-purifiers/purifier),
  # which the overlay passes.
  purifier,
  # lib.pip-purifier.readLock (read-lock.nix), which the overlay passes.
  readLock,
}:
{
  # The directory pip runs in.
  src,
  # Replacements for nixpkgs' fetchers, such as a fetchurl that sends
  # credentials or goes through a mirror, for the purifier library's
  # fetchEntry and tree.
  fetchers ? { },
  # The lockfile, which may lie outside `src`.
  lockFile ? src + "/pip-purifier.lock.json",
  # The lockfile's contents, parsed, in place of reading `lockFile`; the
  # conformance checks give a changed lockfile this way.
  lockData ? null,
  # The Python to install for. Its version must be the one the lock run
  # used.
  python ? python3,
  # Local projects outside `src` that the requirements name by a relative
  # path such as "../shared", each with its source.
  pathSources ? { },
  # Native dependencies of sdists that pip builds, such as pkg-config and
  # a C library.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # A command that tests the project, run in a copy of the source with the
  # environment's programs on PATH.
  checkPhase ? null,
}:
let
  inherit (builtins)
    attrNames
    filter
    toJSON
    ;
  inherit (lib)
    concatMapStrings
    escapeShellArg
    hasSuffix
    ;

  system = stdenv.hostPlatform.system;
  arch = stdenv.hostPlatform.parsed.cpu.name;

  # The lock in memory, checked by the purifier library, and then for this
  # build's system and Python.
  read = readLock {
    inherit
      src
      lockFile
      lockData
      pathSources
      ;
  };
  lock = purifier.checkLock read;
  file = toString lockFile;
  checked = builtins.seq lock (
    if !(lib.elem system (attrNames read.lockfile.pins)) then
      throw "pip-purifier: ${file} has no lock for ${system}; it covers ${toString (attrNames read.lockfile.pins)}. Run `pip-purifier lock`."
    else if python.pythonVersion != read.lockfile.python then
      throw "pip-purifier: ${file} was made for Python ${read.lockfile.python}, and this build uses Python ${python.pythonVersion}. Pass a `python` of version ${read.lockfile.python}, or run `pip-purifier lock --python` with this one."
    else
      read.lockfile
  );

  fetchArgs = {
    inherit pkgs;
  }
  // fetchers;
  fetch = purifier.fetchEntry fetchArgs;
  compatible = purifier.wheels {
    pythonVersion = checked.python;
    inherit arch;
    glibcVersion = lib.versions.majorMinor (lib.getVersion stdenv.cc.libc);
  };

  isFile = entry: entry ? url;
  fileName = entry: baseNameOf entry.path;
  # The entries of this system, of which the build keeps the wheels that
  # install here, and every sdist, archive and checkout.
  files = filter (
    entry: isFile entry && (!(hasSuffix ".whl" entry.path) || compatible (fileName entry))
  ) (builtins.seq checked (purifier.entriesFor system read));
  byPath = lib.listToAttrs (
    map (entry: {
      name = entry.path;
      value = entry;
    }) lock.entries
  );

  # Each VCS or URL requirement, as written, to its local copy: a checkout
  # in the store, or a file of the wheelhouse (relative to `inputs`).
  sources = lib.mapAttrs (
    _: path:
    let
      entry = byPath.${path};
    in
    if isFile entry then "wheelhouse/${fileName entry}" else "${fetch entry}"
  ) checked.sources;

  # The path at which `mitm-cache replay` looks up a URL: "https/" or
  # "http/", then the host and path, without the query.
  replayPath =
    url:
    let
      m = builtins.match "(https?)://([^?#]*).*" url;
    in
    "${builtins.elemAt m 0}/${builtins.elemAt m 1}";

  # Each git repository that another package names as a source, with a
  # clone of it in the store: the purifier library rebuilds its .git from
  # the recorded commit object.
  repositories = map (repository: repository // { path = "${fetch byPath.${repository.path}}"; }) (
    checked.repositories or [ ]
  );

  # The wheels that install here and every sdist and archive, by file name.
  wheelhouse = purifier.tree (
    fetchArgs
    // {
      name = "pip-purifier-wheelhouse";
      entries = files;
    }
  );

  # Each Mercurial, Subversion or Bazaar repository that another package
  # names as a source, with its locked checkout, for vcs_shim.py.
  shims = map (shim: shim // { path = "${fetch byPath.${shim.path}}"; }) (checked.shims or [ ]);

  inputs = runCommand "pip-purifier-inputs" { } ''
    mkdir -p $out
    ln -s ${wheelhouse} $out/wheelhouse
    mkdir -p $out/replay
    ${concatMapStrings (replay: ''
      mkdir -p "$(dirname $out/replay/${escapeShellArg (replayPath replay.url)})"
      ln -s ${fetch byPath.${replay.path}} $out/replay/${escapeShellArg (replayPath replay.url)}
    '') (checked.replays or [ ])}
    cp ${writeText "sources.json" (toJSON sources)} $out/sources.json
    cp ${writeText "repositories.json" (toJSON repositories)} $out/repositories.json
    cp ${writeText "shims.json" (toJSON shims)} $out/shims.json
    cp ${writeText "versions.json" (toJSON checked.versions)} $out/versions.json
    cp ${writeText "args.json" (toJSON checked.args)} $out/args.json
    cp ${writeText "pins.txt" (lib.concatLines checked.pins.${system})} $out/pins.txt
  '';

  # The offline installer, with the module that rewrites pip's inputs.
  scripts = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./offline.py
      ./pip_inputs.py
      ./vcs_shim.py
    ];
  };

  pip = python.withPackages (ps: [
    ps.pip
    ps.build
  ]);

  # The project, with its `pathSources` beside it where its relative paths
  # lead. It is placed four directories deep so that "../" paths stay
  # inside the build directory.
  unpack = ''
    work=$TMPDIR/work/a/b/c/d/project
    mkdir -p $work
    cp -r ${src}/. $work
    ${concatMapStrings (key: ''
      mkdir -p "$(dirname $work/${key})"
      rm -rf $work/${key}
      cp -r ${pathSources.${key}} $work/${key}
    '') (attrNames pathSources)}
    chmod -R u+w $TMPDIR/work
    cd $work
    export HOME=$TMPDIR
    # nixpkgs' Python setup hook puts the site-packages of each Python
    # package among the build inputs on PYTHONPATH, which would come ahead
    # of the locked packages in pip and in `python -m build`.
    unset PYTHONPATH
  '';

  offlineEnv = {
    PIP_NO_INDEX = "1";
    PIP_FIND_LINKS = "${inputs}/wheelhouse";
    PIP_CONFIG_FILE = "/dev/null";
    PIP_DISABLE_PIP_VERSION_CHECK = "1";
    PIP_NO_INPUT = "1";
  };

  name = lib.head (attrNames checked.outputs.packages ++ [ "pip-project" ]);

  environment = stdenv.mkDerivation (
    offlineEnv
    // {
      name = "${name}-environment";
      dontUnpack = true;
      nativeBuildInputs = [
        pip
        git
        mitm-cache
        openssl
      ]
      ++ nativeBuildInputs;
      inherit buildInputs;
      buildPhase = ''
        runHook preBuild
        ${unpack}
        ${python.interpreter} -m venv --without-pip $out
        ${pip.interpreter} ${scripts}/offline.py --project $work --inputs ${inputs} --venv $out --no-editable
        runHook postBuild
      '';
      dontInstall = true;
      passthru = {
        inherit inputs;
      };
    }
  );

  programs = lib.genAttrs checked.outputs.programs (
    program:
    runCommand program { meta.mainProgram = program; } ''
      mkdir -p $out/bin
      ln -s ${environment}/bin/${program} $out/bin/${program}
    ''
  );

  packages = lib.mapAttrs (
    name: package:
    let
      wheel = package.wheels.${system};
      drv = stdenv.mkDerivation (
        offlineEnv
        // {
          name = "${name}-${package.version}-dist";
          dontUnpack = true;
          nativeBuildInputs = [
            pip
            git
          ]
          ++ nativeBuildInputs;
          inherit buildInputs;
          buildPhase = ''
            runHook preBuild
            ${unpack}
            ${pip.interpreter} ${scripts}/offline.py tag ${escapeShellArg package.path} ${escapeShellArg package.version}
            ${pip.interpreter} -m pip wheel --no-deps --wheel-dir $out ${escapeShellArg package.path}
            ${pip.interpreter} -m build --sdist --outdir $out ${escapeShellArg package.path}
            ${pip.interpreter} ${scripts}/offline.py normalize-sdist $out/${escapeShellArg package.sdist}
            for f in ${escapeShellArg wheel} ${escapeShellArg package.sdist}; do
              if [ ! -e "$out/$f" ]; then
                echo "pip-purifier: the build made $(ls $out), not $f. Run \`pip-purifier lock\`." >&2
                exit 1
              fi
            done
            runHook postBuild
          '';
          dontInstall = true;
          dontFixup = true;
          passthru = {
            inherit wheel;
            inherit (package) sdist version;
            files = {
              ${wheel} = "${drv}/${wheel}";
              ${package.sdist} = "${drv}/${package.sdist}";
            };
          };
        }
      );
    in
    drv
  ) checked.outputs.packages;

  release =
    if packages == { } then
      throw "pip-purifier: the project has no local package to release; `release` holds the sdists and wheels of the local projects that pip installs."
    else
      symlinkJoin {
        name = "${name}-release";
        paths = lib.attrValues packages;
      };

  testCommand =
    if checkPhase != null then
      checkPhase
    else if lib.elem "pytest" checked.outputs.programs then
      "pytest"
    else
      throw "pip-purifier: the environment has no pytest, so `tests` needs a `checkPhase`.";

  tests = stdenv.mkDerivation {
    name = "${name}-tests";
    dontUnpack = true;
    nativeBuildInputs = [ environment ];
    buildPhase = ''
      ${unpack}
      export PATH=${environment}/bin:$PATH
      ${testCommand}
      touch $out
    '';
    dontInstall = true;
  };
in
{
  inherit
    packages
    tests
    release
    environment
    programs
    inputs
    ;
  fetches = lock.entries;
}
