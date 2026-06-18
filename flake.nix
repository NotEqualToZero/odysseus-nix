{
  description = "Nix packaging for Odysseus AI assistant UI";

  inputs = {
    nixpkgs.url          = "github:NixOS/nixpkgs/nixos-unstable";

    odysseus = {
      url   = "github:pewdiepie-archdaemon/odysseus";
      flake = false;  # plain source, not a flake
    };

    pyproject-nix = {
      url    = "github:pyproject-nix/pyproject.nix";
      inputs = { nixpkgs.follows = "nixpkgs"; };
    };

    uv2nix = {
      url    = "github:pyproject-nix/uv2nix";
      inputs = {
        nixpkgs.follows      = "nixpkgs";
        pyproject-nix.follows = "pyproject-nix";
      };
    };

    pyproject-build-systems = {
      url    = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        nixpkgs.follows       = "nixpkgs";
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows        = "uv2nix";
      };
    };
  };

  outputs = { self, nixpkgs, odysseus, pyproject-nix, uv2nix, pyproject-build-systems }:
    let
      lib     = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = lib.genAttrs systems;
    in {
      # ---------------------------------------------------------------- #
      # NixOS module — the main output, importable in configuration.nix  #
      # ---------------------------------------------------------------- #
      nixosModules.default = import ./default.nix {
        inherit lib odysseus pyproject-nix uv2nix pyproject-build-systems;
      };

      # Convenience alias
      nixosModules.odysseus = self.nixosModules.default;

      # ---------------------------------------------------------------- #
      # Per-system package output (optional, for nix build / nix run)    #
      # ---------------------------------------------------------------- #
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mod  = import ./default.nix {
            inherit lib pkgs odysseus pyproject-nix uv2nix pyproject-build-systems;
          };
        in {
          default  = mod.package;
          odysseus = mod.package;
        }
      );
    };
}
