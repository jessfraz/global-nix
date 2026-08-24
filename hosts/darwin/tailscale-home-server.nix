{servicePorts}: {
  lib,
  pkgs,
  hostname,
  ...
}: let
  ratgdoRoutes = [
    "192.168.1.58/32" # Big Garage Door
    "192.168.1.12/32" # Small Garage Door
    "192.168.1.190/32" # Gate
  ];
  serviceHostTag = "tag:home-server";
  tailscaleServiceTargets = {
    hb = "tls-terminated-tcp://127.0.0.1:${toString servicePorts.homebridge}";
    matterbridge = "tls-terminated-tcp://127.0.0.1:${toString servicePorts.matterbridge}";
    scrypted = "https+insecure://127.0.0.1:${toString servicePorts.scrypted}";
  };
  tailscaleServices =
    lib.mapAttrs (name: target: {
      serviceName = "svc:${name}";
      configFile = pkgs.writeText "tailscale-service-${name}.json" (builtins.toJSON {
        version = "0.0.1";
        endpoints."tcp:443" = target;
      });
    })
    tailscaleServiceTargets;
  tailscaleServiceNames = lib.mapAttrsToList (_: service: service.serviceName) tailscaleServices;
  advertisedRoutes = lib.concatStringsSep "," ratgdoRoutes;
  jq = lib.getExe pkgs.jq;
  tailscale = lib.getExe pkgs.tailscale;
  tailscaleServiceCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service: ''
      # ${name}
      if ! current_service_config="$(${tailscale} serve get-config --service=${lib.escapeShellArg service.serviceName} 2>&1)"; then
        echo "Unable to read Tailscale Service ${service.serviceName}: $current_service_config" >&2
        exit 1
      fi
      if ! current_service_config="$(printf '%s' "$current_service_config" | ${jq} -cS . 2>/dev/null)"; then
        echo "Tailscale returned an invalid config for ${service.serviceName}." >&2
        exit 1
      fi
      desired_service_config="$(${jq} -cS . ${lib.escapeShellArg service.configFile})"
      if [ "$current_service_config" != "$desired_service_config" ]; then
        if ! set_service_output="$(${tailscale} serve set-config \
          --service=${lib.escapeShellArg service.serviceName} \
          ${lib.escapeShellArg service.configFile} 2>&1)"; then
          echo "Unable to configure Tailscale Service ${service.serviceName}: $set_service_output" >&2
          exit 1
        fi

        if ! applied_service_config="$(${tailscale} serve get-config --service=${lib.escapeShellArg service.serviceName} 2>&1)"; then
          echo "Unable to verify Tailscale Service ${service.serviceName}: $applied_service_config" >&2
          exit 1
        fi
        if ! applied_service_config="$(printf '%s' "$applied_service_config" | ${jq} -cS . 2>/dev/null)"; then
          echo "Tailscale returned an invalid config while verifying ${service.serviceName}." >&2
          exit 1
        fi
        if [ "$applied_service_config" != "$desired_service_config" ]; then
          echo "Tailscale Service ${service.serviceName} did not converge to its declared config." >&2
          exit 1
        fi
      fi
    '')
    tailscaleServices);
  tailscaleLegacyServeCleanupCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: port: ''
      # ${name}
      if ! legacy_serve_json="$(${tailscale} serve status --json 2>&1)"; then
        echo "Unable to inspect legacy Tailscale Serve port ${toString port}: $legacy_serve_json" >&2
        exit 1
      fi
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
    servicePorts);
in {
  services.tailscale.enable = true;
  launchd.daemons.tailscaled.serviceConfig.KeepAlive = true;

  # Reconcile settings after tailscaled is authenticated. The failed-exit
  # keepalive lets a fresh machine wait for its one-time `tailscale up` login.
  launchd.daemons.tailscale-home-server = {
    script = ''
      set -euo pipefail

      backend_state=""
      status_error=""
      for _ in {1..30}; do
        if status_json="$(${tailscale} status --json 2>&1)"; then
          backend_state="$(printf '%s' "$status_json" | ${jq} -r '.BackendState // empty' 2>/dev/null || true)"
          status_error="backend state: ''${backend_state:-unknown}"
        else
          status_error="$status_json"
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
      # hb.<tailnet>.ts.net and can only be hosted by tagged nodes.
      if ! printf '%s' "$status_json" | ${jq} -e \
        --arg tag ${lib.escapeShellArg serviceHostTag} \
        '(.Self.Tags // []) | index($tag) != null' \
        >/dev/null; then
        echo "Tailscale Services require this node to have ${serviceHostTag}." >&2
        echo "Authorize that tag in the tailnet policy, then reauthenticate macmini with a tagged auth key." >&2
        exit 1
      fi

      # Reconcile node preferences without touching unrelated Serve or Funnel
      # configuration that might already exist on this host.
      if ! prefs_json="$(${tailscale} get --json 2>&1)"; then
        echo "Unable to read Tailscale preferences: $prefs_json" >&2
        exit 1
      fi
      if ! printf '%s' "$prefs_json" | ${jq} -e 'type == "object"' >/dev/null; then
        echo "Tailscale returned invalid preferences." >&2
        exit 1
      fi
      if ! printf '%s' "$prefs_json" | ${jq} -e \
        --arg hostname ${lib.escapeShellArg hostname} \
        --argjson routes ${lib.escapeShellArg (builtins.toJSON ratgdoRoutes)} \
        '.ssh == true
          and ."advertise-exit-node" == false
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
          --shields-up=false \
          --ssh=true
      fi

      ${tailscaleServiceCommands}

      # Local config readback is not enough: the Services must also be defined
      # and this host approved by the tailnet control plane.
      services_active=false
      service_approval_state="service-host capability not present"
      for _ in {1..30}; do
        if service_status_json="$(${tailscale} status --json 2>&1)"; then
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
          service_approval_state="$service_status_json"
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done
      if [ "$services_active" != true ]; then
        echo "Tailscale Services are configured locally but not all are approved and active." >&2
        echo "Current service-host state: $service_approval_state" >&2
        echo "Define tcp:443 for svc:hb, svc:matterbridge, and svc:scrypted, then approve this host or configure service auto-approvers." >&2
        exit 1
      fi

      # Retire only the exact raw TCP mappings from the superseded port-based
      # design. Preserve every unrelated node handler and Tailscale Service.
      ${tailscaleLegacyServeCleanupCommands}
    '';

    serviceConfig = {
      KeepAlive.SuccessfulExit = false;
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = 300;
      ThrottleInterval = 30;
    };
  };
}
