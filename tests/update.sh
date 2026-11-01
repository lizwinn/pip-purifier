#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update job of CI. A project whose lockfile pins six
# 1.16.0 after its requirement was loosened to `six`: `lock` keeps 1.16.0,
# `update six` moves it to a newer six, and the updated lockfile passes the
# stale check of `prefetch`, which installs the newer six. A project whose
# input is a pylock.toml is refused, with the command that updates it.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')/bin/pip-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/project"
cd "$work/project"

pins() {
  python3 -c 'import json, sys; print(" ".join(p for p in json.load(open("pip-purifier.lock.json"))["pins"]["x86_64-linux"] if p.startswith("six==")))'
}

echo "== a lockfile that pins six 1.16.0" >&2
echo "six==1.16.0" > requirements.txt
"$cli" lock
echo "six" > requirements.txt

echo "== lock keeps it" >&2
"$cli" lock
[ "$(pins)" = "six==1.16.0" ]

echo "== update six" >&2
"$cli" update six
updated=$(pins)
echo "$updated" >&2
[ -n "$updated" ] && [ "$updated" != "six==1.16.0" ]
"$cli" prefetch
[ "$(.venv/bin/python -c 'import six; print("six==" + six.__version__)')" = "$updated" ]

echo "== update of a pylock.toml project" >&2
cd "$OLDPWD"
cp -r tests/fixtures/pylock "$work/pylock"
cd "$work/pylock"
if "$cli" update 2> refused.txt; then
  echo "update rewrote the lock of a pylock.toml project" >&2
  exit 1
fi
grep -q 'Run `pip lock`' refused.txt
echo "update works" >&2
