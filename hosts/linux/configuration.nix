{
  config,
  pkgs,
  inputs,
  ...
}: {
  users.users.jessfraz = {
    isNormalUser = true;
  };
}
