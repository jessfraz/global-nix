{config, ...}: {
  programs.bash = {
    enable = true;

    enableCompletion = true;

    shellOptions = [
      # check the window size after each command and, if necessary,
      # update the values of LINES and COLUMNS.
      "checkwinsize"
      # Case-insensitive globbing (used in pathname expansion)
      "nocaseglob"
      # Append to the Bash history file, rather than overwriting it
      "histappend"
      # Autocorrect typos in path names when using `cd`
      "cdspell"
      # `**/qux` will enter `./foo/bar/baz/qux`
      "autocd"
      # * Recursive globbing, e.g. `echo **/*.txt`
      "extglob"
      "globstar"
      # Warn if closing shell with running jobs.
      "checkjobs"
    ];

    historySize = 50000000;
    historyFileSize = 50000000;
    historyControl = ["ignoredups"];
    historyIgnore = ["exit"];

    # Load the other bash dotfiles we have.
    bashrcExtra = ''
      source ${config.home.homeDirectory}/.nixbash

      # Keep GPG_TTY aligned in interactive terminals.
      if [ -t 1 ]; then
          export GPG_TTY="$(tty)"
      fi

      function wknew() {
          local b="$1"
          if [ -z "$b" ]; then
              echo "usage: wknew <branch>"
              return 1
          fi
          local repo wt
          repo=$(basename "$(git rev-parse --show-toplevel)") || return $?
          wt="../$repo-$b"
          git worktree add -b "$b" "$wt" origin/main || return $?
          git -C "$wt" submodule update --init --recursive || return $?
          git -C "$wt" config branch.$b.remote origin || return $?
          git -C "$wt" config branch.$b.merge refs/heads/$b || return $?
          cd "$wt" || return $?
      }

      function gcleanup() {
          local receipt primary argument
          for argument in "$@"; do
              case "$argument" in
                  -h|--help) git cleanup "$@"; return $? ;;
              esac
          done
          receipt=$(git cleanup --json "$@") || return $?
          printf '%s' "$receipt" | python3 -c 'import json,sys; result=json.load(sys.stdin); print(result.get("summary", json.dumps(result, indent=2)))' || return $?
          primary=$(printf '%s' "$receipt" | python3 -c 'import json,sys; result=json.load(sys.stdin); print(result["primary_worktree"] if result.get("status") == "completed" and result.get("worktree_removed") else "")') || return $?
          if [ -n "$primary" ]; then
              cd "$primary" || return $?
          fi
      }
    '';

    # Fix for https://github.com/nix-community/home-manager/issues/5997
    initExtra = ''
      gpgconf --launch gpg-agent
    '';
    sessionVariables = {
      SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
    };
  };
}
