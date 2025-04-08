{
  config,
  pkgs,
  inputs,
  ...
}: {
  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 6;
}
