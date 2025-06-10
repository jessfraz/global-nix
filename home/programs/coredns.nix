{
  config,
  pkg,
  githubUsername,
  ...
}: let
  tplIpPrefix = "10.42.9";
  tplIpPrefixReverse = "9.42.10";
  corednsDirPath = "${config.home.homeDirectory}/coredns";
in {
  home.packages = [
    pkg.coredns
  ];

  home.file = {
    "${corednsDirPath}/${tplIpPrefixReverse}.in-addr.arpa".text = ''
      $ORIGIN ${tplIpPrefixReverse}.in-addr.arpa.
      $TTL 86400
      @   IN  SOA ns1.${githubUsername}.tpl. admin.${githubUsername}.tpl. (
            2024020501  ; Serial
            7200        ; Refresh
            3600        ; Retry
            1209600     ; Expire
            86400       ; Minimum TTL
      )
        IN  NS  ns1.${githubUsername}.tpl.

      1   IN  PTR ${githubUsername}.tpl.
      254 IN  PTR ns1.${githubUsername}.tpl.
    '';

    "${corednsDirPath}/Corefile".text = ''
      # sudo ifconfig vlan0 alias ${tplIpPrefix}.254 up
      . {
        forward . 10.42.254.51 10.42.254.52
        errors
        log
        bind ${tplIpPrefix}.254
      }

      ${githubUsername}.tpl {
        file ${corednsDirPath}/${githubUsername}.tpl
        errors
        log
        bind ${tplIpPrefix}.254
        acl {
          allow type AXFR net 10.42.0.0/16
          allow type IXFR net 10.42.0.0/16
          block type AXFR net *
          block type IXFR net *
        }
        transfer {
          to *
        }
      }

      ${tplIpPrefixReverse}.in-addr.arpa {
        file ${corednsDirPath}/${tplIpPrefixReverse}.in-addr.arpa
        errors
        log
        bind ${tplIpPrefix}.254
      }
    '';

    "${corednsDirPath}/${githubUsername}.tpl".text = ''
      $ORIGIN ${githubUsername}.tpl.
      $TTL 86400
      @   IN  SOA ns1.${githubUsername}.tpl. admin.${githubUsername}.tpl. (
              2024020501  ; Serial
              7200        ; Refresh
              3600        ; Retry
              1209600     ; Expire
              86400       ; Minimum TTL
      )
          IN  NS  ns1

      ns1 IN  A   ${tplIpPrefix}.254

      _pki IN TXT "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlxfU+TEWhcxtxjBGntY9O3Qee3KiuH7CPYC7fsrORi
      ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCl9xcA41v4JxOSnFlMCUJRbl3NvZvNWV4mMavq0yW/xue/kwqy9b8qfff61NEYsdXlUoVJdpjUIQOeDKg2aAMeAGQV8bwJLYCFMw/peQrs8Qa73TAuuQ/hwID5OGhjcm/vSqUGwyer1XfEZfKuJBLWT5C3mpF3sKvsZAu++a72+pJesdJjw1f9lQrD0NdgImn1FA5SYRcQr6zjDIhioA/4F1RPvNTQ4rUbnP+f0Wtw545p6H9TZbeVQpJDZj2WrUVkZF08hN941VAyA4ra0Ujvq1vP/sXMnv+3OpIFxaezOKwOn7IejFdA9OKCyvg8fuksdpeRHqyA3ciK/J11Xahh
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzDj1crpw+1sj03Dgxif8SVLglNC7s0E3rbihTqg2td
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINXMGbdH1HoFJZdZ631qvIUMNbWG8RDEQOhWfb4CsRKK"

      @   IN  A   ${tplIpPrefix}.1
    '';
  };
}
