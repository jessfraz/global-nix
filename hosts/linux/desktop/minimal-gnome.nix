{
  config,
  pkgs,
  ...
}: {
  # Enable the X11 windowing system.
  services = {
    xserver = {
      enable = true;

      videoDrivers = ["nvidia"];

      # Enable the GNOME Desktop Environment.
      displayManager = {
        gdm = {enable = true;};
        gnome = {
          enable = true;
        };
        xterm = {
          enable = false;
        };
      };

      # Configure keymap in X11
      xkb = {
        layout = "us";
        variant = "";
      };

      excludePackages = [pkgs.xterm];

      # Enable touchpad support (enabled default in most desktopManager).
      # libinput.enable = true;
    };

    printing = {
      # Enable CUPS to print documents.
      enable = false;
    };

    # Enable sound with pipewire.
    pulseaudio = {
      enable = false;
    };
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      # If you want to use JACK applications, uncomment this
      #jack.enable = true;

      # use the example session manager (no others are packaged yet so this is enabled by default,
      # no need to redefine it in your config for now)
      #media-session.enable = true;
    };
  };

  # Remove stupid gnome packages.
  environment = {
    gnome.excludePackages = with pkgs; [
      baobab # disk usage analyzer
      cheese # photo booth
      eog # image viewer
      epiphany # web browser
      gedit # text editor
      simple-scan # document scanner
      totem # video player
      yelp # help viewer
      evince # document viewer
      file-roller # archive manager
      geary # email client
      seahorse # password manager

      # these should be self explanatory
      gnome-calculator
      gnome-calendar
      gnome-characters
      gnome-clocks
      gnome-connections
      gnome-contacts
      gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      gnome-photos
      gnome-screenshot
      gnome-system-monitor
      gnome-tour
      gnome-weather
      gnome-disk-utility
    ];
  };
}
