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

CI also builds the native Home Manager configuration on Linux and both host configurations on macOS. The public cache receives only the packages selected by `packages.<system>.ci-cache`; generated host configurations and Home Manager generations stay out of it. Packages are published after their build and Codex runtime checks pass, before host builds, so unrelated host failures cannot block caching. Linux CI can read Ghostty's upstream cache and includes the unconfigured terminal package in the selected outputs. Automated dependency merges explicitly dispatch a main-branch build to populate that cache.

macOS CI checks both hosts' complete runtime closures against `ci-cache`, including packages used only by service scripts. Missing package outputs fail CI. Generated derivations marked `preferLocalBuild`, source files, and an exact list of host tools, scripts, files and manuals remain local; their package dependencies must still be covered. The check also rejects generated host/configuration outputs in the public cache. Keep new public package selections independent of host configuration: do not push host generations or the whole store.

CoreDNS's cache/ACL regression exercises the configured DNS server and plugin chain with distinct client addresses through its test response writer. All allowed/blocked and cache-isolation assertions remain enabled, without requiring a privileged `127.0.0.2` loopback alias on macOS. Its dnstap tests allow one second for handshakes instead of a fragile 10ms deadline. The full upstream test suite still runs during the package build.

Dependency updates run every three days at 17:17 UTC for both the Nix pins/flake inputs and Dependabot's GitHub Actions checks. The cron schedule runs on days 1, 4, 7, and so on each month, so month-boundary gaps can be shorter than three days. Nix updates merge only after **Test Nix Flake** succeeds and never deploy a host.

The Nix updater uses the private `jessfraz-global-nix-updater` GitHub App,
installed only on this repository with Contents and Pull requests read/write
permissions. Actions needs the `DEPENDENCY_APP_CLIENT_ID` repository variable
and `DEPENDENCY_APP_PRIVATE_KEY` repository secret. The private key is backed up
in 1Password, never in this repository. App-authored updates run normal PR CI,
so build jobs appear on the PR without a workflow-approval step. Updates on
`automation/weekly-updates`, including human-pushed repairs, merge automatically
after all three CI jobs pass. The merge job verifies the PR's repository, branch,
tested head, and tested base. If `main` changes during CI, rebase and rerun CI;
the merge job will not regenerate the branch and discard repairs.

The default package bundle is shared by all hosts. KiCad and Disktree are installed separately on the desktop hosts, OrcaSlicer is installed on macinator, and the editor tools come from the `.vim` flake's `editor-tools` package. Rust keeps the compiler, Cargo, source, Clippy, and rustfmt without the offline documentation.

Codex uses the complete upstream release packages with pinned archive checksums.
The package preserves the upstream binaries and helpers, including macOS signatures
and the Linux sandbox helper's embedded integrity check. `just update-codex` updates
the release source and both platform archives together. Package builds run the
matching upstream layout validator; `just check-codex` also exercises helper loading
and daemon startup, version reporting, and shutdown in an isolated temporary home.
CI runs that lifecycle check outside the Nix build sandbox on both platforms.
The NixOS host enables `nix-ld` with `ncurses` for upstream's dynamically linked
shell and voice helpers, including daemon-managed copies and updates.

Codex's default daemon installation copies its package into the user's Codex home
and manages its own updates. The Nix pin controls the CLI package; it does not pin
that separately managed daemon. The packaging preserves upstream's update behavior.

`just update-pins` refreshes artifact pins, then resolves all flake inputs once.
Zoo's Cargo vendor tree is built and rebuilt against that final graph to check
reproducibility, and native CI builds the same graph on Linux and macOS. Failed
pin, lock, or vendor validation restores the original pin and lockfile contents,
including existing local edits. `just update-zoo` refreshes only Zoo and its shared
Rust toolchain together. Vendor validation uses the exported `zoo` package. The scheduled
updater refuses to replace an update branch containing unmerged human repairs;
those repairs must be resolved or merged before the next generated refresh.

Disktree is built from the source revision in `flake.lock` and updates through the normal flake refresh. Run `disktree` to scan home, `disktree PATH` for one directory, or `nix run .#disktree -- PATH` before switching a host. macOS also gets `Disktree.app`. Upstream currently targets Linux; the macOS build uses its native GPUI backend, but mount discovery and Trash handling still follow upstream's Linux conventions.

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
In command mode, credentials stay in the child environment or private temporary
files. It resolves every required credential before starting the command and
preserves the command's exit status.

