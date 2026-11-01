# SPDX-License-Identifier: MIT
#
# What the `pip-purifier` command builds for a project directory and a
# lockfile, each given as an absolute path, with the nixpkgs the command was
# built with: `attr` is "inputs", "release" or "packages.<name>".
#
# A local project that the requirements name by a path outside the project
# directory is read from that path.
{
  nixpkgs,
  src,
  lockFile,
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
  lockPath = /. + lockFile;
  lock = builtins.fromJSON (builtins.readFile lockPath);
  outside = lib.unique (
    map dirOf (builtins.filter (rel: lib.hasPrefix "../" rel) (builtins.attrNames lock.inputs))
  );
  pathSources = lib.genAttrs outside (rel: source (/. + "${src}/${rel}"));

  # The purifier library at the revision this pip-purifier's flake.lock
  # pins, which the command's package links beside this directory.
  purifier = import ../purifier/nix/lib { inherit lib; };

  inherit (import ./read-lock.nix { inherit lib; }) readLock;
  project = pkgs.callPackage ./build-pip-project.nix { inherit purifier readLock; } {
    src = source root;
    lockFile = lockPath;
    lockData = lock;
    inherit pathSources;
  };
in
lib.attrByPath (lib.splitString "." attr) (throw "pip-purifier: the project has no output ${attr}")
  project
