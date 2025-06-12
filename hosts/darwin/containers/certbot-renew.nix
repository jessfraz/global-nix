{
  hostname,
  volumesPath,
  ...
}: {
  launchd.user.agents."${hostname}.certbot-renew" = {
    serviceConfig.ProgramArguments = [
      "/bin/sh"
      "-c"
      ''
        PATH="/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:$PATH"
        LABEL_NGINX="org.nixos.${hostname}.nginx"
        LABEL_ZNC="org.nixos.${hostname}.znc"
        DOMAIN_NGINX="gui/$(id -u)/$LABEL_NGINX"
        DOMAIN_ZNC="gui/$(id -u)/$LABEL_ZNC"
        PLIST_NGINX="$HOME/Library/LaunchAgents/$LABEL_NGINX.plist"
        PLIST_ZNC="$HOME/Library/LaunchAgents/$LABEL_ZNC.plist"

        # Tear down the LaunchAgent that runs the container
        launchctl bootout "$DOMAIN_NGINX" || true      # ignore "not loaded" errors
        launchctl bootout "$DOMAIN_ZNC" || true

        # Renew certificates
        certbot renew \
          --config-dir ${volumesPath}/letsencrypt \
          --work-dir   ${volumesPath}/letsencrypt \
          --logs-dir   ${volumesPath}/letsencrypt

        # Update the ZNC certificate
        cat ${volumesPath}/letsencrypt/live/irc.jess.dev/fullchain.pem ${volumesPath}/letsencrypt/live/irc.jess.dev/privkey.pem > ${volumesPath}/znc/znc.pem

        # Bring nginx back by re-loading its plist
        launchctl bootstrap "$DOMAIN_NGINX" "$PLIST_NGINX"
        # Bring znc back by re-loading its plist
        launchctl bootstrap "$DOMAIN_ZNC" "$PLIST_ZNC"
      ''
    ];

    ## schedule: 01 @ 03:15 in every even-numbered month
    serviceConfig.StartCalendarInterval = [
      {
        Month = 2;
        Day = 1;
        Hour = 3;
        Minute = 15;
      }
      {
        Month = 4;
        Day = 1;
        Hour = 3;
        Minute = 15;
      }
      {
        Month = 6;
        Day = 1;
        Hour = 3;
        Minute = 15;
      }
      {
        Month = 8;
        Day = 1;
        Hour = 3;
        Minute = 15;
      }
      {
        Month = 10;
        Day = 1;
        Hour = 3;
        Minute = 15;
      }
      {
        Month = 12;
        Day = 1;
        Hour = 3;
        Minute = 15;
      }
    ]; # launchd has no “*/2” modulo, you enumerate months  [oai_citation:1‡stackoverflow.com](https://stackoverflow.com/questions/70127661/running-launchd-services-with-non-root-user-on-macos?utm_source=chatgpt.com)

    serviceConfig.KeepAlive = false; # run–exit–done

    serviceConfig.StandardOutPath = "/tmp/certbot-renew.log";
    serviceConfig.StandardErrorPath = "/tmp/certbot-renew.log";

    environment.PATH = "/opt/homebrew/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin";
  };
}
