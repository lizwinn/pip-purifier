# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;

  # The flake's `packages` are the derivations of the `pip-purifier` scope,
  # which is the `default` entry of the package overlay registry
  # (pkg-overlays/). The flake also exports that overlay as `pkgOverlays`
  # and as the plain `overlays.default`.
  purifier.scope = "pip-purifier";

  caisson.libOverlays.exported = libOverlays: {
    inherit (libOverlays) default;
  };

  # `nix run github:nix-purifiers/pip-purifier -- lock` writes
  # pip-purifier.lock.json for the pip project in the current directory.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.cli;
      devShells.default = pkgs.mkShell {
        packages = [ config.packages.cli ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.packages.${system}) cli;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
