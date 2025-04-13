{
  # Add ability to used TouchID for sudo authentication.
  flake.modules.darwin.base.security.pam.services.sudo_local = {
    enable = true;
    touchIdAuth = true;
  };
}
