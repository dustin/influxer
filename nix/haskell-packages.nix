{ pkgs }:
pkgs.haskellPackages.override {
  overrides = self: super: {
    # Fork with fixes; the Hackage release is marked broken in nixpkgs.
    hjsonpointer = pkgs.haskell.lib.dontCheck (self.callCabal2nix "hjsonpointer"
      (pkgs.fetchFromGitHub {
        owner = "dustin";
        repo = "hjsonpointer";
        rev = "3def4c51bebb43e1250eac894788eba3c7eb507f";
        hash = "sha256-9yvWI4lWCfFCwD77z7Cvz7PjFzlZPgGo9l5taShA+dw=";
      })
      { });
  };
}
