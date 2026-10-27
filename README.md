# global-nix

NixOS, nix-darwin and Home Manager configuration for `macinator`, `macmini`
(Apple Silicon) and `system76` (x86_64 Linux).

Usernames, paths and services are hard-coded for these machines. Adapt them before
using this configuration elsewhere. For a first Nix setup, start with a small
package flake before managing a whole host.

## Setup

Install Nix with the [Determinate installer](https://github.com/DeterminateSystems/nix-installer).
Run these commands from this checkout on the matching host.

On macOS, build and activate once to bootstrap `darwin-rebuild`:

```sh
nix build .#darwinConfigurations.macinator.system
sudo ./result/sw/bin/darwin-rebuild switch --flake .#macinator
```

For later rebuilds, use `sudo darwin-rebuild switch --flake .#macinator`.
Replace `macinator` with `macmini` for the mini.

On NixOS:

```sh
sudo nixos-rebuild switch --flake .#system76
```

`nix store gc` removes unused store paths.

Linux installs Ghostty and runs Rex as a systemd user service, with lingering enabled.
Check Rex with `rex --autostart=false server status` or `systemctl --user status rex`.
Its pinned preview builds without a package token and stays out of the public cache.
On macOS, the `rex` launcher requires Rex.app or Rex Beta.app in `/Applications`
or `~/Applications`.

## Checks and updates

```sh
just ci          # Formatting, lint and tool tests
just eval        # Evaluate all platforms without building packages or updating the lockfile
just test-tools  # Tool tests only
just check-codex # Build Codex and check its daemon lifecycle in a temporary home
just update-pins # Refresh artifact pins and all flake inputs; validate Zoo's vendor tree
```

Individual updates: `just update-codex`, `just update-kicad`, `just update-mole`,
`just update-orcaslicer`, `just update-ramp` and `just update-zoo`.
The Zoo update also refreshes its Rust toolchain. Failed pin, lock or vendor validation
restores the original pin and lockfile contents, including local edits.
`nix flake update` refreshes flake inputs alone.

`just update-flakes-all` also commits and pushes lockfile updates in the sibling
`../dotfiles` and `../vim` clones before updating this checkout. Use it only when
those pushes are intended. See the [justfile](justfile) for all tasks.

[CI](.github/workflows/nix.yml) builds Linux Home Manager and both macOS hosts.
Only `packages.<system>.ci-cache` belongs in the public cache. Never publish host
generations, Home Manager generations or the whole store. macOS CI checks package
coverage and rejects host configuration in the cache.

The [dependency updater](.github/workflows/weekly-updates.yml) runs at 17:17 UTC
on days 1, 4, 7, etc. of each month. Updates on `automation/weekly-updates` merge
after all three CI jobs pass against the current base; they never deploy a host.
If `main` changes during CI, rebase and rerun. Unmerged human repairs block the
next generated refresh. The updater App needs Contents and Pull requests write
access, `DEPENDENCY_APP_CLIENT_ID` and `DEPENDENCY_APP_PRIVATE_KEY`; keep its key
in 1Password and the Actions secret.

Codex uses the complete upstream release archives. The Nix pin controls the CLI;
the daemon installed in the user's Codex home manages its own updates.

Run `disktree PATH` or `nix run .#disktree -- PATH` to scan a directory.
macOS also gets `Disktree.app`, but mount discovery and Trash handling still use
upstream's Linux conventions. `phone` requires separate local setup through the
[Switchboard phone guide](https://github.com/jessfraz/switchboard/blob/main/docs/phone.md).
Keep provider credentials and transcript keys outside Nix and Git.

## Credentials

`with-credentials PROFILE -- COMMAND` resolves credentials before starting a child
command and preserves its exit status. It works in scripts and GUI jobs too.

```sh
with-credentials axiom -- axiom query "['corp-kubernetes'] | take 5"
fetch-axiom-key axiom query "['corp-kubernetes'] | take 5"
with-credentials google.personal -- gws gmail users getProfile --params '{"userId":"me"}'
with-credentials ssh -- git fetch origin
with-credentials --doctor
```

With no command, the `fetch-*` shell functions export into the current shell.
Home Manager loads them in Bash and managed Zsh. In an existing or unmanaged shell:

```sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/with-credentials/shell.sh"
```

Bare GitHub helpers also update `.netrc` and Nix's GitHub access token.
`vault-login` uses OIDC and retains `VAULT_ADDR` in the shell.
Prefer `zoo-prod`, `zoo-dev`, `easypost-live` or `easypost-test` when one credential
is enough. Profile mappings are in [credentials.nix](home/programs/credentials.nix).

Configured provider namespaces use Switchboard. Add `--draft` before the profile
to prepare a write, or `--apply` to approve and execute it. Exit 70 means the write
outcome is uncertain: reconcile it before retrying.

Provision scoped 1Password access separately. Store the `personal` service-account
token at `~/.config/agent-credentials/personal.token` (under `XDG_CONFIG_HOME` when
set). Its directory must be owned by the current user with mode `0700`; the token
must be a regular, user-owned file with mode `0600` or `0400`. Missing tokens,
symlinks and invalid permissions fail without desktop fallback. Verify read-only
vault grants before enabling a profile. Never export the token globally or put it
in Nix, Git or logs.

Rotate the token by atomically replacing its file. Revoke the service account and
remove the file to disable access; revoke provider sessions and clear persistent
files such as `.netrc` separately. These permissions do not isolate processes
running as the same OS user. SSH still needs the YubiKey, PIN or touch where
required. Doctor checks configuration and socket health without reading secrets;
it does not prove remote authorization.

## Cleanup

`git cleanup` refreshes the remote base, fast-forwards the local base and removes
the current clean, merged branch or linked worktree. `gcleanup` also returns the
shell to the primary clone. On the base branch, cleanup only refreshes it.

Preview and review a saved plan before executing it. Keep it outside the target:

```sh
git cleanup --plan > /tmp/cleanup-plan.json
git cleanup --execute /tmp/cleanup-plan.json
```

Execution rechecks refs, merge evidence and local files. Missing remote branches
do not prove a merge. Ignored build output may be deleted with a linked worktree;
other ignored files block removal. Local changes are never discarded. `--force`
waives only the merge check and must be repeated when executing a force plan.
Submodule Git stores are retained under `cleanup-submodules/`; inspect the archive
named in the receipt before deleting it. `--no-gc` skips Git garbage collection.

`cleanup --dry-run` previews inactive build-cache removal and the merged Codex
worktree sweep. `cleanup-worktrees --dry-run` saves just worktree plans under
`$XDG_STATE_HOME/cleanup` (default `~/.local/state/cleanup`);
`cleanup-worktrees --execute DIRECTORY` executes reviewed plans. Busy, dirty,
locked or unverifiable worktrees are skipped. Sweeps retain primary clones.
Use existing home clones for normal work, or `wknew <branch>` for a sibling
worktree. See [git-cleanup](scripts/git-cleanup) and
[cleanup-worktrees.py](scripts/cleanup-worktrees.py) for options and refusal rules.

## Mac mini services

### Tailscale

The system `tailscaled` LaunchDaemon and
[reconciliation job](hosts/darwin/tailscale-home-server.nix) run after FileVault
unlock, before desktop login. A cold boot still needs the initial FileVault
password over LAN SSH.

For a handover from the GUI client, keep an independent management connection and
a timed rollback. The clients have separate login state but share routing; a
Tailscale ping alone does not prove SSH or Screen Sharing works.

1. Pause reconciliation with `sudo launchctl bootout system/org.nixos.tailscale-home-server`.
   Enroll the daemon with a `tag:home-server` auth key outside Nix and Git, a
   temporary hostname and `--socket=/var/run/tailscaled.socket`. Keep
   `--accept-dns=false` and `--accept-routes=false` during the overlap.
2. Disconnect the GUI VPN, then run
   `sudo launchctl kickstart -k system/com.tailscale.tailscaled` to recreate routes.
   Test fresh SSH and Screen Sharing connections through the daemon's own IP.
   If they fail, run `sudo tailscale --socket=/var/run/tailscaled.socket down`
   before reconnecting with `/Applications/Tailscale.app/Contents/MacOS/Tailscale up`.
3. Once verified, keep the GUI disconnected and disable its login item. Stop the
   old user job if loaded with
   `sudo launchctl bootout gui/$(id -u minitron)/org.nixos.tailscale-home-server`.
   Free the final `macmini` name, then resume reconciliation with
   `sudo launchctl bootstrap system /Library/LaunchDaemons/org.nixos.tailscale-home-server.plist`.
   Verify the name, tag, approved routes and Service hosts before retiring the old
   node. Preserve daemon state on rebuilds.

Check the client with `sudo tailscale --socket=/var/run/tailscaled.socket status`
and its job with `sudo launchctl print system/com.tailscale.tailscaled`.
Reconciliation logs are in `/Library/Logs/tailscale-home-server.{log,err}`.
Verify daemon access before a reboot or logout.

### ZNC

[ZNC](hosts/darwin/containers/znc.nix) keeps state in `~/.local/state/znc` on the
native filesystem. Do not put this mutable bind mount on exFAT. Before migrating,
make a private, checksum-verified backup of all state, including encryption
material and saved buffers. Copy and verify it, then change only ZNC's bind mount
during a planned interruption. Activation does not migrate data or create an
empty configuration.

Container port 6697 is published without TLS only at `127.0.0.1:12345`.
Tailscale terminates TLS on port 443. Define `svc:irc` with `tcp:443` in the
tailnet control plane and approve macmini as its service host; local Serve
configuration alone does not publish its DNS name. Keep existing access rules;
Funnel is unnecessary.

Before startup, verified AppleDouble metadata in savebuff directories moves to
`.appledouble-savebuff`. Preserve it: ZNC 1.8 otherwise mistakes it for encrypted
buffers and stops loading valid buffers. Saved buffers and encryption settings
are left intact.
