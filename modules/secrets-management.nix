{ lib, config, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      home-packages-gui = lib.mkMerge [
        (lib.mkOrder 100 [ pkgs._1password-cli ])
        # SUGGESTION: should this be only on linux? Also, deduplicate with the following line
        (lib.mkOrder 1700 [ pkgs.pinentry-tty ])
        (lib.optional pkgs.stdenv.isLinux pkgs.pinentry-tty |> lib.mkOrder 2600)
        (lib.optional pkgs.stdenv.isLinux pkgs._1password-gui |> lib.mkOrder 2400)
        (lib.optional pkgs.stdenv.isDarwin pkgs.pinentry_mac |> lib.mkOrder 2350)
      ];
    };

  nixpkgs.allowUnfreePackages = [
    "1password-cli"
    "1password"
  ];

  flake.modules = {
    homeManager = {
      base.programs.bash.sessionVariables.SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
      gui =
        { pkgs, ... }:
        {
          # Use 1Password for passwords.
          targets.darwin.defaults."com.apple.Safari".AutoFillPasswords = lib.mkIf pkgs.stdenv.isDarwin false;
        };
    };

    nixos.desktop =
      { pkgs, ... }:
      {
        programs = {
          _1password-gui = {
            enable = true;

            polkitPolicyOwners = [ config.flake.meta.owner.username ];
            package = pkgs._1password-gui;
          };

          # 1Password CLI
          _1password = {
            enable = true;

            package = pkgs._1password-cli;
          };
        };

        users.users.${config.flake.meta.owner.username}.extraGroups = [
          "onepassword-cli"
          "onepassword"
        ];

        # Auth with 1Password
        environment.systemPackages = [ pkgs.polkit_gnome ];
      };
  };
}
