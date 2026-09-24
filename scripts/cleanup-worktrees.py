#!/usr/bin/env python3
"""Remove inactive, verified-merged Codex worktrees and keep per-worktree receipts."""

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

CLEANUP = Path(__file__).with_name("git-cleanup")


def discover(root: Path) -> tuple[list[Path], list[tuple[Path, str]]]:
    """Codex stores a checkout at the container root or one directory below it."""
    found = []
    errors = []
    if root.is_symlink() or not root.is_dir():
        return found, errors
    for container in sorted(root.iterdir()):
        try:
            if container.is_symlink() or not container.is_dir():
                continue
            if (container / ".git").is_file():
                found.append(container.resolve())
                continue
            for checkout in sorted(container.iterdir()):
                try:
                    if not checkout.is_symlink() and (checkout / ".git").is_file():
                        found.append(checkout.resolve())
                except OSError as error:
                    errors.append((checkout, str(error)))
        except OSError as error:
            errors.append((container, str(error)))
    return found, errors


def git(worktree: Path, *arguments: str) -> bytes:
    # Like git-cleanup, inspect the named checkout, not inherited Git routing.
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    result = subprocess.run(
        ["git", "-C", str(worktree), *arguments],
        env={**env, "GIT_OPTIONAL_LOCKS": "0"},
        capture_output=True,
        check=True,
        timeout=30,
    )
    return result.stdout


def require_unshared(worktree: Path, discovered: list[Path]) -> None:
    sources = set(discovered)
    sources.update(
        Path(os.fsdecode(field.removeprefix(b"worktree "))).resolve()
        for field in git(worktree, "worktree", "list", "--porcelain", "-z").split(b"\0")
        if field.startswith(b"worktree ")
    )

    for source in sorted(sources - {worktree}):
        if source.is_symlink() or not source.is_dir():
            continue
        pending = [str(source)]
        while pending:
            # Cache directories can contain links to another checkout. DirEntry
            # metadata avoids a separate stat for every ordinary build file.
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    if entry.name == ".git":
                        continue
                    if entry.is_symlink():
                        target = Path(entry.path).resolve()
                        if target == worktree or worktree in target.parents:
                            raise OSError(f"referenced by symlink {entry.path}")
                    elif entry.is_dir(follow_symlinks=False):
                        pending.append(entry.path)


def active_directories() -> list[tuple[str, Path]]:
    result = subprocess.run(
        [
            "lsof",
            "-w",
            "-nP",
            "+c",
            "0",
            "-a",
            "-u",
            str(os.getuid()),
            "-d",
            "cwd,txt",
            "-F0pcfn",
        ],
        capture_output=True,
        check=False,
        timeout=30,
    )
    if result.returncode not in (0, 1) or not result.stdout:
        raise OSError("could not inspect processes using worktrees")
    active = []
    pid, command = "", ""
    for field in result.stdout.split(b"\0"):
        field = field.lstrip(b"\n")
        if not field:
            continue
        kind, value = chr(field[0]), os.fsdecode(field[1:])
        if kind == "p":
            pid = value
        elif kind == "c":
            command = value
        elif kind == "n" and value.startswith("/"):
            active.append((f"{command} (PID {pid})", Path(value)))
    return active


def require_inactive(worktree: Path) -> None:
    for process, path in active_directories():
        if path == worktree or worktree in path.parents:
            raise OSError(f"in use by {process}")


def require_clean(worktree: Path) -> None:
    if git(
        worktree, "status", "--porcelain", "--untracked-files=normal", "--ignored=no"
    ):
        raise OSError("checkout has tracked or untracked changes")


