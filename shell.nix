{ pkgs ? import <nixpkgs> { } }:
with pkgs;
let
  hpkgs = import ./nix/haskell-packages.nix { inherit pkgs; };
  ghcWithDeps = hpkgs.ghcWithPackages (p: with p; [
    aeson
    async
    bytestring
    containers
    effectful-core
    effectful-th
    exceptions
    hjsonpointer
    influxdb
    lens
    megaparsec
    monad-logger
    mtl
    net-mqtt
    network-uri
    optparse-applicative
    scientific
    sqlite-simple
    stm
    text
    time
    transformers
    # test deps
    QuickCheck
    hedgehog
    hedgehog-corpus
    tasty
    tasty-hedgehog
    tasty-hunit
    tasty-quickcheck
  ]);
in
mkShell {
  buildInputs = [
    ghcWithDeps
    sqlite-interactive
    stylish-haskell
    hlint
    ghcid
    hpkgs.haskell-language-server
    cabal-install
    hpack
    zlib
  ];

  shellHook = ''
    # ...
  '';
}
