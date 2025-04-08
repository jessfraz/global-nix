{
  config,
  pkgs,
  ...
}: {
  programs.bash.enable = true;
  users.users.jessfraz = {
    description = "Jessie Frazelle";
    shell = pkgs.bash;
    home = "/Users/jessfraz";
  };

  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
