{
  hostname,
  volumesPath,
  ...
}: {
  launchd.user.agents."${hostname}.tripitcalb0t" = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/bin/docker"
        "run"
        "--rm"
        "--name=tripitcalb0t"
        "-v"
        "${volumesPath}/tripitcalb0t-service-auth.json:/root/.tripitcalb0t/google.json:ro"
        "-v"
        "/etc/localtime:/etc/localtime:ro"
        "--env-file"
        "${volumesPath}/tripitcalb0t-env-file.txt"
        "jess/tripitcalb0t"
        "--interval"
        "5m"
      ];
      KeepAlive = true; # restart if the container exits
      RunAtLoad = true; # fire at login
      StandardOutPath = "/tmp/tripitcalb0t.out.log";
      StandardErrorPath = "/tmp/tripitcalb0t.err.log";
    };

    # Make sure the Docker CLI lives in PATH for the agent
    environment = {"PATH" = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";};
  };
}
