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

    disktree = {
      url = "github:tobi/disktree";
      flake = false;
    };

    dotfiles = {
      url = "github:jessfraz/dotfiles";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    dotvim = {
      url = "git+https://github.com/jessfraz/.vim";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    zoo-cli = {
      url = "github:kittycad/cli";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    codex = {
      url = "github:openai/codex/rust-v0.161.0";
      flake = false;
    };

    switchboard = {
      url = "github:jessfraz/switchboard";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
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
    disktree,
    dotfiles,
    dotvim,
    zoo-cli,
    codex,
    switchboard,
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
      axiomCli = prev.callPackage ./pkgs/axiom-cli.nix {};
      mole = prev.callPackage ./pkgs/mole.nix {};
      rampCli = prev.callPackage ./pkgs/ramp-cli.nix {};
      slackCli = prev.callPackage ./pkgs/slack-cli.nix {};
    };

    commonOverlays = [
      overlay
      rust-overlay.overlays.default
    ];

    codexCargoToml = builtins.fromTOML (builtins.readFile "${codex}/codex-rs/Cargo.toml");
    codexVersion = codexCargoToml.workspace.package.version;

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
      rustToolchain = rustBin.minimal.override {
        extensions = [
          "rust-src"
          "clippy"
          "rustfmt"
        ];
      };
      zooCli = zoo-cli.packages.${pkgs.stdenv.hostPlatform.system}.zoo;
      cliCompletions = pkgs.callPackage ./pkgs/cli-completions.nix {inherit zooCli;};
      stripeCli = pkgs."stripe-cli";
      rustPlatform = pkgs.makeRustPlatform {
        cargo = rustBin.minimal;
        rustc = rustBin.minimal;
      };
      disktreePackage = pkgs.callPackage ./pkgs/disktree.nix {
        src = disktree;
        inherit rustPlatform;
      };
      codexCli = pkgs.callPackage ./pkgs/codex.nix {
        version = codexVersion;
        upstreamSource = codex;
      };
      switchboardPackages = switchboard.packages.${pkgs.stdenv.hostPlatform.system};
      switchboardClis = [
        switchboardPackages.switchboard
        switchboardPackages.mychart
        switchboardPackages.mindbody
        switchboardPackages.momence
        switchboardPackages.phone
        switchboardPackages.plaid
        switchboardPackages.schwab
      ];
      flakehubCli = fh.packages.${pkgs.stdenv.hostPlatform.system}.default;
      gwsCli = pkgs.symlinkJoin {
        name = "gws-file-credentials-${pkgs.gws.version}";
        paths = [pkgs.gws];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          wrapProgram "$out/bin/gws" --set GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND file
        '';
        meta = pkgs.gws.meta;
      };
      kicadPackage =
        if pkgs.stdenv.hostPlatform.isDarwin
        then pkgs.callPackage ./pkgs/kicad-bin.nix {}
        else pkgs.kicad;
      orcaSlicerPackage =
        if pkgs.stdenv.hostPlatform.isDarwin
        then pkgs.callPackage ./pkgs/orca-slicer-bin.nix {}
        else pkgs.orca-slicer;

      # Common packages for all systems
      commonPackages =
        (with pkgs; [
          _1password-cli
          axiomCli
          awscli2
          bash
          bash-completion
          claude-code
          cliCompletions
          codexCli
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
          gwsCli
          gnumake
          gnupg
          gnused
          jq
          just
          lsof
          ncurses
          nodejs_22
          pinentry-tty
          rampCli
          ripgrep
          slackCli
          starship
          stripeCli
        ])
        ++ switchboardClis
        ++ (with pkgs; [
          tailscale
          tree
          uv
          vault
          watch
          yarn
          yubikey-manager
          zooCli
        ]);

      # System-specific packages
      systemSpecificPackages =
        if pkgs.stdenv.hostPlatform.isLinux
        then
          # Linux-specific packages
          with pkgs; [
            _1password-gui
            google-chrome
            pinentry-tty
            xclip
          ]
        else
          # macOS-specific packages
          with pkgs; [
            # Add macOS-specific packages here
            mole
            pinentry_mac
          ];
      packageBundle = pkgs.buildEnv {
        name = "home-packages";
        paths = commonPackages ++ systemSpecificPackages;
      };
    in {
      codex = codexCli;
      gws = gwsCli;
      cli-completions = cliCompletions;
      disktree = disktreePackage;
      kicad = kicadPackage;
      orca-slicer = orcaSlicerPackage;
      default = packageBundle;
      # Only package outputs belong in the public cache, never generated host
      # configurations or Home Manager generations.
      ci-cache = pkgs.linkFarmFromDrvs "ci-cache" (
        [
          packageBundle
          dotvim.packages.${system}.editor-tools
          disktreePackage
          kicadPackage
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          ghostty.packages.${system}.default
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
          orcaSlicerPackage
        ]
      );
    };
  in {
    # Generate packages for all supported systems
    packages = forAllSystems mkPackages;

    lib.cleanupBuildCachePolicy = "${dotfiles}/bin/build_cache_policy.py";

    checks.aarch64-darwin.package-selection = nixpkgs.legacyPackages.aarch64-darwin.callPackage ./tests/package-selection.nix {inherit self;};

    checks.aarch64-darwin.tailscale-home-server-launch-agent = let
      config = self.darwinConfigurations.macmini.config;
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      script = config.launchd.user.agents.tailscale-home-server.script;
      relayScript = config.launchd.daemons.epson-tm-m30-relay.script;
    in
      assert builtins.hasAttr "tailscale-home-server" config.launchd.user.agents;
      assert builtins.hasAttr "epson-tm-m30-relay" config.launchd.daemons;
      assert !(builtins.hasAttr "epson-tm-m30-relay" config.launchd.user.agents);
      assert !(builtins.hasAttr "tailscale-home-server" config.launchd.daemons);
      assert nixpkgs.lib.hasInfix "--tls-terminated-tcp=443" script;
      assert nixpkgs.lib.hasInfix "tcp://127.0.0.1:19443" script;
      assert !(nixpkgs.lib.hasInfix "https+insecure://127.0.0.1:19443" script);
      assert nixpkgs.lib.hasInfix "10.42.9.7/32" script;
      assert nixpkgs.lib.hasInfix "TCP4-LISTEN:19443,bind=127.0.0.1" relayScript;
      assert nixpkgs.lib.hasInfix "OPENSSL:10.42.9.7:443,verify=0,nosni" relayScript;
        pkgs.runCommand "tailscale-home-server-launch-agent-check" {} ''
          touch "$out"
        '';

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
