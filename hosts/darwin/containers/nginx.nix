{
  hostname,
  volumesPath,
  ...
}: {
  launchd.user.agents."${hostname}.nginx" = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/bin/docker"
        "run"
        "--rm"
        "--name=nginx"
        "-p"
        "0.0.0.0:80:80"
        "-p"
        "0.0.0.0:443:443"
        "-v"
        "${volumesPath}/configs/terraform/gcloud/nginx:/etc/nginx:ro"
        "-v"
        "${volumesPath}/letsencrypt:/etc/letsencrypt:ro"
        "nginx"
      ];
      KeepAlive = true; # restart if the container exits
      RunAtLoad = true; # fire at login
      StandardOutPath = "/tmp/nginx.log";
      StandardErrorPath = "/tmp/nginx.log";
    };

    # Make sure the Docker CLI lives in PATH for the agent
    environment = {"PATH" = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";};
  };
}
