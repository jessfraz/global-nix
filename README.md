# global-nix

Global nix configuration for my desktop and laptops.

# Installation

Refer to the instructions in [github.com/DeterminateSystems/nix-installer](https://github.com/DeterminateSystems/nix-installer).

1. For initial installation, run `nix profile install .` (inside the folder). This registered the flake.nix as part of the global nix profile. 
2. Running `nix profile list` shows the profile. 
3. To update, you need to run `nix profile upgrade global-nix`.

To cleanup the world run `nix store gc`
