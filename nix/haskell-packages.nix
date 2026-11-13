{ pkgs }:
pkgs.haskellPackages.override {
  overrides = self: super: {
    # influxer needs >= 0.8.8.0 (on Hackage 2026-11-05); nixpkgs still has
    # 0.8.6.3. Drop this once haskellPackages.net-mqtt catches up.
    net-mqtt = pkgs.haskell.lib.dontCheck (self.callHackageDirect {
      pkg = "net-mqtt";
      ver = "0.8.8.0";
      sha256 = "1xg3yhzis53zw9bid9kf028f19wpbb98rz6xgwbz10j3pcwjm0yi";
    } { });
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
