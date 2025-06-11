{
  hostname,
  volumesPath,
  ...
}: {
  launchd.user.agents."${hostname}.homebridge" = {
    serviceConfig = {
      ProgramArguments = [
        "/usr/local/bin/docker"
        "run"
        "--rm"
        "--name=homebridge"
        "--network"
        "host"
        "-v"
        "${volumesPath}/homebridge:/homebridge"
        "homebridge/homebridge"
      ];
      KeepAlive = true; # restart if the container exits
      RunAtLoad = true; # fire at login
      StandardOutPath = "/tmp/homebridge.out.log";
      StandardErrorPath = "/tmp/homebridge.err.log";
    };

    # Make sure the Docker CLI lives in PATH for the agent
    environment = {"PATH" = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";};
  };
}
