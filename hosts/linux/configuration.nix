{
  pkgs,
  username,
  ...
}: {
  imports = [
    ./disable-sleep-on-ssh.nix
  ];

  nix = {
    enable = true;
    optimise = {
      automatic = true;
    };
  };

  nixpkgs.config = {
    allowUnfree = true;
    nvidia.acceptLicense = true;
  };

  virtualisation = {
    docker = {
      enable = true;
    };
  };

  networking = {
    networkmanager = {
      enable = true;
    };

    nameservers = ["8.8.8.8" "8.8.4.4" "1.1.1.1"];

    firewall = {
      allowedTCPPorts = [
        8585 # running machine-api locally
      ];
      allowedUDPPorts = [
        5353 # mDNS allow for machine-api
      ];
    };
  };

  users.groups.plugdev = {};
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = ["audio" "docker" "networkmanager" "wheel" "libvirtd" "plugdev" "onepassword-cli" "onepassword"];
  };

  boot = {
    # Bootloader.
    loader = {
      efi.canTouchEfiVariables = true;
    };
  };

  # Set your time zone.
  time = {
    timeZone = "America/Los_Angeles";
  };

  # Select internationalisation properties.
  i18n = {
    defaultLocale = "en_US.UTF-8";

    extraLocaleSettings = {
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
  };

  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      font-awesome
      source-han-sans
      source-han-serif
    ];
    fontconfig.defaultFonts = {
      serif = ["Noto Serif" "Source Han Serif"];
      sansSerif = ["Noto Sans" "Source Han Sans"];
    };
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 1w";
  };

  environment = {
    systemPackages = with pkgs; [
      # Auth with 1Password
      polkit_gnome
    ];
  };

  programs = {
    _1password-gui = {
      enable = true;

      polkitPolicyOwners = [username];
      package = pkgs._1password-gui;
    };

    # 1Password CLI
    _1password = {
      enable = true;

      package = pkgs._1password-cli;
    };

    chromium = {
      enable = true;
    };
  };

  services = {
    tailscale = {
      enable = true;

      extraUpFlags = ["--ssh"];
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
