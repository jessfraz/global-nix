{ inputs, ... }:
{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      programs.ghostty = {
        enable = true;

        package =
          if pkgs.stdenv.isLinux then inputs.ghostty.packages.${pkgs.stdenv.system}.default else null; # We install on our own on macOS

        settings = {
          font-family = "Hack Nerd Font Mono";
          # SUGGESTION
          # font-family = "monospace";
          theme = "Ayu Mirage";
          macos-titlebar-style = "tabs";
          background-opacity = 0.9;
          background-blur-radius = 20;
        };

        enableBashIntegration = true;
      };
    };
}
