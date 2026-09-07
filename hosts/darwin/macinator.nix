{
  pkgs,
  inputs,
  homeDir,
  hostname,
  ...
}: let
  autoDndScript = pkgs.writeShellScript "auto-dnd" (builtins.readFile ./auto-dnd.sh);
in {
  environment.systemPackages = [
    pkgs.wireshark
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.kicad
  ];

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
