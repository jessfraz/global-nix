{ lib, ... }:
{
  nixpkgs.allowUnfreePackages = [ "claude-code" ];

  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkOrder 400 [ pkgs.claude-code ];
    };

  # SUGGESTION: this, instead
  # flake.modules.homeManager.base =
  #   { pkgs, ... }:
  #   {
  #     home.packages = [ pkgs.claude-code ];
  #   };
}
