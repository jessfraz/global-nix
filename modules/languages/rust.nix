{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui =
        let
          fenixPkgs = inputs.fenix.packages.${pkgs.system};
        in
        lib.mkOrder 700 [
          # https://github.com/nix-community/fenix#usage
          (fenixPkgs.stable.withComponents [
            "cargo"
            "clippy"
            "rust-src"
            "rustc"
            "rustfmt"
          ])
        ];
    };

  # flake.modules.homeManager.base =
  #   { pkgs, ... }:
  #   {
  #     home.packages =
  #       let
  #         fenixPkgs = inputs.fenix.packages.${pkgs.system};
  #       in
  #       [
  #         # https://github.com/nix-community/fenix#usage
  #         (fenixPkgs.stable.withComponents [
  #           "cargo"
  #           "clippy"
  #           "rust-src"
  #           "rustc"
  #           "rustfmt"
  #         ])
  #       ];
  #   };
}
