{
  pkgs,
  inputs,
  homeDir,
  hostname,
  ...
}: let
  autoDnd = pkgs.callPackage ../../pkgs/auto-dnd.nix {};
in {
  services.agent.role = "worker";

  environment.systemPackages = [
    pkgs.wireshark
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.disktree
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.kicad
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.orca-slicer
    autoDnd
  ];

  launchd.user.agents."${hostname}.auto-dnd" = {
    serviceConfig = {
      ProgramArguments = [
        "${autoDnd}/Applications/Auto DND.app/Contents/MacOS/auto-dnd"
      ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 60;
      ExitTimeOut = 40;
      StandardOutPath = "${homeDir}/Library/Logs/auto-dnd.log";
      StandardErrorPath = "${homeDir}/Library/Logs/auto-dnd.err";
    };
  };
}
