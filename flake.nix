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

    alejandra = {
      url = "github:kamadorueda/alejandra/3.0.0";
      inputs.nixpkgs.follows = "unstable";
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
    };
  };

  outputs = {
    self,
    nixpkgs,
    unstable,
    home-manager,
    nix-darwin,
    fenix,
    alejandra,
    ghostty,
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
      pkgs = nixpkgs.legacyPackages.${system};
      unstablePkgs = unstable.legacyPackages.${system};
      fenixPkgs = fenix.packages.${system};
      alejandraPkg = alejandra.defaultPackage.${system};

      # Check if system is Linux-based for ghostty
      isLinux = builtins.match ".*-linux" system != null;
      # Only include ghostty on Linux systems
      ghosttyPkgs =
        if isLinux
        then ghostty.packages.${system}
        else null;

      # Common packages for all systems
      commonPackages = with pkgs; [
        alejandraPkg
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
        go
        jq
        just
        neovim
        nodejs
        ripgrep
        fenixPkgs.rust-analyzer
        silver-searcher
        starship
        tree
        typescript-language-server
        uv
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
          ]
        else
          # macOS-specific packages
          with pkgs; [
            # Add macOS-specific packages here
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
      system76-pc = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux"; # or aarch64-linux if you're on ARM
        specialArgs = {inherit inputs;};
        modules = [
          ./linux/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jessfraz.imports = [
              ./home.nix
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
          ./darwin/configuration.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.jessfraz.imports = [
              ./home.nix
            ];
          }
        ];
      };
    };
  };
}
