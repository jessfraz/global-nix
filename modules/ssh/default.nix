{
  flake.modules = {
    nixos.desktop.services = {
      openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
      };
    };

    homeManager.base.programs.ssh = {
      enable = true;
      addKeysToAgent = "yes";
    };
  };
}
