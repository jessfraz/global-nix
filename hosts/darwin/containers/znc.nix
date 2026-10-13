{
  hostname,
  lib,
  volumesPath,
  ...
}: {
  launchd.user.agents."${hostname}.znc" = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/bin/docker"
        "run"
        "--rm"
        "--name=znc"
        "--entrypoint"
        "/bin/sh"
        "-p"
        "127.0.0.1:12345:6697"
        "--dns"
        "10.42.0.1"
        "--dns"
        "1.1.1.1"
        "-v"
        "${volumesPath}/znc:/home/user/.znc"
        "jess/znc"
        "-ec"
        # Docker claims the container name before this runs, so the existing
        # server cannot rewrite its mutable config during the listener update.
        # Tailscale Serve owns TLS; only the host's loopback port is published.
        ''
          perl -e ${lib.escapeShellArg (builtins.readFile ../../../scripts/znc-tailscale-listener.pl)} /home/user/.znc/configs/znc.conf
          exec znc -f
        ''
      ];
      KeepAlive = true; # restart if the container exits
      RunAtLoad = true; # fire at login
      StandardOutPath = "/tmp/znc.log";
      StandardErrorPath = "/tmp/znc.log";
    };

    # Make sure the Docker CLI lives in PATH for the agent
    environment = {"PATH" = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";};
  };
}
