{
  githubUsername,
  gitName,
  gitGpgKey,
  gitEmail,
  ...
}: {
  programs.git = {
    enable = true;

    userName = gitName;
    userEmail = gitEmail;
    signing = {
      key = gitGpgKey;
      signByDefault = true;
    };

    extraConfig = {
      github.user = githubUsername;
      init.defaultBranch = "main";
      pull.rebase = true;

      apply.whitespace = "fix";

      core = {
        excludesfile = "~/.gitignore";
        attributesfile = "~/.gitattributes";
        whitespace = "space-before-tab,-indent-with-non-tab,trailing-space";
        trustctime = false;
        editor = "nvim";
      };

      color = {
        ui = "auto";
        branch = {
          current = "yellow reverse";
          local = "yellow";
          remote = "green";
        };
        diff = {
          meta = "yellow bold";
          frag = "magenta bold";
          old = "red";
          new = "green";
        };
        status = {
          added = "yellow";
          changed = "green";
          untracked = "cyan";
        };
      };

      diff.renames = "copies";

      help.autocorrect = 1;

      merge.log = true;

      push = {
        default = "simple";
        autoSetupRemote = true;
      };

      url = {
        "git@github.com:github" = {
          insteadOf = [
            "https://github.com/github"
            "github:github"
            "git://github.com/github"
          ];
        };
        "git@github.com:" = {
          pushInsteadOf = [
            "https://github.com/"
            "github:"
            "git://github.com/"
          ];
        };
        "git://github.com/" = {
          insteadOf = "github:";
        };
        "git@gist.github.com:" = {
          insteadOf = "gst:";
          pushInsteadOf = [
            "gist:"
            "git://gist.github.com/"
          ];
        };
        "git://gist.github.com/" = {
          insteadOf = "gist:";
        };
      };

      filter.lfs = {
        clean = "git-lfs clean -- %f";
        smudge = "git-lfs smudge -- %f";
        process = "git-lfs filter-process";
        required = true;
      };
    };

    aliases = {
      # View abbreviated SHA, description, and history graph of the latest 20 commits
      l = "log --pretty=oneline -n 20 --graph --abbrev-commit";

      # View the current working tree status using the short format
      s = "status -s";

      # Show the diff between the latest commit and the current state
      d = "!\"git diff-index --quiet HEAD -- || clear; git --no-pager diff --patch-with-stat\"";

      # `git di $number` shows the diff between the state `$number` revisions ago and the current state
      di = "!\"d() { git diff --patch-with-stat HEAD~$1; }; git diff-index --quiet HEAD -- || clear; d\"";

      # Pull in remote changes for the current repository and all its submodules
      p = "!\"git pull; git submodule foreach git pull origin master\"";

      # Checkout a pull request from origin (of a github repository)
      pr = "!\"pr() { git fetch origin pull/$1/head:pr-$1; git checkout pr-$1; }; pr\"";

      # Clone a repository including all submodules
      c = "clone --recursive";

      # Commit all changes
      ca = "!git add -A && git commit -av";

      # Switch to a branch, creating it if necessary
      go = "!f() { git checkout -b \"$1\" 2> /dev/null || git checkout \"$1\"; }; f";

      # Color graph log view
      graph = "log --graph --color --pretty=format:\"%C(yellow)%H%C(green)%d%C(reset)%n%x20%cd%n%x20%cn%x20(%ce)%n%x20%s%n\"";

      # Show verbose output about tags, branches or remotes
      tags = "tag -l";
      branches = "branch -a";
      remotes = "remote -v";

      # Amend the currently staged files to the latest commit
      amend = "commit --amend --reuse-message=HEAD";

      # Credit an author on the latest commit
      credit = "!f() { git commit --amend --author \"$1 <$2>\" -C HEAD; }; f";

      # Interactive rebase with the given number of latest commits
      reb = "!r() { git rebase -i HEAD~$1; }; r";

      # Find branches containing commit
      fb = "!f() { git branch -a --contains $1; }; f";

      # Find tags containing commit
      ft = "!f() { git describe --always --contains $1; }; f";

      # Find commits by source code
      fc = "!f() { git log --pretty=format:'%C(yellow)%h\t%Cblue%ad  %Creset%s%Cgreen  [%cn] %Cred%d' --decorate --date=short -S$1; }; f";

      # Find commits by commit message
      fm = "!f() { git log --pretty=format:'%C(yellow)%h\t%Cblue%ad  %Creset%s%Cgreen  [%cn] %Cred%d' --decorate --date=short --grep=$1; }; f";

      # Remove branches that have already been merged with master
      # a.k.a. 'delete merged'
      dm = "!git branch --merged | grep -v '\\*' | xargs -n 1 git branch -d; git remote -v update -p";

      # List contributors with number of commits
      contributors = "shortlog --summary --numbered";

      lg = "log --color --decorate --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an (%G?)>%Creset' --abbrev-commit";

      mdiff = "!f() { git stash | head -1 | grep -q 'No local changes to save'; x=$?; git merge --no-commit $1 &>/dev/null; git add -u &>/dev/null; git diff --staged; git reset --hard &>/dev/null; test $x -ne 0 && git stash pop &>/dev/null; }; f";

      # Codereview aliases
      change = "codereview change";
      gofmt = "codereview gofmt";
      mail = "codereview mail";
      pending = "codereview pending";
      submit = "codereview submit";
      sync = "codereview sync";

      # from seth vargo
      unreleased = "!f() { git fetch --tags && git diff $(git tag | tail -n 1); }; f";
      up = "!git pull origin master && git remote prune origin && git submodule update --init --recursive";
      undo = "!git reset HEAD~1 --mixed";
      top = "!git log --format=format:%an | sort | uniq -c | sort -r | head -n 20";

      # from trevor bramble
      alias = "!git config -l | grep ^alias | cut -c 7- | sort";

      # from myles borins - github workflow helpers
      patchit = "!f() { echo $1.patch | sed s_pull/[0-9]*/commits_commit_ | xargs curl -L | git am --whitespace=fix; }; f";
      patchit-please = "!f() { echo $1.patch | sed s_pull/[0-9]*/commits_commit_ | xargs curl -L | git am -3 --whitespace=fix; }; f";
    };
  };
}
