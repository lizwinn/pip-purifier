# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The `pip-purifier` command: `lock` writes pip-purifier.lock.json,
  # `install` and `pip` run pip offline, and `publish` uploads what the Nix
  # build of a local project made.
  cli = callPackage ./cli { };
}
