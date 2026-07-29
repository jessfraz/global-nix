{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.darwinServiceWatchdog;

  escape = lib.escapeShellArg;
  optionalValue = value:
    if value == null
    then ""
    else toString value;

  renderLogFile = logFile: ''
    rotate_log ${escape logFile.path} ${toString logFile.maxBytes} ${toString logFile.keepBytes}
  '';

  renderCheck = _: check: ''
    ${lib.concatMapStringsSep "\n" renderLogFile check.logFiles}
    check_service \
      ${escape check.label} \
      ${toString check.startupGraceSeconds} \
      ${toString check.failureThreshold} \
      ${toString check.restartCooldownSeconds} \
      ${lib.concatMapStringsSep " " escape check.urls}
  '';

  watchdogScript = pkgs.writeShellScript "darwin-service-watchdog" ''
    set -u

    uid="$(/usr/bin/id -u)"
    state_dir=${escape cfg.stateDir}
    log_file="$state_dir/watchdog.log"
    curl=${escape "${pkgs.curl}/bin/curl"}
    timeout_seconds=${toString cfg.timeoutSeconds}
    restart_max_load_average=${escape (optionalValue cfg.restartMaxLoadAverage)}
    restart_max_swap_used_mib=${escape (optionalValue cfg.restartMaxSwapUsedMiB)}

    /bin/mkdir -p "$state_dir"

    now() {
      /bin/date +%s
    }

    log() {
      printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$log_file"
    }

    key_for_label() {
      printf '%s' "$1" | /usr/bin/sed 's/[^A-Za-z0-9_.-]/_/g'
    }

    read_state() {
      local path="$1"
      local default_value="$2"

      if [ -f "$path" ]; then
        /bin/cat "$path"
      else
        printf '%s' "$default_value"
      fi
    }

    read_int_state() {
      local value

      value="$(read_state "$1" "$2")"
      case "$value" in
        ""|*[!0-9]*)
          printf '%s' "$2"
          ;;
        *)
          printf '%s' "$value"
          ;;
      esac
    }

    write_state() {
      local path="$1"
      local value="$2"

      printf '%s\n' "$value" > "$path"
    }

    service_pid() {
      /bin/launchctl print "gui/$uid/$1" 2>/dev/null | /usr/bin/awk '/pid =/ { print $3; exit }'
    }

    rotate_log() {
      local path="$1"
      local max_bytes="$2"
      local keep_bytes="$3"
      local size
      local tmp

      if [ ! -f "$path" ]; then
        return 0
      fi

      size="$(/usr/bin/stat -f '%z' "$path" 2>/dev/null || printf '0')"
      case "$size" in
        ""|*[!0-9]*)
          return 0
          ;;
      esac

      if [ "$size" -le "$max_bytes" ]; then
        return 0
      fi

      tmp="$state_dir/$(/usr/bin/basename "$path").$$.tail"
      if /usr/bin/tail -c "$keep_bytes" "$path" > "$tmp"; then
        : > "$path"
        /bin/cat "$tmp" > "$path"
        log "truncated $path from $size bytes to the latest $keep_bytes bytes"
      else
        log "failed to truncate $path"
      fi
      /bin/rm -f "$tmp"
    }

    host_pressure_blocks_restart() {
      local label="$1"
      local load_average
      local swap_used_mib

      if [ -n "$restart_max_load_average" ]; then
        load_average="$(/usr/bin/uptime | /usr/bin/awk -F'load averages?: ' '{ split($2, a, " "); gsub(",", "", a[1]); print a[1] }')"
        if [ -n "$load_average" ] && /usr/bin/awk -v value="$load_average" -v limit="$restart_max_load_average" 'BEGIN { exit !(value >= limit) }'; then
          log "$label restart suppressed by host pressure: load average $load_average >= $restart_max_load_average"
          return 0
        fi
      fi

      if [ -n "$restart_max_swap_used_mib" ]; then
        swap_used_mib="$(/usr/sbin/sysctl -n vm.swapusage | /usr/bin/sed -E 's/.*used = ([0-9]+)(\.[0-9]+)?M.*/\1/')"
        case "$swap_used_mib" in
          ""|*[!0-9]*)
            ;;
          *)
            if [ "$swap_used_mib" -ge "$restart_max_swap_used_mib" ]; then
              log "$label restart suppressed by host pressure: swap used ''${swap_used_mib}MiB >= ''${restart_max_swap_used_mib}MiB"
              return 0
            fi
            ;;
        esac
      fi

      return 1
    }

    check_service() {
      local label="$1"
      local grace_seconds="$2"
      local failure_threshold="$3"
      local restart_cooldown_seconds="$4"
      shift 4

      local key
      local pid
      local pid_file
      local first_seen_file
      local failure_file
      local last_restart_file
      local first_seen
      local elapsed
      local failures
      local url
      local failed_url
      local current_time
      local last_restart

      key="$(key_for_label "$label")"
      pid_file="$state_dir/$key.pid"
      first_seen_file="$state_dir/$key.first-seen"
      failure_file="$state_dir/$key.failures"
      last_restart_file="$state_dir/$key.last-restart"

      current_time="$(now)"
      pid="$(service_pid "$label")"

      if [ -n "$pid" ] && [ "$pid" != "$(read_state "$pid_file" "")" ]; then
        write_state "$pid_file" "$pid"
        write_state "$first_seen_file" "$current_time"
        write_state "$failure_file" 0
        log "$label observed pid $pid"
      fi

      if [ -z "$pid" ]; then
        failed_url="no launchd pid"
      else
        first_seen="$(read_int_state "$first_seen_file" "$current_time")"
        elapsed=$((current_time - first_seen))

        if [ "$elapsed" -lt "$grace_seconds" ]; then
          return 0
        fi

        failed_url=""
        for url in "$@"; do
          if ! "$curl" -kfsS --connect-timeout "$timeout_seconds" --max-time "$timeout_seconds" -o /dev/null "$url" >/dev/null 2>&1; then
            failed_url="$url"
            break
          fi
        done
      fi

      if [ -z "$failed_url" ]; then
        if [ "$(read_int_state "$failure_file" 0)" != 0 ]; then
          log "$label recovered"
        fi
        write_state "$failure_file" 0
        return 0
      fi

      failures=$(($(read_int_state "$failure_file" 0) + 1))
      write_state "$failure_file" "$failures"
      log "$label unhealthy ($failures/$failure_threshold): $failed_url"

      if [ "$failures" -lt "$failure_threshold" ]; then
        return 0
      fi

      last_restart="$(read_int_state "$last_restart_file" 0)"
      if [ $((current_time - last_restart)) -lt "$restart_cooldown_seconds" ]; then
        log "$label restart suppressed by cooldown"
        return 0
      fi

      if host_pressure_blocks_restart "$label"; then
        return 0
      fi

      log "restarting $label"
      if /bin/launchctl kickstart -k "gui/$uid/$label" >> "$log_file" 2>&1; then
        write_state "$last_restart_file" "$current_time"
        write_state "$failure_file" 0
        /bin/rm -f "$pid_file" "$first_seen_file"
      else
        log "failed to restart $label"
      fi
    }

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderCheck cfg.checks)}
  '';
