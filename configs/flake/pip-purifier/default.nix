# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The `pip-purifier` scope is the `default` entry of this flake's
    # package overlay registry (pkg-overlays/): the package set applies it
    # by default, and the flake exports it as `pkgOverlays` and as the
    # plain `overlays.default`. The scope holds the builder
    # `buildPipProject`, a function, so the flake's `packages` output is
    # written below, as the derivations of the scope.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/pip-purifier -- lock` writes
  # pip-purifier.lock.json for the pip project in the current directory.
  perSystem =
    { config, pkgs, ... }:
    {
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.pip-purifier // {
        default = config.packages.cli;
      };
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
