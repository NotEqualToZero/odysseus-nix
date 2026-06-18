# flake-compat shim.
#
# This lets non-flake consumers use the repository's flake outputs via plain
# `import`. It reads flake.lock to fetch flake-compat at the pinned revision,
# evaluates flake.nix, and returns its outputs.
#
# NixOS module usage WITHOUT flakes (e.g. in a channels-based config):
#
#   { ... }:
#   {
#     imports = [
#       (import (fetchTarball "https://github.com/your-user/odysseus-nix/archive/main.tar.gz")).nixosModules.default
#     ];
#     services.odysseus.enable = true;
#   }
#
# Or with a local checkout:
#
#   imports = [ (import /path/to/odysseus-nix).nixosModules.default ];
#
# The returned attrset is the flake's outputs, plus a `default` attribute
# pointing at the current platform's default package.

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
