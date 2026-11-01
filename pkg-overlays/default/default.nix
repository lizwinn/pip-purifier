# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.pip-purifier` (`.cli`), and the builder `pkgs.buildPipProject`
# (nix/lib/build-pip-project.nix) beside them, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `pip-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "pip-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildPipProject = final.callPackage ../../nix/lib/build-pip-project.nix { };
    };
}
