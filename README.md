# global-nix

Global nix configuration for my desktop and laptops.

# Installation

Refer to the instructions in [github.com/DeterminateSystems/nix-installer](https://github.com/DeterminateSystems/nix-installer). Do the vanilla install on MacOS so that we can use the `darwin-rebuild` command.

## MacOS

1. `nix build .#darwinConfigurations.macinator.system`
2. `./result/sw/bin/darwin-rebuild switch --flake .#macinator`

**OR**

If nix is already installed, you can just do:

`darwin-rebuild switch --flake .#macinator`

## Linux

1. `nix build .`
2. `./result/sw/bin/nixos-rebuild switch --flake .#system76`

**OR**

If nix is already installed, you can just do:

`nixos-rebuild switch --flake .#system76`


## Shared

To cleanup the world run `nix store gc`
