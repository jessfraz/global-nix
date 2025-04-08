{
  description = "Desktop and laptop configuration for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    unstable.url = "nixpkgs/nixos-unstable";

    # rust, see https://github.com/nix-community/fenix#usage
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "unstable";
    };
  };

  outputs = { self, nixpkgs, unstable, fenix }: {
    packages."aarch64-darwin".default = fenix.packages."aarch64-darwin".minimal.toolchain;


    packages."aarch64-darwin".default = let
      pkgs = nixpkgs.legacyPackages."aarch64-darwin";
      unstablePkgs = unstable.legacyPackages."aarch64-darwin";
    in pkgs.buildEnv {
      name = "home-packages";
      paths = with pkgs; [
        bash
        bash-completion
        curl
        (fenix.complete.withComponents [
          "cargo"
          "clippy"
          "rust-src"
          "rustc"
          "rustfmt"
        ])
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
        rust-analyzer-nightly
        silver-searcher
        starship
        tree
        uv
        yarn
      ];
    };
  };
}
