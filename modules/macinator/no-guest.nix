{
  # Disable the guest user account.
  flake.modules.darwin."darwinConfigurations/macinator".system.defaults.loginwindow.GuestEnabled =
    false;
}
