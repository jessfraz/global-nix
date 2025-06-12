{
  hostname,
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
        "-p"
        "0.0.0.0:12345:6697"
        "--dns"
        "10.42.0.1"
        "--dns"
        "1.1.1.1"
        "-v"
        "${volumesPath}/znc:/home/user/.znc"
        "jess/znc"
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
