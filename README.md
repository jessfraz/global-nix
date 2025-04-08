# global-nix

Global nix configuration for my desktop and laptops.

# Installation

Refer to the instructions in [github.com/DeterminateSystems/nix-installer](https://github.com/DeterminateSystems/nix-installer). Do the vanilla install on MacOS so that we can use the `darwin-rebuild` command.

## MacOS

1. `nix build .#darwinConfigurations.macinator.system`
2. `./result/sw/bin/darwin-rebuild switch --flake .#macinator`

To cleanup the world run `nix store gc`
