# global-nix

Global nix configuration for my desktop and laptops.

# Installation

Refer to the instructions in [github.com/DeterminateSystems/nix-installer](https://github.com/DeterminateSystems/nix-installer).

## MacOS

1. `nix build .#darwinConfigurations.macinator.system`
2. `./result/sw/bin/darwin-rebuild switch --flake .#macinator`

To cleanup the world run `nix store gc`
