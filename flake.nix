{
  description = "Desktop and laptop configuration for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    unstable.url = "nixpkgs/nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "unstable";
    };
  };

  outputs = { self, nixpkgs, unstable, rust-overlay }: {

    packages."aarch64-darwin".default = let
      pkgs = nixpkgs.legacyPackages."aarch64-darwin";
      unstablePkgs = unstable.legacyPackages."aarch64-darwin";
    in pkgs.buildEnv {
      name = "home-packages";
      paths = with pkgs; [
        bash
        bash-completion
        curl
        rust-overlay.packages."aarch64-darwin".rust-bin.stable.latest.default # rust
        gh
        git
        git-lfs
        gnumake
        gnupg
        gnused
        go
        jq
        just
        neovim
        nodejs
        ripgrep
        #rust-analyzer-nightly
        silver-searcher
        starship
        tree
        uv
        yarn
      ];
    };
  };
}
