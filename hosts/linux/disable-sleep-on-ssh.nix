# This expression was written by `cbrauchli` at https://discourse.nixos.org/t/disable-suspend-if-ssh-sessions-are-active/11655/4
# with minor modifications by Dominic Mayhew
{pkgs, ...}: let
  PID_PATH = "/tmp/ssh_sleep_block.pid";
  PID_PIPE = "pid_pipe";

  # Prevent sleeping on active SSH
  sleep_script =
    pkgs.writeScript "infinite-sleep"
    ''
      #!/bin/sh

      echo $$ >${PID_PATH}
      echo $$ >${PID_PIPE}
      sleep infinity
    '';

  inhibit_script =
    pkgs.writeScript "inhibit_script"
    ''
      #!/bin/sh

      systemd-inhibit --what=sleep --why="Active SSH session" --mode=block ${sleep_script} 0>&- &> /tmp/inhibit.out &
    '';

  ssh_script =
    pkgs.writeScript "ssh-session-handler"
    ''
      #!/bin/sh
      #
      # This script runs when an ssh session opens/closes, and masks/unmasks
      # systemd sleep and hibernate targets, respectively.
      #
      # Inspired by: https://unix.stackexchange.com/a/136552/84197 and
      #              https://askubuntu.com/a/954943/388360

      num_ssh=$(netstat -nt | awk '$4 ~ /:22$/ && $6 == "ESTABLISHED"' | wc -l)

      # echo "User id is $UID, num_ssh is $num_ssh, pam type $PAM_TYPE" > /tmp/ssh_user

      case "$PAM_TYPE" in
          open_session)
              if [ "$num_ssh" -gt 1 ]; then
                  exit
              fi

              logger "Starting sleep inhibitor"
              mkfifo ${PID_PIPE}
              ${inhibit_script}
              logger "Sleep inhibitor started with PID $(cat ${PID_PIPE})"
              rm ${PID_PIPE}
              ;;

          close_session)
              if [ "$num_ssh" -ne 0 ]; then
                  exit
              fi

              logger "Killing sleep inhibitor PID $(cat ${PID_PATH})"
              kill -9 $(cat ${PID_PATH}) && rm ${PID_PATH}
              ;;

          *)
              exit
      esac

    '';
in {
  security.pam.services.sshd.text = pkgs.lib.mkDefault (
    pkgs.lib.mkAfter
    "# Prevent sleep on active SSH\nsession optional pam_exec.so quiet ${ssh_script}"
  );
}
