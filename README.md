# global-nix

Global nix configuration for my desktop and laptops.

These are just mine. They are imperfect in so many ways, but they work. I tried not to use a lot of plugins and just the raw Nix language. I like flakes. I get some people don't but I do :) sue me.

# Installation

> **NOTE:** Don't actually install these configs on your machine. My username is hard coded places!!

Refer to the instructions in [github.com/DeterminateSystems/nix-installer](https://github.com/DeterminateSystems/nix-installer).

## MacOS

1. `nix build .#darwinConfigurations.macinator.system`
1. `./result/sw/bin/darwin-rebuild switch --flake .#macinator`

**OR**

If nix is already installed, you can just do:

`darwin-rebuild switch --flake .#macinator`

## Linux

`nixos-rebuild switch --flake .#system76`

## Shared

To cleanup the world run `nix store gc`

## Build checks and caching

Run `just ci` for formatting and lint, and `just eval` to evaluate all platforms without building packages or changing the lockfile. The evaluation first materializes package derivations and their sources so the flake check also works with an empty Nix store.

CI also builds the native Home Manager configuration on Linux and both host configurations on macOS. The public cache receives only the packages selected by `packages.<system>.ci-cache`; generated host configurations and Home Manager generations stay out of it. Linux CI can read Ghostty's upstream cache and includes the unconfigured terminal package in the selected outputs. Automated dependency merges explicitly dispatch a main-branch build to populate that cache.

Dependency updates run every three days at 17:17 UTC for both the Nix pins/flake inputs and Dependabot's GitHub Actions checks. The cron schedule runs on days 1, 4, 7, and so on each month, so month-boundary gaps can be shorter than three days. Nix updates merge only after **Test Nix Flake** succeeds and never deploy a host.

The Nix updater uses the private `jessfraz-global-nix-updater` GitHub App,
installed only on this repository with Contents and Pull requests read/write
permissions. Actions needs the `DEPENDENCY_APP_CLIENT_ID` repository variable
and `DEPENDENCY_APP_PRIVATE_KEY` repository secret. The private key is backed up
in 1Password, never in this repository. App-authored updates run normal PR CI,
so build jobs appear on the PR without a workflow-approval step. The merge job
still verifies the bot identity, tested commit, changed-file allowlist, and
current base before merging.

The default package bundle is shared by all hosts. KiCad is installed separately on the desktop hosts, OrcaSlicer is installed on macinator, and the editor tools come from the `.vim` flake's `editor-tools` package. Rust keeps the compiler, Cargo, source, Clippy, and rustfmt without the offline documentation.

The Switchboard CLI bundle includes `phone`. Its Nix package carries the locked
voice-worker source and Python interpreter; the worker environment and private
namespace settings are prepared locally using the
[phone setup guide](https://github.com/jessfraz/switchboard/blob/main/docs/phone.md).
Provider credentials and transcript decryption keys stay outside this repository.

The macOS OrcaSlicer package uses the official universal release. Run `just update-orcaslicer` to update its version and source hash, or `just update-pins` to include it with the other pins. The dependency workflow uses the same updater.

# My personal opinon on how to get started.

Don't start here. Start with a flake that just installs some packages on your host. Drink a bit of that koolaid, install more things, uninstall things. Make flakes in specific repos to use `nix develop` devShells or package binaries in a repo. THEN, if you are thinking this is neat and want to go deeper, start looking into nixOS and darwin-nix for configuring your machines. This was how I went about it.

The reason I mention this is THERE IS A LOT OF CONTENT ON NIX out there and SO MANY different ways to do things. If you start with a big goal its too much information overhead all at once. _First_, dip your toes into just flakes. (Of course some people will say fuck flakes but I like them, personally. This is the type of information overhead and opinions I'm talking about).

## Command credentials and cleanup

`with-credentials` runs a child command with the required credentials. It works
from noninteractive Bash, Zsh, and GUI jobs without loading shell functions.
Credentials stay in the child environment or private temporary files; the
launcher never prints exports. It resolves every required credential before
starting the command and preserves the command's exit status.

```sh
with-credentials axiom -- axiom query "['corp-kubernetes'] | take 5"
fetch-axiom-key axiom query "['corp-kubernetes'] | take 5"
with-credentials google.personal -- gws gmail users getProfile --params '{"userId":"me"}'
with-credentials --doctor
with-credentials ssh -- git fetch origin
```

The `fetch-*` names are executable compatibility wrappers, with a new
command-scoped interface. Replace `fetch-axiom-key; axiom query ...` with
`fetch-axiom-key axiom query ...`. A bare wrapper fails before authentication.
They no longer modify the parent shell, `.netrc`, or Nix configuration.

Configured namespaces are read from Switchboard's config and dispatched through
its CLI, including `github.personal`, `google.personal`, `google.work`, and
`schwab.personal` when configured. Use `--draft` to prepare a provider write or
`--apply` to explicitly approve and execute the selected command. Successful
reads/applications return native provider output; drafts return the Switchboard
receipt. An uncertain write returns exit 70 and must be reconciled before retry.

Other profiles are declared in `home/programs/credentials.nix`. Existing cached
files are read first; vault lookup is bounded to a single 60-second window per
invocation and stops on its first failure. Home Assistant reads its endpoint from
the vault item's `website` field or `~/.config/home-assistant/url`, alongside the
cached token at `~/.config/home-assistant/token`. The SSH profile uses the socket from
`gpgconf`, correcting a stale inherited socket only for the child. Doctor checks
configuration, executable availability, and socket reachability without reading
credentials or unlocking the agent. Neither check proves a particular key is
inserted or that remote authorization succeeds.

Local `kittycad-pr-automerge` calls use Switchboard and share a run identifier.
An explicitly supplied CI token keeps its existing direct `gh` path. Unknown
write outcomes stop the command, including its merge-method fallback loop.

`git cleanup` now prints a JSON plan and performs no deletion by default:

```sh
git cleanup > /tmp/cleanup-plan.json
git cleanup --execute /tmp/cleanup-plan.json
```

Keep the plan outside the target worktree. Execution fetches again, compares the
reviewed refs and evidence, and checks tracked, untracked, and recursive
submodule content. Ignored files also block linked-worktree removal, with the
blocking paths included in the error. It accepts ancestry or matching squash
patch plus exact touched-file content. A missing remote branch is not proof of a
merge. Locked worktrees, failed fetches, changed plans, and Git removal refusals
stop cleanup.
Only the named local worktree/branch is removed; it does not pull, garbage
collect, or delete remote branches. When run in the primary worktree it switches
to the existing local base branch before deleting the reviewed feature branch.
Ignored files outside submodules are kept in a primary worktree, and the switch
refuses ignored-file collisions. Ignored files inside populated submodules still
block cleanup because a branch switch can replace an entire submodule directory.
Populated or deinitialized submodule Git stores are retained intact under the
primary Git directory's `cleanup-submodules/`, including local branches, stashes,
objects, and reflogs. The execution receipt names that archive; inspect it before
any manual deletion. For example, inspect retained refs with
`git --git-dir "$archive/modules/sub" --work-tree "$PWD" show-ref`; the explicit
worktree overrides the original checkout path retained in the archived config.
Stores with symlinks or alternate-object dependencies need
manual preservation and are refused. `gcleanup --execute` also returns the shell
to the primary worktree after a successful linked-worktree removal.

`--force` permits deleting an unmerged branch only after reviewing a force plan
and repeating `--force` during execution. It never discards local file changes.
Remove disposable ignored build output yourself before planning linked-worktree
removal.

Run `just test-tools` for real disposable-repository and credential-child
regressions. `just ci` includes these tests.

## Other tips

- Claude and OpenAI are decent at Nix files. But you have to know what to ask for or else they will fuck it all up. It's almost better to be like "deep research X nix specific thing and tell me your findings". This will eliminate the overhead (all us nerds do) of learning something new and going super deep on blogs.

- Use the links below to the module sources. I found this the best way to get the current options for specific modules.

## Helpful Links

- [NixOS Module Source](https://github.com/NixOS/nixpkgs/tree/master/nixos/modules)
- [Home Manager Module Source](https://github.com/nix-community/home-manager/tree/master/modules)
- [nix-darwin Module Source](https://github.com/nix-darwin/nix-darwin/tree/master/modules)
- [Nix lang visual 'splainer](https://zaynetro.com/explainix)
