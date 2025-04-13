let
  commonFontPkgs = pkgs: [ pkgs.nerd-fonts.hack ];
in
{
  flake.modules = {
    nixos.desktop =
      { pkgs, ... }:
      {
        fonts = {
          packages =
            (with pkgs; [
              noto-fonts
              noto-fonts-cjk-sans
              noto-fonts-emoji
              font-awesome
              source-han-sans
              source-han-sans-japanese
              source-han-serif-japanese
            ])
            ++ commonFontPkgs pkgs;

          fontconfig.defaultFonts = {
            serif = [
              "Noto Serif"
              "Source Han Serif"
            ];
            sansSerif = [
              "Noto Sans"
              "Source Han Sans"
            ];
            # SUGGESTION
            #monospace = [ "Hack Nerd Font Mono" ];
          };
        };
      };

    darwin.gui =
      { pkgs, ... }:
      {
        fonts.packages = commonFontPkgs pkgs;
      };

    homeManager.gui.fonts.fontconfig.enable = true;
  };
}
