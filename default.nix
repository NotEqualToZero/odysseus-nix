# Non-flake entry point. Usable with npins or fetchTarball:
#
#   # In nixos-config with npins:
#   (import sources.odysseus-nix).nixosModules.default
#
#   # Or with a fetchTarball:
#   (import (fetchTarball "https://github.com/NotEqualToZero/odysseus-nix/archive/main.tar.gz")).nixosModules.default

let
  sources = import ./npins;
in {
  nixosModules.default  = import ./module.nix { odysseus = sources.odysseus; };
  nixosModules.odysseus = import ./module.nix { odysseus = sources.odysseus; };
}
