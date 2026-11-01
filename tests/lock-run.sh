#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Runs the lock against the network on a copy of each fixture, and checks
# that the new lockfile names the same outputs and pins the same versions
# as the committed one. The downloads may differ, because build
# requirements such as setuptools are not pinned and move with new
# releases.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')/bin/pip-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
  local fixture=$1
  shift
  echo "== $fixture" >&2
  cp -r "tests/fixtures/$fixture" "$work/$fixture"
  (cd "$work/$fixture" && "$cli" lock "$@")
  for key in outputs pins args inputs; do
    if ! diff <(jq -S ".$key" "tests/fixtures/$fixture/pip-purifier.lock.json") \
      <(jq -S ".$key" "$work/$fixture/pip-purifier.lock.json"); then
      echo "the lock run changed .$key of $fixture" >&2
      exit 1
    fi
  done
}

check project
check sources
check pylock
check hashed
check script -- --requirements-from-script app.py
