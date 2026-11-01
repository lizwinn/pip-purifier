# SPDX-License-Identifier: MIT
#
# Common mistakes, each of which has to fail with an error that names the
# problem and the command that fixes it. Each case builds the hashed fixture
# with a changed lockfile, given as `lockData` so that evaluation reads no
# generated file. Evaluation errors are caught with builtins.tryEval; a
# failure inside a build is caught with testers.testBuildFailure, whose log
# the check reads.
{
  pkgs,
  buildPipProject,
}:
let
  inherit (pkgs) lib runCommand;
  src = ./fixtures/hashed;
  lock = builtins.fromJSON (builtins.readFile (src + "/pip-purifier.lock.json"));

  withLock =
    changes:
    buildPipProject {
      inherit src;
      lockData = lock // changes;
    };

  fails =
    name: value:
    let
      result = builtins.tryEval (builtins.seq value.drvPath true);
    in
    assert lib.assertMsg (
      !result.success
    ) "pip-purifier: the negative test ${name} evaluated, and it should not";
    true;

  # The requirements changed after the lock: their hash no longer matches.
  stale = withLock { inputs = lib.mapAttrs (_: _: lib.fakeSha256) lock.inputs; };
  malformed = buildPipProject {
    inherit src;
    lockData = removeAttrs lock [ "artifacts" ];
  };
  newerFormat = withLock { version = 999; };
  otherSystem = withLock { systems = [ "riscv64-linux" ]; };
  otherPython = buildPipProject {
    inherit src;
    python = pkgs.python312;
  };

  # A lockfile whose download of idna was removed: pip cannot find idna
  # offline, and the error names it.
  missing = withLock { artifacts = [ ]; };
in
{
  evaluation =
    assert fails "stale" stale.environment;
    assert fails "malformed" malformed.environment;
    assert fails "newer-format" newerFormat.environment;
    assert fails "other-python" otherPython.environment;
    assert fails "other-system" otherSystem.environment;
    runCommand "pip-purifier-test-negative-evaluation" { } "touch $out";

  missing-entry =
    let
      failure = pkgs.testers.testBuildFailure missing.environment;
    in
    runCommand "pip-purifier-test-negative-missing-entry" { } ''
      grep -q 'the lockfile has no file for idna' ${failure}/testBuildFailure.log
      grep -q 'run `pip-purifier lock`' ${failure}/testBuildFailure.log
      touch $out
    '';
}
