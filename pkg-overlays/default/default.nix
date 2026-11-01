# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.pip-purifier` (`.cli`). A consumer that lists this flake in
# `projects` holds it as `pip-purifier/default`, which its package sets
# apply by default. The builder is in the library, as
# `lib.pip-purifier.buildPipProject` (lib-overlays/default).
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "pip-purifier";
}
