{
  homeDir,
  lib,
  pkgs,
  hostname,
  ...
}: let
  epsonAddress = "10.42.9.7";
  epsonRelayPort = 19443;
  retiredHomeAssistantPort = 8123;
  mkPlainHttpService = address: {
    inherit address;
    destination = "${address}:80";
    protocol = "tls-terminated-tcp";
  };
  serviceHostTag = "tag:home-server";
  tailscaleServiceDefinitions = {
    # Epson redirects plaintext HTTP to HTTPS. Proxy its self-signed HTTPS
    # endpoint through a localhost relay so the sandboxed macOS Tailscale app
    # does not need to reach a remote address on a non-default interface.
    epson-tm-m30 = {
      address = epsonAddress;
      destination = "127.0.0.1:${toString epsonRelayPort}";
      protocol = "https+insecure";
    };
    ratgdo-big-garage = mkPlainHttpService "192.168.1.58";
    ratgdo-small-garage = mkPlainHttpService "192.168.1.12";
    ratgdo-gate = mkPlainHttpService "192.168.1.241";
  };
  httpDeviceRoutes = lib.mapAttrsToList (_: definition: "${definition.address}/32") tailscaleServiceDefinitions;
  tailscaleServices =
    lib.mapAttrs (
      name: definition: let
        serviceName = "svc:${name}";
        inherit (definition) destination;
        configFile = pkgs.writeText "tailscale-service-${name}.json" (builtins.toJSON {
          version = "0.0.1";
          endpoints."tcp:443" = "${definition.protocol}://${destination}";
        });
        configureCommand =
          if definition.protocol == "tls-terminated-tcp"
          then "${tailscale} serve --service=${lib.escapeShellArg serviceName} --tls-terminated-tcp=443 ${lib.escapeShellArg "tcp://${destination}"}"
          else if definition.protocol == "https+insecure"
          then "${tailscale} serve --service=${lib.escapeShellArg serviceName} --https=443 ${lib.escapeShellArg "https+insecure://${destination}"}"
          else "${tailscale} serve set-config --service=${lib.escapeShellArg serviceName} ${lib.escapeShellArg configFile}";
      in {
        inherit serviceName configFile configureCommand;
      }
    )
    tailscaleServiceDefinitions;
  tailscaleServiceNames = lib.mapAttrsToList (_: service: service.serviceName) tailscaleServices;
  advertisedRoutes = lib.concatStringsSep "," httpDeviceRoutes;
  jq = lib.getExe pkgs.jq;
  tailscale = lib.getExe pkgs.tailscale;
  retiredTailscaleServices = ["svc:ha" "svc:hb" "svc:matterbridge"];
  tailscaleRetiredServiceCommands =
    lib.concatMapStringsSep "\n" (service: ''
      # ${service}
      if drain_output="$(${tailscale} serve drain ${lib.escapeShellArg service} 2>&1)"; then
        if clear_output="$(${tailscale} serve clear ${lib.escapeShellArg service} 2>&1)"; then
          if capture_tailscale_json ${tailscale} serve get-config --service=${lib.escapeShellArg service}; then
            if ! printf '%s' "$tailscale_json" | ${jq} -e 'type == "object" and length == 0' >/dev/null; then
              echo "Retired Tailscale Service ${service} still has local configuration; will retry." >&2
            fi
          else
            echo "Unable to verify retired Tailscale Service ${service}; will retry: $tailscale_json_error" >&2
          fi
        else
          echo "Unable to clear retired Tailscale Service ${service}; will retry: $clear_output" >&2
        fi
      else
        echo "Unable to drain retired Tailscale Service ${service}; will retry: $drain_output" >&2
      fi
    '')
    retiredTailscaleServices;
  tailscaleServiceCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service: ''
      # ${name}
      if ! capture_tailscale_json ${tailscale} serve get-config --service=${lib.escapeShellArg service.serviceName}; then
        echo "Unable to read Tailscale Service ${service.serviceName}: $tailscale_json_error" >&2
        exit 1
      fi
      current_service_config="$tailscale_json"
      if ! current_service_config="$(printf '%s' "$current_service_config" | ${jq} -cS . 2>/dev/null)"; then
        echo "Tailscale returned an invalid config for ${service.serviceName}." >&2
        exit 1
      fi
      desired_service_config="$(${jq} -cS . ${lib.escapeShellArg service.configFile})"
      if [ "$current_service_config" != "$desired_service_config" ]; then
        if ! printf '%s' "$current_service_config" | ${jq} -e 'type == "object" and length == 0' >/dev/null; then
          if ! drain_output="$(${tailscale} serve drain ${lib.escapeShellArg service.serviceName} 2>&1)"; then
            echo "Unable to drain Tailscale Service ${service.serviceName} before updating it: $drain_output" >&2
            exit 1
          fi
          if ! clear_output="$(${tailscale} serve clear ${lib.escapeShellArg service.serviceName} 2>&1)"; then
            echo "Unable to clear Tailscale Service ${service.serviceName} before updating it: $clear_output" >&2
            exit 1
          fi
        fi
        if ! configure_service_output="$(${service.configureCommand} 2>&1)"; then
          echo "Unable to configure Tailscale Service ${service.serviceName}: $configure_service_output" >&2
          exit 1
        fi

        if ! capture_tailscale_json ${tailscale} serve get-config --service=${lib.escapeShellArg service.serviceName}; then
          echo "Unable to verify Tailscale Service ${service.serviceName}: $tailscale_json_error" >&2
          exit 1
        fi
        applied_service_config="$tailscale_json"
        if ! applied_service_config="$(printf '%s' "$applied_service_config" | ${jq} -cS . 2>/dev/null)"; then
          echo "Tailscale returned an invalid config while verifying ${service.serviceName}." >&2
          exit 1
        fi
        if [ "$applied_service_config" != "$desired_service_config" ]; then
          echo "Tailscale Service ${service.serviceName} did not converge to its declared config." >&2
          exit 1
        fi
      fi

      if ! advertise_output="$(${tailscale} serve advertise ${lib.escapeShellArg service.serviceName} 2>&1)"; then
        echo "Unable to advertise Tailscale Service ${service.serviceName}: $advertise_output" >&2
        exit 1
      fi
    '')
    tailscaleServices);
  retiredLegacyServePorts = {
    homeAssistant = retiredHomeAssistantPort;
    homebridge = 8581;
    matterbridge = 8283;
  };
  legacyServeCleanupCommands = ports:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: port: ''
        # ${name}
        if ! capture_tailscale_json ${tailscale} serve status --json; then
          echo "Unable to inspect legacy Tailscale Serve port ${toString port}: $tailscale_json_error" >&2
          exit 1
        fi
        legacy_serve_json="$tailscale_json"
        if ! legacy_serve_json="$(printf '%s' "$legacy_serve_json" | ${jq} -c 'if . == null then {} elif type == "object" then . else error("invalid Serve configuration") end' 2>/dev/null)"; then
          echo "Tailscale returned an invalid Serve configuration." >&2
          exit 1
        fi
        legacy_handler="$(printf '%s' "$legacy_serve_json" | ${jq} -c --arg port ${lib.escapeShellArg (toString port)} '.TCP[$port] // null')"
        if [ "$legacy_handler" != null ]; then
          if ! printf '%s' "$legacy_handler" | ${jq} -e \
            --arg target ${lib.escapeShellArg "127.0.0.1:${toString port}"} \
            '. == {"TCPForward": $target}' \
            >/dev/null; then
            echo "Refusing to remove an unexpected node-level Serve handler on port ${toString port}: $legacy_handler" >&2
            exit 1
          fi

          # Reasserting Serve first removes Funnel, if someone enabled it on the
          # old mapping, before deleting only this exact managed handler.
          ${tailscale} serve --bg --yes --tcp=${toString port} tcp://127.0.0.1:${toString port}
          ${tailscale} serve --yes --tcp=${toString port} off
        fi
      '')
      ports);
  tailscaleRetiredLegacyServeCleanupCommands = legacyServeCleanupCommands retiredLegacyServePorts;
