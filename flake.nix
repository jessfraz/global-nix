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
      url = "git+https://github.com/openai/codex?ref=refs/tags/rust-v0.148.0&submodules=1";
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
      axiomCli = prev.callPackage ./pkgs/axiom-cli.nix {};
      homebridge = prev.callPackage ./pkgs/homebridge.nix {};
      mole = prev.callPackage ./pkgs/mole.nix {};
      rampCli = prev.callPackage ./pkgs/ramp-cli.nix {};
      scrypted = prev.callPackage ./pkgs/scrypted.nix {};
      slackCli = prev.callPackage ./pkgs/slack-cli.nix {};
      terminal-notifier = prev.terminal-notifier.overrideAttrs (_: {
        src = prev.fetchzip {
          url = "https://github.com/alloy/terminal-notifier/releases/download/2.0.0/terminal-notifier-2.0.0.zip";
          sha256 = "0gi54v92hi1fkryxlz3k5s5d8h0s66cc57ds0vbm1m1qk3z4xhb0";
          stripRoot = false;
        };
        nativeBuildInputs = [];
        buildInputs = [];
        xcbuildFlags = [];
        dontBuild = true;
        installPhase = ''
          runHook preInstall

          mkdir -p "$out/Applications" "$out/bin"
          cp -r terminal-notifier.app "$out/Applications/"
          cat >"$out/bin/terminal-notifier" <<EOF
          #!${prev.runtimeShell}
          cd "$out/Applications/terminal-notifier.app"
          exec ./Contents/MacOS/terminal-notifier "\$@"
          EOF
          chmod +x "$out/bin/terminal-notifier"

          runHook postInstall
        '';
      });
      biome = prev.biome.overrideAttrs (old: {
        preCheck =
          (old.preCheck or "")
          + prev.lib.optionalString prev.stdenv.isDarwin ''
            # Biome's Unix socket tests exceed macOS's SUN_LEN limit when they
            # inherit Nix's long per-derivation temporary directory.
            biomeTestTmp="$(mktemp -d /tmp/biome-check.XXXXXX)"
            cleanupBiomeTestTmp() {
              rm -rf -- "$biomeTestTmp"
            }
            exitHooks+=(cleanupBiomeTestTmp)
            failureHooks+=(cleanupBiomeTestTmp)
            export TMPDIR="$biomeTestTmp"
          '';
      });
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
    # dotvim still references `rust-analyzer-nightly` on Linux.
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

    codexSrc = codex.outPath + "/codex-rs";
    codexCargoToml = builtins.fromTOML (builtins.readFile "${codexSrc}/Cargo.toml");
    codexCargoLock = builtins.fromTOML (builtins.readFile "${codexSrc}/Cargo.lock");
    codexV8Packages = builtins.filter (package: package.name == "v8") codexCargoLock.package;
    codexV8Version =
      if builtins.length codexV8Packages == 1
      then (builtins.head codexV8Packages).version
      else throw "Expected exactly one v8 package in the Codex Cargo.lock";
    codexVersion =
      if codexCargoToml.workspace.package.version != "0.0.0"
      then codexCargoToml.workspace.package.version
      else "0.0.0-dev+${codex.shortRev or "dirty"}";

    # Code mode enables rusty_v8's sandbox feature. Fetch its matching static
    # archive and generated binding up front rather than downloading at build time.
    rustyV8ArtifactsByVersion = {
      "150.4.0" = {
        aarch64-darwin = {
          archive = {
            url = "https://github.com/openai/codex/releases/download/rusty-v8-v${codexV8Version}/librusty_v8_ptrcomp_sandbox_release_aarch64-apple-darwin.a.gz";
            hash = "sha256-AK27SHmISMd1UEQcaGc6XoUpuOG3PqvN7iMss5tA9KE=";
          };
          binding = {
            url = "https://github.com/openai/codex/releases/download/rusty-v8-v${codexV8Version}/src_binding_ptrcomp_sandbox_release_aarch64-apple-darwin.rs";
            hash = "sha256-ylrfDPicmnCtRgrnNkiy/om3SqETs8t/dXtqArdYOU8=";
          };
        };
        x86_64-linux = {
          archive = {
            url = "https://github.com/openai/codex/releases/download/rusty-v8-v${codexV8Version}/librusty_v8_ptrcomp_sandbox_release_x86_64-unknown-linux-gnu.a.gz";
            hash = "sha256-o1x10fJuapg4haRbM0kKTr5U8FBQVosyuJz7QhswtYM=";
          };
          binding = {
            url = "https://github.com/openai/codex/releases/download/rusty-v8-v${codexV8Version}/src_binding_ptrcomp_sandbox_release_x86_64-unknown-linux-gnu.rs";
            hash = "sha256-dyeCauR5vbZF6Acjn7EtH44uI956bPFvXuWSaQ0dhQY=";
          };
        };
      };
    };
    rustyV8Artifacts =
      if builtins.hasAttr codexV8Version rustyV8ArtifactsByVersion
      then builtins.getAttr codexV8Version rustyV8ArtifactsByVersion
      else throw "No rusty_v8 artifacts pinned for Codex v8 ${codexV8Version}";

    livekitWebrtcArchives = {
      aarch64-darwin = {
        url = "https://github.com/livekit/rust-sdks/releases/download/webrtc-24f6822-2/webrtc-mac-arm64-release.zip";
        hash = "sha256-eb5cwV5uBjPEOA4z4XLX6/Gm3Og+ngmXYdYQPw1+tsE=";
        directory = "mac-arm64-release";
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
      rustyV8ArtifactsForSystem = builtins.getAttr system rustyV8Artifacts;
      rustyV8Archive =
        pkgs.fetchurl (rustyV8ArtifactsForSystem.archive
          // {name = "rusty-v8-${codexV8Version}-${system}.a.gz";});
      rustyV8Binding =
        pkgs.fetchurl (rustyV8ArtifactsForSystem.binding
          // {name = "rusty-v8-${codexV8Version}-${system}-binding.rs";});
      livekitWebrtcArchive =
        if builtins.hasAttr system livekitWebrtcArchives
        then
          pkgs.fetchurl {
            inherit (builtins.getAttr system livekitWebrtcArchives) url hash;
            name = "livekit-webrtc-${system}.zip";
          }
        else null;
      livekitWebrtcDirectory =
        if livekitWebrtcArchive != null
        then (builtins.getAttr system livekitWebrtcArchives).directory
        else null;
      livekitWebrtcPrebuilt =
        if livekitWebrtcArchive != null
        then
          pkgs.runCommand "livekit-webrtc-${system}" {
            nativeBuildInputs = [pkgs.unzip];
          } ''
            mkdir -p "$out"
            unzip -q "${livekitWebrtcArchive}" -d "$out"
          ''
        else null;
      rustBin = pkgs.rust-bin.stable.latest;
      rustToolchain = rustBin.default.override {
        extensions = [
          "rust-src"
          "clippy"
          "rustfmt"
        ];
      };
      zooCli = let
        package = zoo-cli.packages.${pkgs.stdenv.hostPlatform.system}.zoo;
        zooCliRev = zoo-cli.rev or "";
        cargoOutputHashOverrides = {
          "41069aff358e5eb4a68f8b73d26967164da9019e" = {
            "openapitor-0.0.9" = "sha256-UpyQzk4VnqNKwS2DUz9tM+v5YKEVoNkd9GyzaGX1uzk=";
          };
          "de962c47098c2e26d4fbb6681c552819d89f829c" = {
            "openapitor-0.0.9" = "sha256-UpyQzk4VnqNKwS2DUz9tM+v5YKEVoNkd9GyzaGX1uzk=";
          };
        };
        cargoOutputHashes = cargoOutputHashOverrides.${zooCliRev} or null;
      in
        if cargoOutputHashes != null
        then
          package.overrideAttrs (_: {
            # Some kittycad/cli revs have stale Nix hashes for git dependencies.
            # Replace only the generated Cargo vendor deps for known bad revs.
            cargoDeps = pkgs.rustPlatform.importCargoLock {
              lockFile = "${zoo-cli.outPath}/Cargo.lock";
              outputHashes = cargoOutputHashes;
            };
          })
        else package;
      googleWorkspaceCli = googleworkspace-cli.packages.${pkgs.stdenv.hostPlatform.system}.default;
      stripeCli = pkgs."stripe-cli";
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
            "crossterm-0.29.0" = "sha256-cQxQQuV+YEutuQiPurXVISq6F/99vCEk8qe5PU8BCSo=";
            "nucleo-0.5.0" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
            "nucleo-matcher-0.3.1" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
            "runfiles-0.1.0" = "sha256-uJpVLcQh8wWZA3GPv9D8Nt43EOirajfDJ7eq/FB+tek=";
            "tokio-tungstenite-0.28.0" = "sha256-V1xmnrfRWOcZZogelZEA4vvyMj2awCfHVA5/glQ6KAI=";
            "tungstenite-0.27.0" = "sha256-VVHhk7l9J/sEmG3q/UuV/sQ3f+fGsmq5vumSy8vbMvw=";
          };
        };
        doCheck = false;
        cargoBuildFlags = [
          "--package"
          "codex-cli"
          "--package"
          "codex-code-mode-host"
        ];
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
        env =
          {
            PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
              [pkgs.openssl] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.libcap]
            );
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            CC = "clang";
            CXX = "clang++";
            RUSTY_V8_ARCHIVE = "${rustyV8Archive}";
            RUSTY_V8_SRC_BINDING_PATH = "${rustyV8Binding}";
          }
          // pkgs.lib.optionalAttrs (livekitWebrtcPrebuilt != null) {
            LK_CUSTOM_WEBRTC = "${livekitWebrtcPrebuilt}/${livekitWebrtcDirectory}";
          };
        postInstall =
          ''
            test -x "$out/bin/codex"
            test -x "$out/bin/codex-code-mode-host"
          ''
          + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            mkdir -p "$out/codex-resources"
            ln "$out/bin/codex" "$out/bin/codex-linux-sandbox"
            ln -s ${pkgs.bubblewrap}/bin/bwrap "$out/codex-resources/bwrap"
            test -x "$out/bin/codex-linux-sandbox"
            test -x "$out/codex-resources/bwrap"
          '';
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
          axiomCli
          bash
          bash-completion
          claude-code
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
      scrypted =
        (import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = commonOverlays;
        }).scrypted;
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
    darwinModules.darwin-service-watchdog = import ./modules/darwin-service-watchdog.nix;
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
            self.darwinModules.darwin-service-watchdog
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
