#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Runs the commands that build with Nix themselves on a copy of the project
# fixture: `install` into .venv, `pip` against that venv, `build` of a
# program, and `publish --dry-run`, which checks the distributions Nix built
# with twine.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')/bin/pip-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp -r tests/fixtures/project "$work/project"
cd "$work/project"

"$cli" install
output=$(.venv/bin/greet)
echo "$output"
[ "$output" = "hello attrs=25.3.0 docopt=0.6.2 yaml=6.0.3" ]

"$cli" pip --python .venv/bin/python list | grep -q '^PyYAML *6.0.3'

program=$("$cli" build programs.greet)
[ "$("$program/bin/greet")" = "hello attrs=25.3.0 docopt=0.6.2 yaml=6.0.3" ]

"$cli" publish --dry-run