in {
  # The sandboxed GUI owns this Mac's tailnet identity. Do not start a second,
  # unauthenticated nix-darwin tailscaled alongside it.
  services.tailscale.enable = false;

  # The sandboxed macOS Tailscale app cannot reliably proxy to a remote target
  # reached through a non-default interface. Keep the workaround loopback-only;
  # socat itself makes the LAN connection to the printer. Run it as a root
  # daemon because macOS grants launchd daemons local-network access while user
  # agents require an interactive privacy grant.
  launchd.daemons.epson-tm-m30-relay = {
    script = ''
      exec ${pkgs.socat}/bin/socat \
        TCP4-LISTEN:${toString epsonRelayPort},bind=127.0.0.1,reuseaddr,fork \
        TCP4:${epsonAddress}:443
    '';

    serviceConfig = {
      KeepAlive = true;
      ProcessType = "Background";
      RunAtLoad = true;
      StandardErrorPath = "/Library/Logs/epson-tm-m30-relay.err";
      StandardOutPath = "/Library/Logs/epson-tm-m30-relay.log";
      ThrottleInterval = 30;
    };
  };

  # The App Store client exposes its LocalAPI in the logged-in user's launchd
  # domain. Keep this as a user LaunchAgent: a root LaunchDaemon (or `sudo
  # tailscale`) looks for /var/run/tailscaled.socket and cannot reach the
  # GUI-owned daemon. The failed-exit keepalive lets a fresh machine wait for
  # its one-time login.
  launchd.user.agents.tailscale-home-server = {
    script = ''
      set -euo pipefail

      # A newer GUI-managed tailscaled can emit a harmless client-version
      # warning on stderr. Keep stderr out of JSON and rerun only failed reads
      # to preserve a useful diagnostic.
      capture_tailscale_json() {
        if tailscale_json="$("$@" 2>/dev/null)"; then
          tailscale_json_error=""
          return 0
        fi
        tailscale_json_error="$("$@" 2>&1 >/dev/null || true)"
        return 1
      }

      backend_state=""
      status_error=""
      for _ in {1..30}; do
        if capture_tailscale_json ${tailscale} status --json; then
          status_json="$tailscale_json"
          backend_state="$(printf '%s' "$status_json" | ${jq} -r '.BackendState // empty' 2>/dev/null || true)"
          status_error="backend state: ''${backend_state:-unknown}"
        else
          status_error="$tailscale_json_error"
        fi

        if [ "$backend_state" = "Running" ]; then
          break
        fi
        if [ "$backend_state" = "NeedsLogin" ]; then
          echo "Tailscale login required; authenticate macmini with a ${serviceHostTag} auth key." >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done

      if [ "$backend_state" != "Running" ]; then
        echo "Tailscale did not become ready: ''${status_error:-unknown error}" >&2
        exit 1
      fi

      # Tailscale Services have stable MagicDNS names such as
      # ha.<tailnet>.ts.net and can only be hosted by tagged nodes.
      if ! printf '%s' "$status_json" | ${jq} -e \
        --arg tag ${lib.escapeShellArg serviceHostTag} \
        '(.Self.Tags // []) | index($tag) != null' \
        >/dev/null; then
        echo "Tailscale Services require this node to have ${serviceHostTag}." >&2
        echo "Authorize that tag in the tailnet policy, then apply it to macmini or reauthenticate with a tagged auth key." >&2
        exit 1
      fi

      # Reconcile node preferences without touching unrelated Serve or Funnel
      # configuration that might already exist on this host.
      if ! capture_tailscale_json ${tailscale} get --json; then
        echo "Unable to read Tailscale preferences: $tailscale_json_error" >&2
        exit 1
      fi
      prefs_json="$tailscale_json"
      if ! printf '%s' "$prefs_json" | ${jq} -e 'type == "object"' >/dev/null; then
        echo "Tailscale returned invalid preferences." >&2
        exit 1
      fi
      if ! printf '%s' "$prefs_json" | ${jq} -e \
        --arg hostname ${lib.escapeShellArg hostname} \
        --argjson routes ${lib.escapeShellArg (builtins.toJSON httpDeviceRoutes)} \
        '."advertise-exit-node" == false
          and ."shields-up" == false
          and .hostname == $hostname
          and (
            ((."advertise-routes" // "") | split(",") | map(select(length > 0)) | sort)
            == ($routes | sort)
          )' \
        >/dev/null; then
        ${tailscale} set \
          --advertise-exit-node=false \
          --advertise-routes=${lib.escapeShellArg advertisedRoutes} \
          --hostname=${lib.escapeShellArg hostname} \
          --shields-up=false
      fi

      # Retired cleanup is best-effort and independent of active Service
      # configuration, advertisement, approval, or control-plane health.
      ${tailscaleRetiredServiceCommands}

      # Legacy node-level cleanup remains exact and scoped.
      ${tailscaleRetiredLegacyServeCleanupCommands}

      ${tailscaleServiceCommands}

      # Local config readback is not enough: the Services must also be defined
      # and this host approved by the tailnet control plane.
      services_active=false
      service_approval_state="service-host capability not present"
      for _ in {1..30}; do
        if capture_tailscale_json ${tailscale} status --json; then
          service_status_json="$tailscale_json"
          service_approval_state="$(printf '%s' "$service_status_json" | ${jq} -c '.Self.CapMap["service-host"] // []' 2>/dev/null || true)"
          if printf '%s' "$service_status_json" | ${jq} -e \
            --argjson services ${lib.escapeShellArg (builtins.toJSON tailscaleServiceNames)} \
            '(.Self.CapMap["service-host"] // []) as $mappings
              | all(
                  $services[];
                  . as $service
                  | any($mappings[]?; ((.[$service] // []) | length) > 0)
                )' \
            >/dev/null; then
            services_active=true
            break
          fi
        else
          service_approval_state="$tailscale_json_error"
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done
      if [ "$services_active" != true ]; then
        echo "Tailscale Services are configured locally but not all are approved and active." >&2
        echo "Current service-host state: $service_approval_state" >&2
        echo "Define tcp:443 for ${lib.concatStringsSep ", " tailscaleServiceNames}, then approve this host or configure service auto-approvers." >&2
        exit 1
      fi
    '';

    serviceConfig = {
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Background";
      RunAtLoad = true;
      StandardErrorPath = "${homeDir}/Library/Logs/tailscale-home-server.err";
      StandardOutPath = "${homeDir}/Library/Logs/tailscale-home-server.log";
      StartInterval = 300;
      ThrottleInterval = 30;
    };
  };
}
