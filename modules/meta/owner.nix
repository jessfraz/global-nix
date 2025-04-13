{ lib, ... }:
let
  username = "jessfraz";

  firstName = "Jess";
  nickName = "${firstName}ie";
  lastName = "Frazelle";

  formalName = lib.concatStringsSep " " [
    firstName
    lastName
  ];

  informalName = lib.concatStringsSep " " [
    nickName
    lastName
  ];
in
{
  flake = {
    meta.owner = {
      inherit
        username
        firstName
        lastName
        nickName
        formalName
        informalName
        ;
    };

    modules = {
      nixos.desktop = {
        users = {
          groups.plugdev.members = [ username ];
          users.${username} = {
            description = informalName;
            isNormalUser = true;
            extraGroups = [
              "wheel"
            ];
          };
        };
      };
      darwin.base.users.users.${username}.home = "/Users/${username}";
    };
  };
}
