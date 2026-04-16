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

    googleworkspace-cli = {
      url = "github:googleworkspace/cli";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex = {
      url = "git+https://github.com/openai/codex?ref=refs/tags/rust-v0.121.0&submodules=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    switchboard = {
      url = "git+ssh://git@github.com/jessfraz/switchboard.git";
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
    dotfiles,
    dotvim,
    zoo-cli,
    googleworkspace-cli,
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
      homebridge = prev.callPackage ./pkgs/homebridge.nix {};
      mole = prev.callPackage ./pkgs/mole.nix {};
      rampCli = prev.callPackage ./pkgs/ramp-cli.nix {};
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
        guardedPostPatch =
          builtins.replaceStrings
          ["--replace-fail \"TestCorefile1\" \"SkipCorefile1\""]
          ["--replace \"TestCorefile1\" \"SkipCorefile1\"\n    fi"]
          guardSubstitution;
      in {
        postPatch =
          guardedPostPatch;
        # nixpkgs already carries several Darwin-specific CoreDNS test skips and
        # 1.14.2 still flakes in networking tests, so don't gate macOS rebuilds
        # on that check suite.
        doCheck =
          if prev.stdenv.isDarwin
          then false
          else old.doCheck or true;
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

    # nixpkgs assembles `nodejs_*` from `nodejs-slim_*`, so disable checks on
    # the slim builders that actually run the flaky Darwin test suite.
    overlaySkipNodeChecks = final: prev:
      if prev.stdenv.isDarwin
      then {
        nodejs-slim_20 = prev.nodejs-slim_20.overrideAttrs (_: {doCheck = false;});
        nodejs-slim_22 = prev.nodejs-slim_22.overrideAttrs (_: {doCheck = false;});
      }
      else {};

    commonOverlays = [
      overlay
      overlaySkipNodeChecks
      overlayCompatRust
      rust-overlay.overlays.default
    ];

    # `rusty_v8` wants to download a prebuilt archive at build time, which is
    # a lousy fit for Nix. Prefetch the archive and pass the local path instead.
    rustyV8Archives = {
      aarch64-darwin = {
        url = "https://github.com/denoland/rusty_v8/releases/download/v146.4.0/librusty_v8_release_aarch64-apple-darwin.a.gz";
        hash = "sha256-v+LJvjKlbChUbw+WWCXuaPv2BkBfMQzE4XtEilaM+Yo=";
      };
      x86_64-linux = {
        url = "https://github.com/denoland/rusty_v8/releases/download/v146.4.0/librusty_v8_release_x86_64-unknown-linux-gnu.a.gz";
        hash = "sha256-5ktNmeSuKTouhGJEqJuAF4uhA4LBP7WRwfppaPUpEVM=";
      };
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
        overlays = commonOverlays;
      };
      rustyV8Archive = pkgs.fetchurl (builtins.getAttr system rustyV8Archives);
      rustBin = pkgs.rust-bin.stable.latest;
      rustToolchain = rustBin.default.override {
        extensions = [
          "rust-src"
          "clippy"
          "rustfmt"
        ];
      };
      zooCli = zoo-cli.packages.${pkgs.stdenv.hostPlatform.system}.zoo;
      googleWorkspaceCli = googleworkspace-cli.packages.${pkgs.stdenv.hostPlatform.system}.default;
      stripeCli = pkgs."stripe-cli";
      codexSrc = codex.outPath + "/codex-rs";
      codexCargoToml = builtins.fromTOML (builtins.readFile "${codexSrc}/Cargo.toml");
      codexVersion =
        if codexCargoToml.workspace.package.version != "0.0.0"
        then codexCargoToml.workspace.package.version
        else "0.0.0-dev+${codex.shortRev or "dirty"}";
      codexRustPlatform = pkgs.makeRustPlatform {
        cargo = rustBin.minimal;
        rustc = rustBin.minimal;
      };
      codexCli = codexRustPlatform.buildRustPackage {
        pname = "codex-rs";
        version = codexVersion;
        src = codexSrc;
        cargoLock = {
          lockFile = "${codexSrc}/Cargo.lock";
          outputHashes = {
            "ratatui-0.29.0" = "sha256-HBvT5c8GsiCxMffNjJGLmHnvG77A6cqEL+1ARurBXho=";
            "crossterm-0.28.1" = "sha256-6qCtfSMuXACKFb9ATID39XyFDIEMFDmbx6SSmNe+728=";
            "nucleo-0.5.0" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
            "nucleo-matcher-0.3.1" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
            "runfiles-0.1.0" = "sha256-uJpVLcQh8wWZA3GPv9D8Nt43EOirajfDJ7eq/FB+tek=";
            "tokio-tungstenite-0.28.0" = "sha256-hJAkvWxDjB9A9GqansahWhTmj/ekcelslLUTtwqI7lw=";
            "tungstenite-0.27.0" = "sha256-AN5wql2X2yJnQ7lnDxpljNw0Jua40GtmT+w3wjER010=";
            "libwebrtc-0.3.26" = "sha256-0HPuwaGcqpuG+Pp6z79bCuDu/DyE858VZSYr3DKZD9o=";
          };
        };
        doCheck = false;
        postPatch = ''
          sed -i 's/^version = "0\.0\.0"$/version = "${codexVersion}"/' Cargo.toml
        '';
        nativeBuildInputs = with pkgs; [
          cmake
          git
          llvmPackages.clang
          pkg-config
        ];
        buildInputs =
          (with pkgs; [
            openssl
            llvmPackages.libclang.lib
          ])
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.libcap.dev
            pkgs.libcap.lib
          ];
        env = {
          PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
            [pkgs.openssl] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.libcap]
          );
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          CC = "clang";
          CXX = "clang++";
          RUSTY_V8_ARCHIVE = "${rustyV8Archive}";
        };
        meta = with pkgs.lib; {
          description = "OpenAI Codex command-line interface rust implementation";
          homepage = "https://github.com/openai/codex";
          license = licenses.asl20;
          mainProgram = "codex";
        };
      };
      switchboardPackages = switchboard.packages.${pkgs.stdenv.hostPlatform.system};
      switchboardClis = [
        switchboardPackages.switchboard
        switchboardPackages.mychart
        switchboardPackages.mindbody
        switchboardPackages.momence
        switchboardPackages.plaid
        switchboardPackages.schwab
      ];
      flakehubCli = fh.packages.${pkgs.stdenv.hostPlatform.system}.default;

      # Common packages for all systems
      commonPackages =
        (with pkgs; [
          _1password-cli
          bash
          bash-completion
          claude-code-bin
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
          googleWorkspaceCli
          gnumake
          gnupg
          gnused
          jq
          just
          ncurses
          nodejs_22
          pinentry-tty
          rampCli
          silver-searcher
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
          zooCli
        ]);

      # System-specific packages
      systemSpecificPackages =
        if pkgs.stdenv.isLinux
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
