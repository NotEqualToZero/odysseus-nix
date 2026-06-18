{
  description = "Nix packaging for Odysseus AI assistant UI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # flake-compat lets non-flake consumers import this repo via default.nix
    flake-compat = {
      url = "github:NixOS/flake-compat";
      flake = false;
    };

    odysseus = {
      url   = "github:pewdiepie-archdaemon/odysseus";
      flake = false;  # plain source, not a flake
    };

    pyproject-nix = {
      url    = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url    = "github:pyproject-nix/uv2nix";
      inputs = {
        nixpkgs.follows       = "nixpkgs";
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

  outputs = { self, nixpkgs, odysseus, pyproject-nix, uv2nix, pyproject-build-systems, ... }:
    let
      lib     = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = lib.genAttrs systems;
    in {
      # ---------------------------------------------------------------- #
      # NixOS module — the main output                                    #
      # ---------------------------------------------------------------- #
      nixosModules.default = import ./module.nix {
        inherit lib odysseus pyproject-nix uv2nix pyproject-build-systems;
      };

      nixosModules.odysseus = self.nixosModules.default;

      # ---------------------------------------------------------------- #
      # Per-system package output (for nix build / nix run)              #
      # Built directly from package.nix, not the module.                #
      # ---------------------------------------------------------------- #
      packages = forAllSystems (system:
        let
          pkgs  = nixpkgs.legacyPackages.${system};
          built = import ./package.nix {
            inherit lib pkgs odysseus pyproject-nix uv2nix pyproject-build-systems;
            extras = [];
          };
        in {
          default  = built.package;
          odysseus = built.package;
        }
      );
    };
}