```sh
with-credentials axiom -- axiom query "['corp-kubernetes'] | take 5"
fetch-axiom-key axiom query "['corp-kubernetes'] | take 5"
with-credentials google.personal -- gws gmail users getProfile --params '{"userId":"me"}'
with-credentials --doctor
with-credentials ssh -- git fetch origin
```

The `fetch-*` helpers support both interfaces. With no arguments, the shell
function exports credentials into the current shell, so `fetch-axiom-key; axiom
query ...` still works. With a command, `fetch-axiom-key axiom query ...` passes
credentials only to that command. Executable wrappers retain the command form
for scripts and jobs that have not loaded the shell functions.

Home Manager loads the functions in Bash and in Zsh when its Zsh module is
enabled. For an already-open shell, or an unmanaged Zsh configuration, source
the shared fragment after applying the configuration:

```sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/with-credentials/shell.sh"
fetch-github-token
```

Bare GitHub helpers also refresh `.netrc` and the Nix GitHub access token. Google
helpers select the personal or work config directory and clear conflicting
token and credentials-file overrides. The Cockroach helper writes its persistent
certificate to `~/.cockroach/ca.crt`; command mode uses a private temporary file.
The shell functions capture the resolver's explicit `--shell PROFILE` output,
which contains quoted exports and unsets, and apply it only after resolution
succeeds. Run the helpers rather than printing that credential-bearing output.
The `vault-login` shell helper retains `VAULT_ADDR` for subsequent commands and
uses OIDC authentication. Its executable form uses the same OIDC flow.

Command-mode namespaces are read from Switchboard's config and dispatched through
its CLI, including `github.personal`, `google.personal`, `google.work`, and
`schwab.personal` when configured. Use `--draft` to prepare a provider write or
`--apply` to explicitly approve and execute the selected command. Successful
reads/applications return native provider output; drafts return the Switchboard
receipt. An uncertain write returns exit 70 and must be reconciled before retry.

Other profiles are declared in `home/programs/credentials.nix`. Scoped secrets
name an `auth_profile`, vault, item and field. The generated
`~/.config/with-credentials/auth-profiles.json` maps each authentication profile to
`~/.config/agent-credentials/personal.token`. One authentication profile,
`personal`, reads the selected personal and work credentials from the `AI Agents`
vault in the personal 1Password account. Provider accounts and Google session
namespaces remain separate. Provision the service-account token separately from
Nix: the directory must be owned by the current user with mode `0700`, and the
regular token file with mode `0600` or `0400`. Symlinks, missing tokens and invalid
permissions stop the command without desktop fallback.
The token enters only the `op` lookup process. Provider commands receive their
selected credentials with all inherited `OP_*` variables removed. Do not export a
service-account token globally or place one in Nix configuration, Git or logs.

Vault lookup is bounded to a single 60-second window per invocation and stops on
its first failure. Selected fields from the same account, authentication profile,
vault and item share one lookup; duplicate references reuse that result in memory
for the invocation. Separate helper invocations still resolve their scoped fields
again. Configured provider commands use Switchboard's existing one-hour cache,
which coordinates cold lookups and records confirmed quota cooldowns across
processes. No helper credential cache or longer credential lifetime is added.
Scoped profiles do not use the old unbound file caches. Home
Assistant therefore reads the endpoint labeled `website` and its API token from
its scoped vault item; the old Home Assistant cache files are not consulted or
rewritten. Provider session caches managed by Switchboard remain independent.
Legacy profiles without `auth_profile` retain their existing cache and desktop
session behavior, but never select an account through an ambient service-account
or Connect token. `XDG_CONFIG_HOME` defaults to `~/.config`.

Use `zoo-prod`, `zoo-dev`, `easypost-live` or `easypost-test` when a command needs
only one credential. Existing `zoo` and `easypost` aggregate helpers remain
available. The global commit-message helper uses the same `openai` resolver and
skips generation when credentials are unavailable.

Provision and verify the destination vaults, items and read-only service-account
grants before activating a new profile mapping. Rotate a bootstrap token by
atomically replacing its private file; the next invocation reads the new token.
To disable access, revoke the service account and remove its token file. Provider
sessions and legacy consumer files such as `.netrc` have their own lifetime and
must be revoked or cleared separately when withdrawing their access. File modes
do not isolate different processes running as the same operating-system user.

