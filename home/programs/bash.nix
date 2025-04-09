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
    '';
  };
}
