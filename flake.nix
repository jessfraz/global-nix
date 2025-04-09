{
  description = "Desktop and laptop configuration for NixOS and macOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    unstable.url = "nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "unstable";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "unstable";
    };

    # rust, see https://github.com/nix-community/fenix#usage
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "unstable";
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
    };

    dotfiles = {
      url = "github:jessfraz/dotfiles";
    };

    dotvim = {
      url = "git+https://github.com/jessfraz/.vim?submodules=1";
    };
  };

  outputs = {
    self,
    nixpkgs,
    unstable,
    home-manager,
    nix-darwin,
    fenix,
    ghostty,
    dotfiles,
    dotvim,
  } @ inputs: let
    # Define the systems we want to support
    supportedSystems = ["aarch64-darwin" "x86_64-linux" "aarch64-linux"];

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
          allowUnfreePredicate = _: true;
        };
      };
      unstablePkgs = import unstable {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnfreePredicate = _: true;
        };
      };
      fenixPkgs = fenix.packages.${system};

      # Check if system is Linux-based for ghostty
      isLinux = builtins.match ".*-linux" system != null;
      # Only include ghostty on Linux systems
      ghosttyPkgs =
        if isLinux
        then ghostty.packages.${system}
        else null;

      # Common packages for all systems
      commonPackages = with pkgs; [
        _1password-cli
        bash
        bash-completion
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
        gh
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
            # Add Linux-specific packages here
            # For example, if ghostty is only for Linux:
            (
              if ghosttyPkgs != null
              then ghosttyPkgs.default
              else null
            )
            tailscale
            pinentry-tty
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

    # Make sure we define a default package per system
    defaultPackage = forAllSystems (system: self.packages.${system}.default);

    # NixOS configurations
    nixosConfigurations = {
      system76 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux"; # or aarch64-linux if you're on ARM
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/base/configuration.nix
          ./hosts/linux/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jessfraz.imports = [
              dotfiles.homeManagerModules.default
              dotvim.homeManagerModules.default
              ./home/default.nix
            ];
          }
        ];
      };
    };

    # macOS configurations
    darwinConfigurations = {
      macinator = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/base/configuration.nix
          ./hosts/darwin/configuration.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jessfraz.imports = [
              dotfiles.homeManagerModules.default
              dotvim.homeManagerModules.default
              ./home/default.nix
            ];
          }
        ];
      };
    };
  };
}
