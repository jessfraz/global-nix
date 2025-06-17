{tplResolverFile, ...}: let
  myNameserver = "192.168.1.24";
in {
  environment.etc.${tplResolverFile} = {
    text = ''
      nameserver ${myNameserver}
      port 53
    '';
  };
}
