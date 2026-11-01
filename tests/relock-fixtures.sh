#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes pip-purifier.lock.json for every fixture with the CLI of this
# flake. Run it from the repository root after changing a fixture or the
# lock format.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')/bin/pip-purifier

lock() {
  local fixture=$1
  shift
  echo "== $fixture" >&2
  (cd "tests/fixtures/$fixture" && "$cli" lock "$@")
}

lock project
lock sources
lock pylock
lock hashed
lock script -- --requirements-from-script app.py