The SSH profile uses the socket from `gpgconf`, correcting a stale inherited
socket only for the child. Doctor checks configuration, executable availability,
and socket reachability without reading credentials or unlocking the agent.
Neither check proves a particular key is inserted or that remote authorization
succeeds. Service-account tokens do not replace YubiKey insertion, PIN or touch
requirements, OAuth consent, or the need for an awake runner.

Local `kittycad-pr-automerge` calls use Switchboard and share a run identifier.
An explicitly supplied CI token keeps its existing direct `gh` path. Unknown
write outcomes stop the command, including its merge-method fallback loop.

`git cleanup` fetches the remote base branch without fetching tags or unrelated
refs, updates the local base branch with a fast-forward, and cleans up the current
merged branch/worktree. It then prunes stale worktree metadata and runs Git garbage
collection (skip with `--no-gc`).
Running it on the base branch refreshes it without deleting the branch.
`gcleanup` does the same and returns the shell to the primary worktree after a
successful linked-worktree removal. Both print a readable completion message in
the terminal. Captured `git cleanup` output remains a JSON receipt so existing
shell functions keep working after an update; `--json` explicitly requests it.

Both accept `--plan` for a non-destructive preview. To inspect a plan before
executing it:

```sh
git cleanup --plan > /tmp/cleanup-plan.json
git cleanup --execute /tmp/cleanup-plan.json
```

Keep saved plans outside the target worktree. Execution fetches again, compares
the planned refs and evidence, and checks tracked, untracked, and recursive
submodule content. Conventional ignored build directories beside their project
manifest (Rust targets, JavaScript dependencies/builds, and Python environments
and tool caches) are included in the plan and deleted with the linked worktree.
Other ignored files still block removal, with the paths included in the error.
It accepts ancestry, matching squash patches with exact touched-file content,
or a GitHub merged-PR record whose published head contains this checkout and
whose merge commit is present on the freshly fetched base. This also handles
detached baseline/review checkouts and rebased PRs. A missing remote branch is
not proof of a merge. Locked worktrees, failed fetches, changed plans, and Git
removal refusals stop cleanup of that checkout.
Only the named local worktree/branch is removed; remote branches are never
deleted. The base update completes before the feature branch/worktree is
removed. When cleaning a linked worktree, a dirty primary checkout is left
untouched and its base update is skipped with a warning.
Ignored files outside submodules are kept in a primary worktree, and the switch
refuses ignored-file collisions. Ignored files inside populated submodules still
block cleanup because a branch switch can replace an entire submodule directory.
Populated or deinitialized submodule Git stores are retained intact under the
primary Git directory's `cleanup-submodules/`, including local branches, stashes,
objects, and reflogs. The completion output names that archive; inspect it before
any manual deletion. For example, inspect retained refs with
`git --git-dir "$archive/modules/sub" --work-tree "$PWD" show-ref`; the explicit
worktree overrides the original checkout path retained in the archived config.
Stores with symlinks or alternate-object dependencies need manual preservation
and are refused.

`--force` permits deleting an unmerged branch. When executing a saved force plan,
repeat `--force` during execution. It never discards local file changes.
The receipt reports removed build directories and their estimated size. Active
cache users cause that worktree to be kept with a successful `skipped` receipt,
so cleanup can be retried after the build finishes. Build output is never moved
into a preservation directory. Primary-checkout caches remain in place.
Plain `cleanup` handles inactive build caches across projects and Codex tasks,
then sweeps verified-merged Codex worktrees. Use `cleanup --dry-run` to preview
both. Cache discovery and `git cleanup` share the project-output policy from
the dotfiles input, including Next.js `.next` output beside `package.json`.
`gcleanup` delegates to `git cleanup` and uses the same policy. Repository output
must be ignored and contain no tracked files; active cache users are preserved.
`cleanup-worktrees` runs just the worktree sweep; its `--dry-run` saves
plans under `$XDG_STATE_HOME/cleanup` (default `~/.local/state/cleanup`). Run
`cleanup-worktrees --execute DIRECTORY` to execute those reviewed plans.
Each worktree is rechecked before removal. Busy, dirty, locked, unmerged, or
unverifiable checkouts are skipped while others continue. Checkouts supplying
shared files through symlinks to another worktree are retained. The sweep never
removes a primary clone, changes its checked-out branch, or follows build
symlinks into their destinations. Empty Codex containers and their name markers
are removed with the finished checkout.

