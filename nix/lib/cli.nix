# SPDX-License-Identifier: MIT
#
# What the `pip-purifier` command builds for a project directory given as an
# absolute path, with the nixpkgs the command was built with: `attr` is
# "inputs", "environment" or "packages.<name>".
#
# A local project that the requirements name by a path outside the project
# directory is read from that path.
{
  nixpkgs,
  src,
  attr,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;

  # A directory without what pip, Python, git and pip-purifier leave in it.
  source =
    path:
    builtins.path {
      inherit path;
      name = "source";
      filter =
        p: type:
        !builtins.elem (baseNameOf p) [
          ".git"
          ".venv"
          ".pip-purifier"
          "__pycache__"
          ".pytest_cache"
          ".mypy_cache"
          ".tox"
          ".nox"
        ];
    };

  root = /. + src;
  lock = builtins.fromJSON (builtins.readFile (root + "/pip-purifier.lock.json"));
  outside = lib.unique (
    map dirOf (builtins.filter (rel: lib.hasPrefix "../" rel) (builtins.attrNames lock.inputs))
  );
  pathSources = lib.genAttrs outside (rel: source (/. + "${src}/${rel}"));

  project = pkgs.callPackage ./build-pip-project.nix { } {
    src = source root;
    inherit pathSources;
  };
in
lib.attrByPath (lib.splitString "." attr) (throw "pip-purifier: the project has no output ${attr}")
  project
