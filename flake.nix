{
  description = "Desktop and laptop configuration for NixOS and macOS";

  nixConfig = {
    extra-substituters = [
      "https://cache.flakehub.com"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
      "cache.flakehub.com-4:Asi8qIv291s0aYLyH6IOnr5Kf6+OF14WVjkE6t3xMio="
      "cache.flakehub.com-5:zB96CRlL7tiPtzA9/WKyPkp3A2vqxqgdgyTVNGShPDU="
      "cache.flakehub.com-6:W4EGFwAGgBj3he7c5fNh9NkOXw0PUVaxygCVKeuvaqU="
      "cache.flakehub.com-7:mvxJ2DZVHn/kRxlIaxYNMuDG1OvMckZu32um1TadOR8="
      "cache.flakehub.com-8:moO+OVS0mnTjBTcOUh2kYLQEd59ExzyoW1QgQ8XAARQ="
      "cache.flakehub.com-9:wChaSeTI6TeCuV/Sg2513ZIM9i0qJaYsF+lZCXg0J6o="
      "cache.flakehub.com-10:2GqeNlIp6AKp4EF2MVbE1kBOp9iBSyo0UPR9KoR0o1Y="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # rust, see https://github.com/nix-community/fenix#usage
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
    };

    dotfiles = {
      url = "github:jessfraz/dotfiles";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dotvim = {
      url = "git+https://github.com/jessfraz/.vim";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zoo-cli = {
      url = "github:kittycad/cli";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex = {
      url = "github:jessfraz/codex/add-github-action-for-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    nix-darwin,
    fenix,
    ghostty,
    dotfiles,
    dotvim,
    zoo-cli,
    codex,
  } @ inputs: let
    # Global variables
    username = "jessfraz";
    githubUsername = username; # This is the case for me but might not be for everyone.
    gitGpgKey = "18F3685C0022BFF3";
    gitName = "Jessie Frazelle";
    gitEmail = "github@jessfraz.com";

    # tpl variables
    tplIpPrefix = "10.42.9";
    tplResolverFile = "resolver/tpl"; # serves *.tpl

    overlay = final: prev: {
      homebridge = prev.callPackage ./pkgs/homebridge.nix {};
    };

    # Avoid flaky Node.js test phases on Darwin by disabling checks.
    overlaySkipNodeChecks = final: prev: {
      nodejs_20 = prev.nodejs_20.overrideAttrs (_: { doCheck = false; });
      nodejs_22 = prev.nodejs_22.overrideAttrs (_: { doCheck = false; });
    };

    # Define the systems we want to support
    supportedSystems = ["aarch64-darwin" "x86_64-linux"];

    # Helper function to generate attributes for each system
    forAllSystems = f:
      builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        })
        supportedSystems);

    # Create packages for each system
    mkPackages = system: let
      # Apply allowUnfree to all package sets
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
        overlays = [overlay overlaySkipNodeChecks];
      };
      fenixPkgs = fenix.packages.${system};
      zooCli = zoo-cli.packages.${pkgs.system}.zoo;
      codexCli = codex.packages.${pkgs.system}.codex-rs;

      # Common packages for all systems
      commonPackages = with pkgs; [
        _1password-cli
        ast-grep
        bash
        bash-completion
        claude-code
        codexCli
        coreutils
        curl
        # Provide python with the 'rich' library for nicer stderr rendering
        # in scripts/prepare-commit-msg.py.
        (python312.withPackages (ps: [ps.rich]))
        (fenixPkgs.complete.withComponents [
          "cargo"
          "clippy"
          "rust-src"
          "rustc"
          "rustfmt"
        ])
        findutils
        git
        git-lfs
        gnumake
        gnupg
        gnused
        jq
        just
        nodejs_22
        pinentry-tty
        silver-searcher
        starship
        tree
        uv
        watch
        yarn
        zooCli
      ];

      # System-specific packages
      systemSpecificPackages =
        if pkgs.stdenv.isLinux
        then
          # Linux-specific packages
          with pkgs; [
            _1password-gui
            google-chrome
            pinentry-tty
            tailscale
            xclip
          ]
        else
          # macOS-specific packages
          with pkgs; [
            # Add macOS-specific packages here
            pinentry_mac
          ];
    in
      pkgs.buildEnv {
        name = "home-packages";
        paths = commonPackages ++ (builtins.filter (p: p != null) systemSpecificPackages);
      };
  in {
    # Generate packages for all supported systems
    packages = forAllSystems (system: {
      default = mkPackages system;
    });

    # NixOS configurations
    nixosConfigurations = {
      system76 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs username githubUsername gitGpgKey gitName gitEmail;
          homeDir = "/home/${username}";
          hostname = "system76";
        };
        system = "x86_64-linux"; # or aarch64-linux if you're on ARM
        modules = [
          ./hosts/base/configuration.nix
          ./hosts/linux/configuration.nix
          ./hosts/linux/system76/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              inherit inputs username githubUsername gitGpgKey gitName gitEmail;
              homeDir = "/home/${username}";
              hostname = "system76";
            };
            home-manager.users.${username}.imports = [
              dotfiles.homeManagerModules.default
              dotvim.homeManagerModules.default
              ./home/default.nix
              ./home/hosts/linux/default.nix
            ];
          }
        ];
      };
    };

    # macOS configurations
    darwinModules.coredns = import ./modules/coredns.nix;
    darwinModules.homebridge = import ./modules/homebridge.nix;
    darwinModules.scrypted = import ./modules/scrypted.nix;

    darwinConfigurations = {
      # M4 Max MacBook Pro
      macinator = nix-darwin.lib.darwinSystem {
        specialArgs = {
          inherit inputs username githubUsername gitGpgKey gitName gitEmail tplIpPrefix tplResolverFile;
          homeDir = "/Users/${username}";
          hostname = "macinator";
        };
        system = "aarch64-darwin";
        modules = [
          ./hosts/base/configuration.nix
          ./hosts/darwin/configuration.nix
          ./hosts/darwin/resolver-tpl.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              inherit inputs username githubUsername gitGpgKey gitName gitEmail tplIpPrefix tplResolverFile;
              homeDir = "/Users/${username}";
              hostname = "macinator";
            };
            home-manager.users.${username}.imports = [
              dotfiles.homeManagerModules.default
              dotvim.homeManagerModules.default
              ./home/default.nix
              ./home/hosts/darwin/default.nix
            ];
          }
        ];
      };

      # M1 Mac Mini
      macmini = let
        username = "minitron";
        homeDir = "/Users/${username}";
        hostname = "macmini";
        volumesPath = "/Volumes/XTRM-Q/volumes";
        system = "aarch64-darwin";
      in
        nix-darwin.lib.darwinSystem {
          system = system;

          pkgs = import nixpkgs {
            system = system;
            overlays = [overlay overlaySkipNodeChecks];
          };

          specialArgs = {
            inherit inputs username githubUsername gitGpgKey gitName gitEmail homeDir hostname volumesPath tplIpPrefix tplResolverFile;
          };
          modules = [
            self.darwinModules.coredns
            self.darwinModules.homebridge
            self.darwinModules.scrypted
            ./hosts/base/configuration.nix
            ./hosts/darwin/configuration.nix
            ./hosts/darwin/home-server.nix
            home-manager.darwinModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = {
                inherit inputs username githubUsername gitGpgKey gitName gitEmail homeDir hostname volumesPath tplIpPrefix tplResolverFile;
              };
              home-manager.users.${username}.imports = [
                dotfiles.homeManagerModules.default
                dotvim.homeManagerModules.default
                ./home/default.nix
                ./home/hosts/darwin/default.nix
                ./home/hosts/darwin/home-server.nix
              ];
            }
          ];
        };
    };
  };
}
