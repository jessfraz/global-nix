{
  config,
  pkgs,
  inputs,
  ...
}: {
  # Enable networking
  networking.networkmanager.enable = true;

  networking.nameservers = ["8.8.8.8" "8.8.4.4" "1.1.1.1"];

  users.groups.plugdev = {};
  users.users.jessfraz = {
    isNormalUser = true;
    extraGroups = ["audio" "docker" "networkmanager" "wheel" "libvirtd" "plugdev"];
  };

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk
      noto-fonts-emoji
      font-awesome
      source-han-sans
      source-han-sans-japanese
      source-han-serif-japanese
    ];
    fontconfig.defaultFonts = {
      serif = ["Noto Serif" "Source Han Serif"];
      sansSerif = ["Noto Sans" "Source Han Sans"];
    };
  };

  nix = {
    enable = true;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 1w";
    };
    optimise = {
      automatic = true;
    };
    settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["jessfraz"];
    };
    package = pkgs.nixVersions.stable;
  };

  services = {
    tailscale = {
      enable = true;
    };

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
  };
}
