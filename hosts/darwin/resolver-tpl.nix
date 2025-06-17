{
  pkgs,
  username,
  githubUsername,
  tplIpPrefix,
  tplResolverFile,
  ...
}: let
  myNameserver = "${tplIpPrefix}.6";
in {
  environment.etc.${tplResolverFile} = {
    text = ''
      nameserver ${myNameserver}
      port 53
    '';
  };
}
