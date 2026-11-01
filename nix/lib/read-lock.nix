# SPDX-License-Identifier: MIT
#
# readLock (lib.pip-purifier.readLock): pip-purifier.lock.json read into
# the lock in memory of the purifier contract, which the purifier library's
# checkLock and entriesFor take:
#
#   {
#     purifier = "pip-purifier";
#     entries  = the downloads (`artifacts`); a wheel for one CPU carries
#                `systems`, the Nix systems of that CPU;
#     outputs  = the local projects, by name: { path, version, sdist,
#                wheels.<system> };
#     problems = why the lockfile cannot be used, each naming the command
#                that fixes it: missing, malformed, of another format
#                version, changed after the lock, or older than the
#                project's requirements;
#     lockfile = the lockfile as it is, for buildPipProject;
#   }
#
# The lockfile holds a hash of its own content: the SHA-256 of the
# lockfile without `hash`, as builtins.toJSON writes it (compact, keys
# sorted). The lock tool computes the same with Python's json module
# (lock_hash in src/pip_purifier.py).
{ lib }:
let
  inherit (builtins)
    attrNames
    filter
    hashFile
    toJSON
    ;

  supportedVersion = import ./lock-version.nix;

  # The top-level fields of a lockfile; LOCK_FIELDS in src/pip_purifier.py
  # lists the same.
  fields = [
    "version"
    "hash"
    "pip"
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

  # The Nix system of each CPU that a lock covers, as wheel platform tags
  # name it.
  cpus = {
    x86_64 = "x86_64-linux";
    aarch64 = "aarch64-linux";
  };

  hashOf =
    lock:
    builtins.convertHash {
      hash = builtins.hashString "sha256" (toJSON (removeAttrs lock [ "hash" ]));
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # The systems a wheel is for, from the platform tags of its file name, or
  # null for a wheel that installs on every platform and for every other
  # download.
  systemsOf =
    path:
    let
      name = baseNameOf path;
      parts = lib.splitString "-" (lib.removeSuffix ".whl" name);
      platforms = lib.splitString "." (lib.last parts);
      systems = lib.unique (
        lib.concatMap (
          platform:
          lib.concatMap (cpu: lib.optional (lib.hasSuffix "_${cpu}" platform) cpus.${cpu}) (attrNames cpus)
        ) platforms
      );
    in
    if !(lib.hasSuffix ".whl" name) || lib.elem "any" platforms then null else systems;

  problemOf =
    {
      lock,
      lockFile,
      resolve,
    }:
    let
      name = toString lockFile;
      missing = if builtins.isAttrs lock then filter (field: !(lock ? ${field})) fields else fields;
      stale = filter (
        rel: !(builtins.pathExists (resolve rel)) || hashFile "sha256" (resolve rel) != lock.inputs.${rel}
      ) (attrNames lock.inputs);
    in
    if missing != [ ] then
      "pip-purifier: ${name} is not a pip-purifier lockfile: it lacks ${lib.concatStringsSep ", " missing}. Run `pip-purifier lock`."
    else if lock.version != supportedVersion then
      "pip-purifier: ${name} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `pip-purifier lock` with the pip-purifier that provides this library."
    else if lock.hash != hashOf lock then
      "pip-purifier: ${name} was changed after `pip-purifier lock` wrote it: its content does not match its hash. Run `pip-purifier lock`."
    else if stale != [ ] then
      "pip-purifier: ${name} does not match ${lib.concatStringsSep ", " stale} any more. Run `pip-purifier lock`."
    else
      null;
in
{
  inherit hashOf;

  readLock =
    {
      # The directory pip runs in.
      src,
      # The lockfile, which may lie outside `src`.
      lockFile ? src + "/pip-purifier.lock.json",
      # The lockfile's contents, parsed, in place of reading `lockFile`.
      lockData ? null,
      # Local projects outside `src` that the requirements name by a
      # relative path such as "../shared", each with its source.
      pathSources ? { },
    }:
    let
      exists = lockData != null || builtins.pathExists lockFile;
      lock = if lockData != null then lockData else builtins.fromJSON (builtins.readFile lockFile);

      # A path the lockfile names relative to `src`, which may lead into
      # one of the `pathSources`.
      resolve =
        rel:
        let
          keys = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) (
            filter (key: rel == key || lib.hasPrefix "${key}/" rel) (attrNames pathSources)
          );
          key = builtins.head keys;
        in
        if keys == [ ] then
          src + "/${rel}"
        else if rel == key then
          pathSources.${key}
        else
          pathSources.${key} + "/${lib.removePrefix "${key}/" rel}";

      problem =
        if !exists then
          "pip-purifier: ${toString lockFile} does not exist. Run `pip-purifier lock`."
        else
          problemOf { inherit lock lockFile resolve; };
      usable = problem == null;
    in
    {
      purifier = "pip-purifier";
      entries =
        if usable then
          map (
            artifact:
            let
              systems = systemsOf artifact.path;
            in
            artifact // lib.optionalAttrs (systems != null) { inherit systems; }
          ) lock.artifacts
        else
          [ ];
      outputs = if usable then lock.outputs.packages else { };
      problems = lib.optional (!usable) problem;
      lockfile = lock;
      inherit resolve;
    };
}
