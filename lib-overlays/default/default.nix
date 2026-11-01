# SPDX-License-Identifier: MIT
#
# The `pip-purifier` library namespace. It holds nothing: the builder needs
# a package set, so it is the package `buildPipProject` that the default
# package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    pip-purifier = prev.pip-purifier or { };
  };

}