in {
  options.services.darwinServiceWatchdog = {
    enable = lib.mkEnableOption "Darwin launchd HTTP health watchdog";

    user = lib.mkOption {
      type = lib.types.str;
      default = config.users.primaryUser or (builtins.getEnv "USER");
      description = "User that owns watchdog state.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/Users/${config.services.darwinServiceWatchdog.user}/.local/state/darwin-service-watchdog";
      description = "Directory used for watchdog state and logs.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "How often launchd runs the watchdog.";
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Per-endpoint curl timeout.";
    };

    restartMaxLoadAverage = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 32;
      description = "Skip service restarts while the 1-minute host load average is at or above this value.";
    };

    restartMaxSwapUsedMiB = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 4096;
      description = "Skip service restarts while macOS reports at least this much swap in use.";
    };

    checks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          label = lib.mkOption {
            type = lib.types.str;
            description = "launchd label to restart.";
          };

          urls = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "HTTP endpoints that must answer for the service to be healthy.";
          };

          startupGraceSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 300;
            description = "Seconds to wait after observing a new PID before health failures count.";
          };

          failureThreshold = lib.mkOption {
            type = lib.types.ints.positive;
            default = 3;
            description = "Consecutive failed checks required before restarting.";
          };

          restartCooldownSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 600;
            description = "Minimum seconds between forced restarts for this service.";
          };

          logFiles = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                path = lib.mkOption {
                  type = lib.types.str;
                  description = "Log file to truncate in place when it grows too large.";
                };

                maxBytes = lib.mkOption {
                  type = lib.types.ints.positive;
                  default = 10485760;
                  description = "Maximum size before truncation.";
                };

                keepBytes = lib.mkOption {
                  type = lib.types.ints.positive;
                  default = 1048576;
                  description = "Number of trailing bytes to keep after truncation.";
                };
              };
            });
            default = [];
            description = "Log files to cap before checking service health.";
          };
        };
      });
      default = {};
      description = "launchd services and endpoints to monitor.";
    };
  };

  config = lib.mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    assertions =
      lib.mapAttrsToList (name: check: {
        assertion = check.urls != [];
        message = "services.darwinServiceWatchdog.checks.${name}.urls must not be empty";
      })
      cfg.checks;

    system.activationScripts.darwin-service-watchdog-state.text = ''
      install -d -m0755 -o ${cfg.user} -g staff ${lib.escapeShellArg cfg.stateDir}
    '';

    launchd.user.agents.darwin-service-watchdog.serviceConfig = {
      Label = "org.nixos.darwin-service-watchdog";
      ProgramArguments = ["${watchdogScript}"];
      RunAtLoad = true;
      StartInterval = cfg.intervalSeconds;
      StandardOutPath = "${cfg.stateDir}/watchdog.log";
      StandardErrorPath = "${cfg.stateDir}/watchdog.log";
      ProcessType = "Background";
    };
  };
}
