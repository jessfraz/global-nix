{
  pkgs,
  homeDir,
  hostname,
  ...
}: let
  calendarDndScript = pkgs.writeShellScript "calendar-dnd" (builtins.readFile ./calendar-dnd.sh);
in {
  launchd.user.agents."${hostname}.calendar-dnd" = {
    serviceConfig = {
      ProgramArguments = ["${calendarDndScript}"];
      StartInterval = 60;
      RunAtLoad = true;
      StandardOutPath = "${homeDir}/Library/Logs/calendar-dnd.log";
      StandardErrorPath = "${homeDir}/Library/Logs/calendar-dnd.err";
    };
  };
}
