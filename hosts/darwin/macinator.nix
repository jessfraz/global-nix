{
  pkgs,
  homeDir,
  hostname,
  ...
}: let
  autoDndScript = pkgs.writeShellScript "auto-dnd" (builtins.readFile ./auto-dnd.sh);
in {
  launchd.user.agents."${hostname}.auto-dnd" = {
    serviceConfig = {
      ProgramArguments = ["${autoDndScript}"];
      StartInterval = 120;
      RunAtLoad = true;
      StandardOutPath = "${homeDir}/Library/Logs/auto-dnd.log";
      StandardErrorPath = "${homeDir}/Library/Logs/auto-dnd.err";
    };
  };
}
