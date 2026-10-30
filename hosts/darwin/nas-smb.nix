{
  config,
  lib,
  hostname,
  homeDir,
  username,
  ...
}: let
  mountPackage =
    lib.findFirst (package: package.name == "nas-smb-mount")
    (throw "NAS SMB mount package is missing")
    config.home-manager.users.${username}.home.packages;
in {
  launchd.user.agents."${hostname}.nas-smb" = {
    serviceConfig = {
      ProgramArguments = [
        (lib.getExe mountPackage)
        "--mount-point"
        "${homeDir}/NAS/Shared_Drive"
      ];
      RunAtLoad = true;
      StartInterval = 300;
      ProcessType = "Background";
      StandardOutPath = "${homeDir}/Library/Logs/nas-smb.log";
      StandardErrorPath = "${homeDir}/Library/Logs/nas-smb.log";
      Umask = 63;
    };
  };
}
