{
  hostname,
  homeDir,
  ...
}: let
  # Live credentials are private runtime files, not removable-drive state.
  credentialsPath = "${homeDir}/.config/tripitcalb0t";
in {
  launchd.user.agents."${hostname}.tripitcalb0t" = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/bin/docker"
        "run"
        "--rm"
        "--name=tripitcalb0t"
        "-v"
        "${credentialsPath}/google.json:/root/.tripitcalb0t/google.json:ro"
        "-v"
        "/etc/localtime:/etc/localtime:ro"
        "--env-file"
        "${credentialsPath}/environment"
        "jess/tripitcalb0t"
        "--interval"
        "5m"
      ];
      KeepAlive = true; # restart if the container exits
      RunAtLoad = true; # fire at login
      StandardOutPath = "/tmp/tripitcalb0t.log";
      StandardErrorPath = "/tmp/tripitcalb0t.log";
    };

    # Make sure the Docker CLI lives in PATH for the agent
    environment = {"PATH" = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";};
  };
}
