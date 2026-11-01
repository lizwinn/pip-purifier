#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Works through pip-purifier the way a developer would, on a real project
# pinned to a commit: pallets/click 8.1.8, whose tests install with
# `pip install -r requirements/tests.txt -e .`.
#
#   1. the README quickstart: lock, then build with the README's flake, with
#      click's test suite as the checkPhase;
#   2. a relock reproduces the lockfile byte for byte, and how long a lock
#      takes;
#   3. the everyday loop offline: install into .venv, run the tests, check
#      that pyright resolves every import from that .venv;
#   4. adding a requirement: install refuses the stale lock with a message
#      that says to relock, and works after the relock.
set -euo pipefail

repo=$(pwd)
cli=$(nix build --no-link --print-out-paths '.#cli')/bin/pip-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

commit=934813e4d421071a1b3db3973c02fe2721359a6e
git clone --quiet https://github.com/pallets/click "$work/click"
git -C "$work/click" -c advice.detachedHead=false checkout --quiet "$commit"
cd "$work/click"

lock() {
  "$cli" lock -- -r requirements/tests.txt -e .
}

echo "== lock" >&2
start=$(date +%s)
lock
echo "the lock run took $(($(date +%s) - start)) s" >&2

echo "== relock reproduces the lockfile" >&2
cp pip-purifier.lock.json "$work/first.json"
start=$(date +%s)
lock
echo "the relock took $(($(date +%s) - start)) s" >&2
cmp "$work/first.json" pip-purifier.lock.json

echo "== the README's flake, with the test suite as checkPhase" >&2
cat > flake.nix <<EOF
{
  inputs.pip-purifier.url = "path:$repo";
  inputs.nixpkgs.follows = "pip-purifier/nixpkgs";
  outputs = { nixpkgs, pip-purifier, ... }:
    let
      system = builtins.currentSystem or "x86_64-linux";
      pkgs = import nixpkgs { inherit system; overlays = [ pip-purifier.overlays.default ]; };
      project = pkgs.buildPipProject { src = ./.; checkPhase = "pytest -q tests"; };
    in {
      packages.\${system} = {
        default = project.environment;
        check = project.check;
        dist = project.packages.click;
      };
    };
}
EOF
system=$(nix eval --impure --raw --expr builtins.currentSystem)
sed -i "s/builtins.currentSystem or \"x86_64-linux\"/\"$system\"/" flake.nix
nix build --no-link -L 'path:.#check'
nix build --no-link 'path:.#dist'

echo "== the everyday loop offline" >&2
"$cli" install
.venv/bin/pytest -q tests
nix run 'nixpkgs#pyright' -- --pythonpath .venv/bin/python --outputjson src/click > "$work/pyright.json" || true
missing=$(nix run 'nixpkgs#jq' -- '[.generalDiagnostics[] | select(.rule == "reportMissingImports" or .rule == "reportMissingModuleSource")] | length' "$work/pyright.json")
echo "pyright found $missing unresolved imports" >&2
[ "$missing" = 0 ]

echo "== adding a requirement" >&2
echo "rich==13.9.4" >> requirements/tests.txt
if "$cli" install 2> "$work/stale.txt"; then
  echo "install accepted a stale lock" >&2
  exit 1
fi
grep -q 'Run `pip-purifier lock`' "$work/stale.txt"
lock
"$cli" install
.venv/bin/python -c 'import rich; print("rich", rich.__version__)'
