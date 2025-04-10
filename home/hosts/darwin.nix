{...}: {
  # Fix for https://github.com/nix-community/home-manager/issues/5997
  programs.bash.initExtra = ''
    gpgconf --launch gpg-agent
  '';
  programs.bash.sessionVariables = {
    SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
  };
}
