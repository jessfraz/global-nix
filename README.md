# global-nix

Global nix configuration for my desktop and laptops.

These are just mine. They are imperfect in so many ways, but they work. I tried not to use a lot of plugins and just the raw Nix language. I like flakes. I get some people don't but I do :) sue me.

# Installation

> **NOTE:** Don't actually install these configs on your machine. My username is hard coded places!!

Refer to the instructions in [github.com/DeterminateSystems/nix-installer](https://github.com/DeterminateSystems/nix-installer). Do the vanilla install on MacOS so that we can use the `darwin-rebuild` command.

## MacOS

1. `nix build .#darwinConfigurations.macinator.system`
2. `./result/sw/bin/darwin-rebuild switch --flake .#macinator`

**OR**

If nix is already installed, you can just do:

`darwin-rebuild switch --flake .#macinator`

## Linux

`nixos-rebuild switch --flake .#system76`


## Shared

To cleanup the world run `nix store gc`

# Helpful Links

- [NixOS Module Source](https://github.com/NixOS/nixpkgs/tree/master/nixos/modules)
- [Home Manager Module Source](https://github.com/nix-community/home-manager/tree/master/modules)
- [nix-darwin Module Source](https://github.com/nix-darwin/nix-darwin/tree/master/modules)
- [Nix lang visual 'splainer](https://zaynetro.com/explainix)

# My personal opinon on how to get started.

Don't start here. Start with a flake that just installs some packages on your host. Drink a bit of that koolaid, install more things, uninstall things. Make flakes in specific repos to use `nix develop` devShells or package binaries in a repo. THEN, if you are thinking this is neat and want to go deeper, start looking into nixOS and darwin-nix for configuring your machines. This was how I went about it.

The reason I mention this is THERE IS A LOT OF CONTENT ON NIX out there and SO MANY different ways to do things. If you start with a big goal its too much information overhead all at once. _First_, dip your toes into just flakes. (Of course some people will say fuck flakes but I like them, personally. This is the type of information overhead and opinions I'm talking about).

## Other tips

- Claude and OpenAI are decent at Nix files. But you have to know what to ask for or else they will fuck it all up. It's almost better to be like "deep research X nix specific thing and tell me your findings". This will eliminate the overhead (all us nerds do) of learning something new and going super deep on blogs.

- Use the links above to the module sources. I found this the best way to get the current options for specific modules.
