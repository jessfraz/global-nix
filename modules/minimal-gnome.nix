{
  flake.modules.nixos.desktop =
    { pkgs, ... }:
    {
      services.xserver = {
        enable = true;
        displayManager.gdm.enable = true;

        desktopManager = {
          gnome.enable = true;
          xterm.enable = false;
        };

        excludePackages = [ pkgs.xterm ];

        # Configure keymap in X11
        xkb = {
          layout = "us";
          variant = "";
        };
      };

      # Remove stupid gnome packages.
      environment.gnome.excludePackages = with pkgs; [
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
