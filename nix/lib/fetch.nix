# SPDX-License-Identifier: MIT
#
# The fetcher for locked files and checkouts. Each locked download is an
# entry in the shape of the shared purifier library:
#
#   { path, url, mirrors, hash }                                  a file
#   { path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash }
#                                                                 a git checkout
#   { path, hg = { url, rev }, hash }                             a Mercurial checkout
#   { path, svn = { url, rev }, hash }                            a Subversion checkout
#   { path, bzr = { url, rev }, hash }                            a Bazaar checkout
#
# A git checkout is always fetched without .git, so its hash is
# reproducible. When `leaveDotGit` is true, `commitObject` is
# { object, gitlinks }: the raw commit object (base64) and the submodule
# commits of its tree ([ { path, rev } ]), from which the offline install
# rebuilds a shallow .git (nix/lib/offline.py, rebuild_git). Otherwise it is
# null.
#
# A file comes from `fetchurl`, which tries `url` and then each mirror. A
# consumer replaces `fetchurl` for credentials (nixpkgs' fetchurl takes
# `netrcPhase`) or more mirrors.
{
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  fetchbzr,
}:
let
  # A store path name from a file name: store path names allow
  # [A-Za-z0-9+._?=-] and must not start with a dot.
  storeName =
    name:
    let
      parts = builtins.split "[^A-Za-z0-9+._?=-]" name;
      replaced = builtins.concatStringsSep "" (map (p: if builtins.isList p then "_" else p) parts);
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
    in
    builtins.substring 0 200 (if undotted == "" then "file" else undotted);
in
entry:
if entry ? url then
  fetchurl {
    name = storeName (baseNameOf entry.path);
    urls = [ entry.url ] ++ entry.mirrors;
    inherit (entry) hash;
  }
else if entry ? git then
  fetchgit {
    inherit (entry.git) url rev;
    fetchSubmodules = entry.git.submodules;
    inherit (entry) hash;
  }
else if entry ? hg then
  fetchhg {
    inherit (entry.hg) url rev;
    inherit (entry) hash;
  }
else if entry ? svn then
  fetchsvn {
    inherit (entry.svn) url rev;
    inherit (entry) hash;
  }
else if entry ? bzr then
  fetchbzr {
    inherit (entry.bzr) url rev;
    inherit (entry) hash;
  }
else
  throw "pip-purifier: a download entry of an unknown kind: ${builtins.toJSON entry}"
