{
  description = "Desktop and laptop configuration for NixOS and macOS";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

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

    dotfiles = {
      url = "github:jessfraz/dotfiles";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dotvim = {
      url = "git+https://github.com/jessfraz/.vim?submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland-contrib = {
      url = "github:hyprwm/contrib";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    nix-darwin,
    fenix,
    dotfiles,
    dotvim,
    hyprland,
    hyprland-contrib,
    hyprland-plugins,
  } @ inputs: let
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
      };
      fenixPkgs = fenix.packages.${system};

      # Check if system is Linux-based
      isLinux = builtins.match ".*-linux" system != null;

      # Common packages for all systems
      commonPackages = with pkgs; [
        _1password-cli
        bash
        bash-completion
        claude-code
        coreutils
        curl
        (fenixPkgs.stable.withComponents [
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
        nodejs
        pinentry-tty
        silver-searcher
        starship
        tree
        uv
        watch
        yarn
      ];

      # System-specific packages
      systemSpecificPackages =
        if isLinux
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
        specialArgs = {inherit inputs;};
        system = "x86_64-linux"; # or aarch64-linux if you're on ARM
        modules = [
          ./hosts/base/configuration.nix
          ./hosts/linux/configuration.nix
          ./hosts/linux/system76/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {inherit inputs;};
            home-manager.users.jessfraz.imports = [
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
    darwinConfigurations = {
      macinator = nix-darwin.lib.darwinSystem {
        specialArgs = {inherit inputs;};
        system = "aarch64-darwin";
        modules = [
          ./hosts/base/configuration.nix
          ./hosts/darwin/configuration.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {inherit inputs;};
            home-manager.users.jessfraz.imports = [
              dotfiles.homeManagerModules.default
              dotvim.homeManagerModules.default
              ./home/default.nix
              ./home/hosts/darwin/default.nix
            ];
          }
        ];
      };
    };
  };
}
