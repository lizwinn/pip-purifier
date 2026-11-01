# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The `pip-purifier` command: `lock` and `update` write
  # pip-purifier.lock.json, `prefetch` and `pip` run pip offline, and
  # `publish` uploads the release that the Nix build made.
  cli = callPackage ./cli { };
}
