# SPDX-License-Identifier: MIT
#
# The `pip-purifier` library namespace: `readLock` (nix/lib/read-lock.nix)
# and `buildPipProject` (nix/lib/build-pip-project.nix), with the
# `purifier` library that this flake lists in `projects`. A consumer that
# lists this flake in `projects` holds it as `pip-purifier/default`, and
# its library then has `lib.pip-purifier`.
{ ... }:
{

  overlay = final: prev: {
    pip-purifier = rec {
      inherit (import ../../nix/lib/read-lock.nix { lib = final; }) readLock;
      buildPipProject = import ../../nix/lib/build-pip-project.nix {
        lib = final;
        inherit (final) purifier;
        inherit readLock;
      };
    };
  };

}
