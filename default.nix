# flake-compat shim — lets non-flake consumers use the flake outputs via
# plain `import`. Reads flake.lock to fetch flake-compat at the pinned rev,
# evaluates flake.nix, and returns its outputs.
#
# Non-flake NixOS module usage (channels-based config):
#
#   imports = [
#     (import (fetchTarball
#       "https://github.com/your-user/odysseus-nix/archive/main.tar.gz")
#     ).nixosModules.default
#   ];
#   services.odysseus.enable = true;
#
# Or with a local checkout:
#   imports = [ (import /path/to/odysseus-nix).nixosModules.default ];

(import (
  let
    lock     = builtins.fromJSON (builtins.readFile ./flake.lock);
    nodeName = lock.nodes.root.inputs.flake-compat;
    node     = lock.nodes.${nodeName}.locked;
  in
    fetchTarball {
      url    = node.url or
        "https://github.com/NixOS/flake-compat/archive/${node.rev}.tar.gz";
      sha256 = node.narHash;
    }
) {
  src = ./.;
}).defaultNix
