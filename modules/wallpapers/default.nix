{pkgs ? import <nixpkgs> {}}:
pkgs.stdenv.mkDerivation {
  name = "nixos-wallpapers";
  src = pkgs.fetchgit {
    url = "https://github.com/NixOS/nixos-artwork";
    rev = "c68a508b95baa0fcd99117f2da2a0f66eb208bbf";
    sparseCheckout = [
      "wallpapers/"
    ];
    hash = "sha256-J4ffpoOrvjETetmY+WfzVCPbNYNw/Abz/EOqik1qd4M=";
  };
  buildPhase = ''
    # nothing, we just don't want default build from makefile
  '';
  installPhase = ''
    mkdir -p $out/share/wallpapers
    cp $src/wallpapers/*.png $out/share/wallpapers/
  '';
}
