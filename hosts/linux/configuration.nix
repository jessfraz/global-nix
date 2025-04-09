{
  config,
  pkgs,
  inputs,
  ...
}: {
  users.users.jessfraz = {
    isNormalUser = true;
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
  ];
}
