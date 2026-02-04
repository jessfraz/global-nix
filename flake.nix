{
  description = "Desktop and laptop configuration for NixOS and macOS";

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

    # rust toolchains, see https://github.com/oxalica/rust-overlay
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
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
      inputs.rust-overlay.follows = "rust-overlay";
    };

    codex = {
      url = "git+https://github.com/openai/codex?ref=refs/tags/rust-v0.94.0&submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # FlakeHub CLI (fh)
    fh = {
      url = "https://flakehub.com/f/DeterminateSystems/fh/*.tar.gz";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    nix-darwin,
    rust-overlay,
    ghostty,
    dotfiles,
    dotvim,
    zoo-cli,
    codex,
    fh,
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
      mole = prev.callPackage ./pkgs/mole.nix {};
      coredns = prev.coredns.overrideAttrs (old: let
        postPatchScript =
          if old ? postPatch
          then old.postPatch
          else "";
        guardSubstitution =
          builtins.replaceStrings
          ["substituteInPlace test/corefile_test.go \\"]
          ["if [ -f test/corefile_test.go ] && grep -q \"TestCorefile1\" test/corefile_test.go; then\n    substituteInPlace test/corefile_test.go \\"]
          postPatchScript;
      in {
        postPatch =
          builtins.replaceStrings
          ["--replace-fail \"TestCorefile1\" \"SkipCorefile1\""]
          ["--replace \"TestCorefile1\" \"SkipCorefile1\"\n    fi"]
          guardSubstitution;
      });
    };

    # Provide a compatibility alias for removed attributes in recent nixpkgs.
    # Some inputs (e.g., editor configs) still reference `rust-analyzer-nightly`.
    # Alias it to the stable `rust-analyzer` when missing.
    overlayCompatRust = final: prev: {
      rust-analyzer-nightly =
        if prev ? rust-analyzer-nightly
        then prev.rust-analyzer-nightly
        else prev.rust-analyzer;
    };

    # Avoid flaky Node.js test phases on Darwin by disabling checks.
    overlaySkipNodeChecks = final: prev: {
      nodejs_20 = prev.nodejs_20.overrideAttrs (_: {doCheck = false;});
      nodejs_22 = prev.nodejs_22.overrideAttrs (_: {doCheck = false;});
    };

    # mdformat 0.7.22 doesn't accept markdown-it-py 4.x; pin mdformat to 1.0.0.
    # TODO(jessfraz): Drop this override once nixpkgs bumps mdformat to 1.0.0+.
    overlayMdformat = final: prev: let
      mdformatOverrides = pself: psuper: {
        mdformat = psuper.mdformat.overridePythonAttrs (_: {
          version = "1.0.0";
          src = prev.fetchFromGitHub {
            owner = "executablebooks";
            repo = "mdformat";
            tag = "1.0.0";
            hash = "sha256-fo4xO4Y89qPAggEjwuf6dnTyu1JzhZVdJyUqGNpti7g=";
          };
        });
      };
    in {
      python3 = prev.python3.override {packageOverrides = mdformatOverrides;};
      python3Packages = final.python3.pkgs;
    };

    commonOverlays = [
      overlay
      overlaySkipNodeChecks
      overlayCompatRust
      overlayMdformat
      rust-overlay.overlays.default
    ];

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
        overlays = commonOverlays;
      };
      rustBin = pkgs.rust-bin.stable.latest;
      rustToolchain = rustBin.default.override {
        extensions = [
          "rust-src"
          "clippy"
          "rustfmt"
        ];
      };
      zooCli = zoo-cli.packages.${pkgs.stdenv.hostPlatform.system}.zoo;
      codexCli = codex.packages.${system}.default.overrideAttrs (oa: {
        nativeBuildInputs =
          (oa.nativeBuildInputs or [])
          ++ (with pkgs; [
            cmake
            git
            llvmPackages.clang
            pkg-config
          ]);
        buildInputs =
          (oa.buildInputs or [])
          ++ (with pkgs; [
            openssl
            llvmPackages.libclang.lib
          ]);
        env =
          (oa.env or {})
          // {
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            CC = "clang";
            CXX = "clang++";
          };
      });
      flakehubCli = fh.packages.${pkgs.stdenv.hostPlatform.system}.default;

      # Common packages for all systems
      commonPackages = with pkgs; [
        _1password-cli
        ast-grep
        bash
        bash-completion
        claude-code
        codexCli
        opencode
        coreutils
        curl
        flakehubCli
        # Provide python with the 'rich' library for nicer stderr rendering
        # in scripts/prepare-commit-msg.py.
        (python312.withPackages (ps: [ps.rich]))
        rustToolchain
        findutils
        git
        git-lfs
        gnumake
        gnupg
        gnused
        jq
        just
        ncurses
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
            mole
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
          {
            nixpkgs = {
              overlays = commonOverlays;
              config.allowUnfree = true;
            };
          }
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
    darwinModules.matterbridge = import ./modules/matterbridge.nix;
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
          {
            nixpkgs = {
              overlays = commonOverlays;
              config.allowUnfree = true;
            };
          }
          ./hosts/base/configuration.nix
          ./hosts/darwin/configuration.nix
          ./hosts/darwin/macinator.nix
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

          specialArgs = {
            inherit inputs username githubUsername gitGpgKey gitName gitEmail homeDir hostname volumesPath tplIpPrefix tplResolverFile;
          };
          modules = [
            {
              nixpkgs = {
                overlays = commonOverlays;
                config.allowUnfree = true;
              };
            }
            self.darwinModules.coredns
            self.darwinModules.homebridge
            self.darwinModules.matterbridge
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
