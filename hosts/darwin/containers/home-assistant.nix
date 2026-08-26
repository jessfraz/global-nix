{
  hostname,
  lib,
  pkgs,
  username,
  ...
}: let
  version = "2026.8.3";
  imageDigest = "sha256:14931c6b13756317849f46da1d01b45937a1150db66c081cfe529d48215943fe";
  image = "ghcr.io/home-assistant/home-assistant:${version}@${imageDigest}";
  containerName = "homeassistant";
  configPath = "/Users/${username}/.homeassistant";
  logPath = "${configPath}/container.log";
  docker = "/opt/homebrew/bin/docker";
  launchScript = pkgs.writeShellScript "home-assistant-container" ''
    set -euo pipefail

    child_pid=""

    stop_container() {
      ${docker} stop --time 60 ${lib.escapeShellArg containerName} >/dev/null 2>&1 || true
      if [ -n "$child_pid" ]; then
        wait "$child_pid" 2>/dev/null || true
      fi
    }

    trap 'stop_container; exit 0' INT TERM

    # A daemon or host crash can leave a stopped named container behind. The
    # durable state lives in /config, so converge only this owned container.
    if ${docker} container inspect ${lib.escapeShellArg containerName} >/dev/null 2>&1; then
      stop_container
      if ${docker} container inspect ${lib.escapeShellArg containerName} >/dev/null 2>&1; then
        ${docker} rm --force ${lib.escapeShellArg containerName} >/dev/null
      fi
    fi

    ${docker} run \
      --rm \
      --name ${lib.escapeShellArg containerName} \
      --platform linux/arm64 \
      --stop-timeout 60 \
      --publish 127.0.0.1:8123:8123 \
      --env TZ=America/Los_Angeles \
      --volume ${lib.escapeShellArg "${configPath}:/config"} \
      ${lib.escapeShellArg image} &
    child_pid="$!"
    wait "$child_pid"
  '';
in {
  # Docker Desktop cannot provide Home Assistant's supported Linux host
  # networking on macOS. Keep the existing bridges while this loopback-only
  # instance proves direct-IP integrations, then move durable HA to bridged
  # HAOS or Linux before migrating discovery-heavy HomeKit or Matter devices.
  system.activationScripts.home-assistant-mkdir.text = ''
    install -d -m0750 -o ${username} -g staff ${lib.escapeShellArg configPath}
    touch ${lib.escapeShellArg logPath}
    chown ${username}:staff ${lib.escapeShellArg logPath}
    chmod 0640 ${lib.escapeShellArg logPath}
  '';

  launchd.user.agents."${hostname}.home-assistant" = {
    serviceConfig = {
      ProgramArguments = ["${launchScript}"];
      KeepAlive = true;
      RunAtLoad = true;
      ThrottleInterval = 30;
      ExitTimeOut = 70;
      ProcessType = "Background";
      StandardOutPath = logPath;
      StandardErrorPath = logPath;
    };

    environment.PATH = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";
  };
}