def invoke(worktree: Path, *arguments: str, timeout: float = 180) -> dict:
    process = subprocess.Popen(
        [sys.executable, str(CLEANUP), *arguments],
        cwd=worktree,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # Let nested helpers clean up their sessions, then stop the entire group.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise
    if process.returncode:
        raise OSError(stderr.strip() or "git cleanup failed")
    return json.loads(stdout)


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def execute(plan_file: Path, discovered: list[Path]) -> dict:
    plan = json.loads(plan_file.read_text())
    worktree = Path(plan["worktree"])
    if not plan.get("remove_worktree") or plan.get("force"):
        raise OSError("sweep requires a merged linked-worktree plan")
    if plan_file.resolve().is_relative_to(worktree.resolve()):
        raise OSError("cleanup plan must be stored outside its worktree")
    require_clean(worktree)
    require_inactive(worktree)
    require_unshared(worktree, discovered)
    return invoke(
        worktree,
        "--execute",
        str(plan_file),
        "--no-update-base",
        "--no-gc",
        "--json",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run", action="store_true", help="Save plans without deleting worktrees"
    )
    mode.add_argument(
        "--execute",
        type=Path,
        metavar="DIRECTORY",
        help="Execute the saved plans in a preview receipt directory",
    )
    parser.add_argument(
        "--root",
        type=Path,
        help="Worktree container directory (default: $CODEX_HOME/worktrees)",
    )
    args = parser.parse_args()
    state = (
        Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "cleanup"
    )
    state.mkdir(parents=True, exist_ok=True)
    receipts = (
        args.execute.resolve()
        if args.execute
        else Path(tempfile.mkdtemp(prefix="worktrees-", dir=state))
    )
    removed, skipped, planned = 0, 0, 0
    try:
        if args.execute:
            index = json.loads((receipts / "index.json").read_text())
            entries = index["entries"]
            root = Path(index["root"])
        else:
            root = (
                args.root
                or Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
                / "worktrees"
            )
        discovered, discovery_errors = discover(root)
        for path, reason in discovery_errors:
            skipped += 1
            print(f"SKIP {path}: {reason}", flush=True)
        if not args.execute:
            entries = [{"worktree": str(path)} for path in discovered]
        index = {"root": str(root.resolve()), "entries": entries}
        save(receipts / "index.json", index)
        for entry in entries:
            worktree = Path(entry["worktree"])
            key = hashlib.sha256(str(worktree).encode()).hexdigest()[:16]
            plan_file = receipts / f"{key}.plan.json"
            try:
                if args.execute:
                    if not plan_file.exists():
                        skipped += 1
                        continue
                else:
                    require_clean(worktree)
                    require_inactive(worktree)
                    require_unshared(worktree, discovered)
                    plan = invoke(worktree, "--plan")
                    if (
                        not plan.get("remove_worktree")
                        or plan.get("force")
                        or Path(plan["worktree"]) != worktree
                    ):
                        raise OSError("not a verified-merged linked worktree")
                    save(plan_file, plan)
                if args.dry_run:
                    planned += 1
                    entry["status"] = "planned"
                    print(f"WOULD REMOVE {worktree}", flush=True)
                    continue
                receipt = execute(plan_file, discovered)
                save(receipts / f"{key}.receipt.json", receipt)
                entry["status"] = receipt["status"]
                if receipt.get("worktree_removed"):
                    removed += 1
                    print(f"REMOVED {worktree}", flush=True)
                    if receipt.get("retained_submodules"):
                        print(
                            f"RETAINED Git storage: {receipt['retained_submodules']}",
                            flush=True,
                        )
                    # Codex container directories can remain after Git removes the checkout.
                    try:
                        container = worktree.parent
                        if container != root.resolve():
                            marker = container / ".codex-worktree-name"
                            if (
                                set(container.iterdir()) == {marker}
                                and marker.is_file()
                                and not marker.is_symlink()
                            ):
                                marker.unlink()
                            container.rmdir()
                    except OSError:
                        pass
                else:
                    skipped += 1
                    print(f"SKIP {worktree}: {receipt['summary']}", flush=True)
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                skipped += 1
                entry.update(status="skipped", reason=str(error))
                print(f"SKIP {worktree}: {error}", flush=True)
            finally:
                save(receipts / "index.json", index)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"SKIP worktree sweep: {error}", flush=True)
        return 0
    action = f"Would remove {planned}" if args.dry_run else f"Removed {removed}"
    print(f"{action} worktrees; skipped {skipped}. Receipts: {receipts}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
