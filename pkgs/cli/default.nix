# SPDX-License-Identifier: MIT
#
# The `pip-purifier` command. It runs the pip of this package set, which is
# also the pip that buildPipProject runs, so the lock run resolves with the
# pip that will install offline. `install`, `pip` and `publish` build with
# the Nix library and the nixpkgs of this package set.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  git,
  mercurial,
  subversion,
  breezy,
  mitm-cache,
  openssl,
  uv,
  path,
}:
let
  python = python3.withPackages (ps: [
    ps.pip
    ps.build
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "pip-purifier";
  version = lib.removeSuffix "\n" (builtins.readFile ../../version.txt);

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../nix/lib
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/pip-purifier
    cp src/pip_purifier.py $out/share/pip-purifier/
    cp -r nix/lib $out/share/pip-purifier/nix-lib
    makeWrapper ${python.interpreter} $out/bin/pip-purifier \
      --add-flags "-I $out/share/pip-purifier/pip_purifier.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          git
          mercurial
          subversion
          breezy
          mitm-cache
          openssl
          uv
        ]
      } \
      --set PIP_PURIFIER_NIX_LIB $out/share/pip-purifier/nix-lib \
      --set PIP_PURIFIER_PYTHON ${python3.interpreter} \
      --set PIP_PURIFIER_NIXPKGS ${path}
    runHook postInstall
  '';

  meta = {
    description = "Lock, install and publish pip projects that Nix builds";
    license = lib.licenses.mit;
    mainProgram = "pip-purifier";
  };
}
