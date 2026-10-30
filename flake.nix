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

    rex = {
      # Pin the public release artifact so builds need no alpha package token.
      url = "https://wthziax2yejsqc4k.public.blob.vercel-storage.com/public/pkgs/rex/nix/preview/0.1.0-preview.8.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
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
      url = "github:openai/codex/rust-v0.165.0";
      flake = false;
    };

    switchboard = {
      url = "github:jessfraz/switchboard";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    ha-packages = {
      url = "github:jessfraz/ha-packages/98a4d75908267b40770a9addcb4be264b4d17114";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    ha-maintenance = {
      url = "github:jessfraz/ha-maintenance/cae078d3c993b6099b41805fad6cd83537d0438d";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    ha-filevault = {
      url = "github:jessfraz/ha-filevault/ba9c7ee8ffaebbbcd98649c90bd414cb6e0e0338";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    agent.url = "github:jessfraz/agent";

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
    rex,
    disktree,
    dotfiles,
    dotvim,
    zoo-cli,
    codex,
    switchboard,
    ha-packages,
    ha-maintenance,
    ha-filevault,
    agent,
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
      # Keep the cache/ACL regression enabled without requiring host loopback aliases.
      coredns = prev.coredns.overrideAttrs (old: {
        patches =
          (old.patches or [])
          ++ [
            ./pkgs/coredns-cache-acl-test.patch
            # A 10ms handshake deadline flakes under Darwin's socket scheduling.
            ./pkgs/coredns-test-timeouts.patch
            # Bind view tests directly instead of racing a temporary DNS server.
            ./pkgs/coredns-view-test-listener.patch
          ];
      });
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
      agentCli = agent.packages.${system}.default;
      chromeControl = pkgs.callPackage ./pkgs/chrome-control.nix {};
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
        switchboardPackages.messages
        switchboardPackages.momence
        switchboardPackages.phone
        switchboardPackages.plaid
        switchboardPackages.schwab
      ];
      shipmentsCli = ha-packages.packages.${system}.ha-shipments;
      maintenanceCli = ha-maintenance.packages.${system}.ha-maintenance;
      filevaultCli = ha-filevault.packages.${system}.ha-filevault;
      haClis = [shipmentsCli maintenanceCli filevaultCli];
      flakehubCli = fh.packages.${pkgs.stdenv.hostPlatform.system}.default;
      gwsPackage = pkgs.gws.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./pkgs/gws-header-case.patch];
      });
      gwsCli = pkgs.symlinkJoin {
        name = "gws-file-credentials-${gwsPackage.version}";
        paths = [gwsPackage];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          wrapProgram "$out/bin/gws" --set GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND file
        '';
        meta = gwsPackage.meta;
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
          agentCli
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
        ++ haClis
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
            chromeControl
            mole
            pinentry_mac
          ];
      packageBundle = pkgs.buildEnv {
        name = "home-packages";
        paths = commonPackages ++ systemSpecificPackages;
      };
      # Public package roots are explicit and independent of host configuration.
      cachePackages =
        [
          packageBundle
          dotvim.packages.${system}.editor-tools
          disktreePackage
          kicadPackage
          # Packages introduced by host and Home Manager modules, outside the
          # shared bundle. Keep this list independent of generated host configs.
          pkgs.bashInteractive
          pkgs.diffutils
          pkgs.fontconfig
          pkgs.irssi
          pkgs.jujutsu
          pkgs.man-db
          pkgs.nerd-fonts.hack
          pkgs.openssh
          pkgs.rsync
          # Providers are shared packages; no user's editor configuration.
          (pkgs.wrapNeovim pkgs.neovim-unwrapped {
            withPython3 = true;
            withRuby = true;
          })
        ]
        ++ commonPackages
        ++ systemSpecificPackages
        ++ dotvim.packages.${system}.editor-tools.paths
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          ghostty.packages.${system}.default
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
          (pkgs.callPackage ./pkgs/auto-dnd.nix {})
          pkgs.coredns
          pkgs.mas
          pkgs.socat
          pkgs.wireshark
          pkgs.zsh
          pkgs.nix-zsh-completions
          pkgs.texinfoInteractive
          orcaSlicerPackage
        ];
      # Hosts install man/info outputs as well as executables. Use output paths
      # as link names so multi-output packages cannot overwrite each other.
      cacheOutputs = pkgs.lib.concatMap (package:
        map (output: pkgs.lib.getOutput output package) (pkgs.lib.unique (
          [(package.outputName or "out")]
          ++ (package.meta.outputsToInstall or [])
          ++ builtins.filter (output: builtins.hasAttr output package) ["man" "info"]
        )))
      cachePackages;
    in
      {
        ha-shipments = shipmentsCli;
        ha-maintenance = maintenanceCli;
        ha-filevault = filevaultCli;
        agent = agentCli;
        zoo = zooCli;
        codex = codexCli;
        gws = gwsCli;
        cli-completions = cliCompletions;
        disktree = disktreePackage;
        kicad = kicadPackage;
        orca-slicer = orcaSlicerPackage;
        default = packageBundle;
        # Only package outputs belong in the public cache, never generated host
        # configurations or Home Manager generations.
        ci-cache = pkgs.linkFarm "ci-cache" (map (package: {
            name = builtins.unsafeDiscardStringContext (builtins.baseNameOf package.outPath);
            path = package;
          })
          cacheOutputs);
      }
      // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        chrome-control = chromeControl;
      };
  in {
    # Generate packages for all supported systems
    packages = forAllSystems mkPackages;

    lib.cleanupBuildCachePolicy = "${dotfiles}/bin/build_cache_policy.py";

    checks.aarch64-darwin.package-selection = nixpkgs.legacyPackages.aarch64-darwin.callPackage ./tests/package-selection.nix {inherit self;};

    checks.x86_64-linux.rex-runs = rex.checks.x86_64-linux.runs;

    checks.x86_64-linux.initrd-ssh-unlock = import ./tests/initrd-ssh-unlock.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      nixpkgsPath = nixpkgs;
    };

    checks.aarch64-darwin.tailscale-home-server-daemon = let
      config = self.darwinConfigurations.macmini.config;
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      script = config.launchd.daemons.tailscale-home-server.script;
      relayScript = config.launchd.daemons.epson-tm-m30-relay.script;
    in
      assert config.services.tailscale.enable;
      assert config.launchd.daemons.tailscaled.serviceConfig.RunAtLoad;
      assert config.launchd.daemons.tailscaled.serviceConfig.KeepAlive;
      assert builtins.hasAttr "tailscale-home-server" config.launchd.daemons;
      assert config.launchd.daemons.tailscale-home-server.serviceConfig.RunAtLoad;
      assert !(builtins.hasAttr "tailscale-home-server" config.launchd.user.agents);
      assert builtins.hasAttr "epson-tm-m30-relay" config.launchd.daemons;
      assert !(builtins.hasAttr "epson-tm-m30-relay" config.launchd.user.agents);
      assert nixpkgs.lib.hasInfix "--tls-terminated-tcp=443" script;
      assert nixpkgs.lib.hasInfix "tcp://127.0.0.1:19443" script;
      assert !(nixpkgs.lib.hasInfix "https+insecure://127.0.0.1:19443" script);
      assert nixpkgs.lib.hasInfix "10.42.9.7/32" script;
      assert nixpkgs.lib.hasInfix "TCP4-LISTEN:19443,bind=127.0.0.1" relayScript;
      assert nixpkgs.lib.hasInfix "OPENSSL:10.42.9.7:443,verify=0,nosni" relayScript;
        pkgs.runCommand "tailscale-home-server-daemon-check" {} ''
          touch "$out"
        '';

    checks.aarch64-darwin.znc-native-state = let
      config = self.darwinConfigurations.macmini.config;
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
      args = config.launchd.user.agents."macmini.znc".serviceConfig.ProgramArguments;
    in
      assert builtins.elem "--mount" args;
      assert builtins.elem "type=bind,source=/Users/minitron/.local/state/znc,target=/home/user/.znc" args;
      assert !(builtins.elem "-v" args);
      assert builtins.elem "127.0.0.1:12345:6697" args;
        pkgs.runCommand "znc-native-state-check" {nativeBuildInputs = [pkgs.python3 pkgs.perl];} ''
          mkdir -p tests scripts
          cp ${./tests/test_znc_savebuff_metadata.py} tests/test_znc_savebuff_metadata.py
          cp ${./scripts/znc-savebuff-metadata.pl} scripts/znc-savebuff-metadata.pl
          python tests/test_znc_savebuff_metadata.py
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
        system = "aarch64-darwin";
      in
        nix-darwin.lib.darwinSystem {
          system = system;

          specialArgs = {
            inherit inputs username githubUsername gitGpgKey gitName gitEmail homeDir hostname tplIpPrefix tplResolverFile;
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
                inherit inputs username githubUsername gitGpgKey gitName gitEmail homeDir hostname tplIpPrefix tplResolverFile;
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
    };
  };
}
