{
  pkgs,
  inputs,
  ...
}: let
in {
  home.packages = with pkgs; [
    # toolbar
    waybar

    #wayland screenshots
    inputs.hyprland-contrib.packages.${pkgs.system}.grimblast

    # wayland copy/paste
    wl-clipboard
  ];

  services = {
    # notifications
    mako = {
      enable = true;
      extraConfig = ''
        on-button-right=dismiss-all
      '';
    };

    hypridle = {
      enable = true;
      settings = {
        general = {
          lock_cmd = "pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
        };
        listener = [
          {
            timeout = 5 * 60;
            on-timeout = "loginctl lock-session";
          }
          {
            timeout = 6 * 60;
            on-timeout = "hyprctl dispatch dpms off";
            on-resume = "hyprctl dispatch dpms on";
          }
        ];
      };
    };
  };

  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        disable_loading_bar = true;
        grace = 300;
        hide_cursor = true;
        no_fade_in = false;
      };
      background = [
        {
          blur_passes = 1;
        }
      ];
      input-field = [
        {
          fade_on_empty = false;
          outline_thickness = 2;
          size = "300, 50";
        }
      ];
    };
  };

  # To be able to use gtk-launch.
  gtk = {
    enable = true;
    iconTheme = {
      name = "Pop";
      package = pkgs.pop-icon-theme;
    };
    theme = {
      name = "Pop";
      package = pkgs.pop-gtk-theme;
    };
  };

  wayland = {
    windowManager = {
      hyprland = {
        enable = true;
        package = inputs.hyprland.packages.${pkgs.system}.hyprland;

        plugins = [
          inputs.hyprland-plugins.packages.${pkgs.system}.borders-plus-plus
          inputs.hyprland-plugins.packages.${pkgs.system}.hyprbars
          inputs.hyprland-plugins.packages.${pkgs.system}.hyprtrails
        ];

        xwayland = {
          enable = true;
        };

        systemd = {
          enable = true;
          variables = ["--all"];
        };

        settings = {
          "$mod" = "SUPER";
          "debug:disable_logs" = false;
          "general:gaps_out" = 5;
          #"decoration:inactive_opacity" = 0.8;
          xwayland = {
            force_zero_scaling = true;
          };

          input = {
            kb_layout = "us";
            natural_scroll = true;
          };

          cursor = {
            no_hardware_cursors = true;
          };

          env = [
            "GBM_BACKEND,nvidia-drm"
            #"AQ_DRM_DEVICES,/dev/dri/by-path/pci-0000:01:00.0-card"
          ];

          exec-once = [
            "${pkgs.mako}/bin/mako"
            "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
            "${pkgs.waybar}/bin/waybar"
          ];

          layerrule = [];

          bind =
            [
              "$mod, C, sendshortcut, CTRL, C, class:(google-chrome)"
              "$mod, V, sendshortcut, CTRL, V, class:(google-chrome)"
              "$mod, X, sendshortcut, CTRL, X, class:(google-chrome)"
              "$mod, G, exec, ${pkgs.google-chrome}/bin/google-chrome-stable"
              "$mod, K, exec, ${pkgs.kitty}/bin/kitty"
              "$mod, Return, exec, gtk-launch com.mitchellh.ghostty.desktop"
              "$mod, Left, movewindow, l"
              "$mod, Right, movewindow, r"
              "$mod SHIFT, Apostrophe, killactive,"
              "$mod SHIFT, S, exec, ${inputs.hyprland-contrib.packages.${pkgs.system}.grimblast}/bin/grimblast --notify copy area"
            ]
            ++ (
              # workspaces
              # binds $mod + [shift +] {1..10} to [move to] workspace {1..10}
              builtins.concatLists (builtins.genList (
                  x: let
                    ws = let
                      c = (x + 1) / 10;
                    in
                      builtins.toString (x + 1 - (c * 10));
                  in [
                    "$mod, ${ws}, workspace, ${toString (x + 1)}"
                    "$mod SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
                  ]
                )
                10)
            );

          bindle = [
            ",XF86Launch4,   exec, ags -r 'recorder.start()'"
            ",Print,         exec, ags -r 'recorder.screenshot()'"
            "SHIFT,Print,    exec, ags -r 'recorder.screenshot(true)'"
            ",XF86MonBrightnessUp,   exec, ags -r 'brightness.screen += 0.05; indicator.display()'"
            ",XF86MonBrightnessDown, exec, ags -r 'brightness.screen -= 0.05; indicator.display()'"
            ",XF86KbdBrightnessUp,   exec, ags -r 'brightness.kbd++; indicator.kbd()'"
            ",XF86KbdBrightnessDown, exec, ags -r 'brightness.kbd--; indicator.kbd()'"
            ",XF86AudioRaiseVolume,  exec, ags -r 'audio.speaker.volume += 0.05; indicator.speaker()'"
            ",XF86AudioLowerVolume,  exec, ags -r 'audio.speaker.volume -= 0.05; indicator.speaker()'"
          ];
        };
      };
    };
  };
}
