# Testing

- `nix flake check -L` builds every fixture in `tests/fixtures/` offline in
  the sandbox (`tests/default.nix`), runs its programs, checks the package
  files, runs `pip-purifier install` against prebuilt inputs, and checks the
  formatting.
- `nix flake check --all-systems --no-build` evaluates the checks for
  x86_64-linux and aarch64-linux.
- `tests/lock-run.sh` (needs jq) runs the lock against the network on a
  copy of each fixture and compares the outputs, pins, arguments and inputs
  with the committed lockfile.
- `tests/interactive.sh` runs `install`, `pip`, `build` and
  `publish --dry-run`, which build with Nix themselves.
- `tests/relock-fixtures.sh` rewrites the fixtures' lockfiles after a
  change to a fixture or to the lock format.
