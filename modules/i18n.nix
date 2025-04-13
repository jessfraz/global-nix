{ lib, ... }:
let
  defaultLocale = "en_US.UTF-8";
in
{
  flake.modules.nixos.desktop.i18n = {
    inherit defaultLocale;

    extraLocaleSettings =
      [
        "LC_ADDRESS"
        "LC_IDENTIFICATION"
        "LC_MEASUREMENT"
        "LC_MONETARY"
        "LC_NAME"
        "LC_NUMERIC"
        "LC_PAPER"
        "LC_TELEPHONE"
        "LC_TIME"
      ]
      |> lib.flip lib.genAttrs (_: defaultLocale);
  };
}
