{
  description = "Influxer";
  nixConfig.bash-prompt = "\[influxer-dev\]$ ";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hpkgs = import ./nix/haskell-packages.nix { inherit pkgs; };
        in
        {
          packages.default = hpkgs.callCabal2nix "influxer" self { };
          devShells.default = import ./shell.nix { inherit pkgs; };
        }
      );
}
