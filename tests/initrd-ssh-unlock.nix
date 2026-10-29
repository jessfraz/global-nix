{
  pkgs,
  nixpkgsPath,
}: let
  keyFixtures = "${nixpkgsPath}/nixos/tests/initrd-network-ssh";
in
  pkgs.testers.runNixOSTest {
    name = "initrd-ssh-unlock";

    nodes = {
      machine = {lib, ...}: {
        imports = [../modules/initrd-ssh-unlock.nix];

        virtualisation = {
          emptyDiskImages = [512];
          useBootLoader = true;
          mountHostNixStore = true;
          useEFIBoot = true;
        };
        boot.loader.systemd-boot.enable = true;
        boot.initrd = {
          availableKernelModules = ["virtio_net"];
          network.ssh = {
            hostKeys = lib.mkForce ["/etc/ssh/initrd-test-host-key"];
            authorizedKeyFiles = [(keyFixtures + "/id_ed25519.pub")];
          };
          secrets."/etc/ssh/initrd-test-host-key" = lib.mkForce (keyFixtures + "/ssh_host_ed25519_key");
        };
        environment.systemPackages = [pkgs.cryptsetup];

        specialisation.boot-luks.configuration = {
          boot.initrd.luks.devices = lib.mkVMOverride {
            cryptroot.device = "/dev/vdb";
          };
          virtualisation.rootDevice = "/dev/mapper/cryptroot";
        };
      };

      client = {
        environment.systemPackages = [pkgs.openssh pkgs.netcat-openbsd];
        environment.etc = {
          sshKey = {
            source = keyFixtures + "/id_ed25519";
            mode = "0600";
          };
          knownHosts.text = "[machine]:2222 ${pkgs.lib.fileContents (keyFixtures + "/ssh_host_ed25519_key.pub")}";
        };
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            interface = "eth1";
            bind-interfaces = true;
            port = 0;
            dhcp-authoritative = true;
            dhcp-range = ["192.168.1.2,192.168.1.2,255.255.255.0,1h"];
          };
        };
        networking.firewall.allowedUDPPorts = [67];
      };
    };

    testScript = {nodes, ...}: let
      encryptedBoot = nodes.machine.specialisation.boot-luks.configuration.system.build.toplevel;
    in ''
      start_all()
      client.wait_for_unit("dnsmasq.service")
      machine.wait_for_unit("multi-user.target")
      machine.succeed("printf supersecret | cryptsetup luksFormat -q --iter-time=1 /dev/vdb -")
      machine.succeed("printf supersecret | cryptsetup luksOpen -q /dev/vdb cryptroot")
      machine.succeed("mkfs.ext4 /dev/mapper/cryptroot")
      machine.succeed("${encryptedBoot}/bin/switch-to-configuration boot")
      machine.succeed("sync")
      machine.crash()

      with subtest("console unlock works without any Ethernet link"):
          machine.start()
          machine.block()
          machine.send_monitor_command("set_link virtio-net-pci.0 off")
          machine.wait_for_console_text("Please enter passphrase for disk cryptroot")
          machine.send_console("supersecret\n")
          machine.wait_for_unit("multi-user.target")
          machine.succeed("test \"$(findmnt -n -o SOURCE /)\" = /dev/mapper/cryptroot")
          machine.succeed("test -z \"$(ss -lntH 'sport = :2222')\"")
          machine.crash()

      with subtest("authenticated SSH is limited to unlocking and stops after boot"):
          machine.start()
          machine.unblock()
          machine.send_monitor_command("set_link virtio-net-pci.0 on")
          client.wait_until_succeeds("nc -4 -z -w1 machine 2222")
          client.succeed(
              "mkfifo /tmp/unlock-input; "
              "(exec 3<>/tmp/unlock-input; "
              "ssh -4 -tt -i /etc/sshKey -o BatchMode=yes -o StrictHostKeyChecking=yes "
              "-o UserKnownHostsFile=/etc/knownHosts -o ConnectTimeout=10 "
              "-p 2222 root@machine 'echo INITRD_SHELL_WAS_ALLOWED' <&3) "
              ">/tmp/unlock.log 2>&1 &"
          )
          client.wait_until_succeeds("grep -q 'Please enter passphrase for disk cryptroot' /tmp/unlock.log")
          client.succeed("printf 'supersecret\\n' > /tmp/unlock-input")
          machine.wait_for_unit("multi-user.target")
          machine.succeed("test \"$(findmnt -n -o SOURCE /)\" = /dev/mapper/cryptroot")
          client.wait_until_succeeds("ping -4 -c1 -W1 machine")
          client.fail("nc -4 -z -w1 machine 2222")
          client.fail("grep -q INITRD_SHELL_WAS_ALLOWED /tmp/unlock.log")
          machine.succeed("test -z \"$(ss -lntH 'sport = :2222')\"")
    '';
  }
