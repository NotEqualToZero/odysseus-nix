{
  description = "Nix packaging for Odysseus AI assistant UI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };

    odysseus = {
      url   = "github:pewdiepie-archdaemon/odysseus";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, odysseus, ... }:
    let
      lib     = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = lib.genAttrs systems;
    in {
      # NixOS module — the main output
      nixosModules.default = import ./module.nix {
        inherit lib odysseus;
      };
      nixosModules.odysseus = self.nixosModules.default;

      # Per-system package output (nix build / nix run)
      packages = forAllSystems (system:
        let
          pkgs  = nixpkgs.legacyPackages.${system};
          built = import ./package.nix {
            inherit lib pkgs odysseus;
            extras = [];
          };
        in {
          default  = built.package;
          odysseus = built.package;
        }
      );
    };
}
