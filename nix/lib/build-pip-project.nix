# SPDX-License-Identifier: MIT
#
# buildPipProject: builds a pip project in the Nix sandbox from
# pip-purifier.lock.json, which `pip-purifier lock` writes beside the
# project's requirements. The lockfile names every download and every
# output, so Nix knows the outputs when it evaluates, with no generated Nix
# files and no import from derivation.
#
#   (buildPipProject { src = ./.; }).environment
#     a virtual environment with everything `pip install <recorded args>`
#     installs, built offline;
#   .programs.<name>
#     each program that environment installs, for `nix run`;
#   .packages.<name>
#     the sdist and the wheel of each local project, with the file names
#     as `.sdist` and `.wheel` and every file under `.files`;
#   .inputs
#     the locked downloads for this system, which `pip-purifier install`
#     reads;
#   .check
#     the environment with `checkPhase` run in a copy of the source, when
#     `checkPhase` is given.
{
  lib,
  stdenv,
  git,
  mitm-cache,
  openssl,
  python3,
  runCommand,
  writeText,
  pkgs,
  # The library the nix-purifiers share (github:nix-purifiers/purifier).
  purifier,
}:
{
  # The directory pip runs in, which holds the lockfile.
  src,
  lockFile ? src + "/pip-purifier.lock.json",
  # The lockfile's contents, parsed, in place of reading `lockFile`; the
  # negative tests give a changed lockfile this way.
  lockData ? builtins.fromJSON (builtins.readFile lockFile),
  # The Python to install for. Its version must be the one the lock run
  # used.
  python ? python3,
  # A replacement for nixpkgs' fetchurl, for credentials or mirrors, which
  # the purifier library fetches locked files with.
  fetchurl ? null,
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
    hashFile
    head
    sort
    stringLength
    substring
    toJSON
    ;
  inherit (lib)
    concatMapStrings
    escapeShellArg
    hasPrefix
    hasSuffix
    ;

  supportedVersion = import ./lock-version.nix;
  lock = lockData;
  system = stdenv.hostPlatform.system;
  arch = stdenv.hostPlatform.parsed.cpu.name;

  fetchers = {
    inherit pkgs;
  }
  // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; };
  fetch = purifier.fetchEntry fetchers;
  compatible = purifier.wheels {
    pythonVersion = lock.python;
    inherit arch;
    glibcVersion = lib.versions.majorMinor (lib.getVersion stdenv.cc.libc);
  };

  # A path the lockfile names relative to `src`, which may lead into one of
  # the `pathSources`.
  resolve =
    rel:
    let
      keys = sort (a: b: stringLength a > stringLength b) (
        filter (key: rel == key || hasPrefix "${key}/" rel) (attrNames pathSources)
      );
    in
    if keys == [ ] then
      src + "/${rel}"
    else if rel == head keys then
      pathSources.${head keys}
    else
      pathSources.${head keys} + "/${substring (stringLength (head keys) + 1) (-1) rel}";

  staleInputs = filter (
    rel: !(builtins.pathExists (resolve rel)) || hashFile "sha256" (resolve rel) != lock.inputs.${rel}
  ) (attrNames lock.inputs);

  requiredFields = [
    "version"
    "python"
    "args"
    "inputs"
    "systems"
    "pins"
    "versions"
    "outputs"
    "sources"
    "artifacts"
  ];
  missingFields = filter (field: !(lock ? ${field})) requiredFields;

  checked =
    assert
      builtins.isAttrs lock && missingFields == [ ]
      || throw "pip-purifier: ${toString lockFile} is not a pip-purifier lockfile: it lacks ${lib.concatStringsSep ", " missingFields}. Run `pip-purifier lock`.";
    assert
      lock.version == supportedVersion
      || throw "pip-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `pip-purifier lock` with the pip-purifier that provides this library.";
    assert
      staleInputs == [ ]
      || throw "pip-purifier: ${toString lockFile} does not match ${lib.concatStringsSep ", " staleInputs} any more. Run `pip-purifier lock`.";
    assert
      lib.elem system lock.systems
      || throw "pip-purifier: ${toString lockFile} has no lock for ${system}; it covers ${toString lock.systems}. Run `pip-purifier lock`.";
    assert
      python.pythonVersion == lock.python
      || throw "pip-purifier: ${toString lockFile} was made for Python ${lock.python}, and this build uses Python ${python.pythonVersion}. Pass a `python` of version ${lock.python}, or run `pip-purifier lock --python` with this one.";
    lock;

  isFile = entry: entry ? url;
  fileName = entry: baseNameOf entry.path;
  # The wheels that install here, and every sdist and other archive.
  files = filter (
    entry: isFile entry && (!(hasSuffix ".whl" entry.path) || compatible (fileName entry))
  ) checked.artifacts;
  byPath = lib.listToAttrs (
    map (entry: {
      name = entry.path;
      value = entry;
    }) checked.artifacts
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
    fetchers
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

  check =
    if checkPhase == null then
      null
    else
      stdenv.mkDerivation {
        name = "${name}-check";
        dontUnpack = true;
        nativeBuildInputs = [ environment ];
        buildPhase = ''
          ${unpack}
          export PATH=${environment}/bin:$PATH
          ${checkPhase}
          touch $out
        '';
        dontInstall = true;
      };
in
{
  inherit
    environment
    programs
    packages
    inputs
    check
    ;
  lock = checked;
}