Normal work uses the existing home-directory clones, including repositories
under `~/zoo`, rather than creating new disposable checkouts in `~/.codex`.
When isolation is useful, `wknew <branch>` creates a sibling worktree and
`gcleanup` removes the finished sibling and returns to its primary clone.
An explicit cleanup of a disposable Codex checkout deletes that checkout and
its build output permanently. Cleanup of a normal clone retains the repository
and brings its base branch up to date.

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

### Mac mini Tailscale startup

Only `macmini` uses the system `tailscaled` LaunchDaemon. It starts after
FileVault unlock, before desktop login, and its Serve/subnet reconciliation
runs in the system launchd domain too. Other hosts keep their current clients.
FileVault still needs the initial password over LAN SSH after a cold boot.
Once macOS starts, Tailscale makes SSH and enabled Screen Sharing reachable
without a desktop login.

When switching an existing mini from the GUI client, enroll the system daemon
while keeping the GUI connection available as a fallback. The clients have
independent login state, but share the Mac's routing table. An authenticated
daemon and a successful Tailscale ping do not prove SSH or Screen Sharing can
reach macOS while the GUI owns those routes. Uninstalling the GUI app is optional.

Pause the system reconciliation job during enrollment so it does not replace
the temporary hostname: `sudo launchctl bootout system/org.nixos.tailscale-home-server`.
Authenticate the daemon once with a `tag:home-server` auth key outside Nix and
Git, using a temporary node name and the explicit system socket. Keep
`--accept-dns=false` and `--accept-routes=false` during the overlap. Test the
handover through an independent management connection with a timed rollback:
disconnect the GUI VPN, then run
`sudo launchctl kickstart -k system/com.tailscale.tailscaled` to recreate the
daemon's routes. Verify fresh SSH and Screen Sharing connections through its
own IP. If they fail, run
`sudo tailscale --socket=/var/run/tailscaled.socket down` before reconnecting
the GUI with `/Applications/Tailscale.app/Contents/MacOS/Tailscale up`.

After the new connection works, keep the GUI disconnected, disable its login
item if enabled, stop the old user
job if loaded with `sudo launchctl bootout gui/$(id -u minitron)/org.nixos.tailscale-home-server`,
and free the final `macmini` name before restoring system reconciliation.
Bootstrap `/Library/LaunchDaemons/org.nixos.tailscale-home-server.plist` into
the system domain to resume reconciliation. Verify the node name, tag,
approved routes and Service hosts before retiring the old tailnet node. Keep
the daemon's persistent state in place on subsequent rebuilds.

Use `sudo tailscale --socket=/var/run/tailscaled.socket status` to check the
system client and `sudo launchctl print system/com.tailscale.tailscaled` to
check its job. Reconciliation logs are in
`/Library/Logs/tailscale-home-server.{log,err}`. The system daemon must be
authenticated and reachable before testing a reboot or logging out.

### ZNC state and Tailscale IRC

macmini keeps ZNC state in `~/.local/state/znc` on its native filesystem.
Do not use the external exFAT volume for this mutable Docker bind mount: it has
returned VirtioFS `Bad file descriptor` errors while ZNC continued running in
memory. Before moving an existing installation, preserve the complete state
(including config, module encryption material and saved buffers) in a private,
checksum-verified backup. Copy the state without resetting encryption or deleting
buffers, verify the new copy, and switch only ZNC's bind mount during a planned
interruption. The bind mount and config check fail closed if migration is missing;
Nix activation does not migrate data.

ZNC listens without TLS on container port 6697, published only at
`127.0.0.1:12345`. Tailscale terminates TLS for
`irc.osiris-dinosaur.ts.net:443`. Separately define `svc:irc` with `tcp:443` in the
tailnet admin console (or the Services API) and approve tagged macmini as its
service host. Local Serve
configuration and advertisement alone do not publish the service DNS name. Keep
existing tailnet access rules; this does not require Funnel or broader ACLs.

Before ZNC starts, verified AppleDouble (`._`) metadata in savebuff directories
is moved into `.appledouble-savebuff` within the state directory. These files
are preserved, not deleted. ZNC 1.8 savebuff otherwise treats metadata as encrypted
buffers and clears its working key after the first failure, preventing valid
buffers from loading. Actual saved buffers and encryption settings are untouched.
