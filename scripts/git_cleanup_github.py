"""Read GitHub's merge evidence for worktrees whose commits were squash merged."""

import json
import os
import re
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from types import FrameType


@dataclass(frozen=True)
class MergedPullRequest:
    number: int
    repository: str
    head: str
    merge: str


def github_repository(origin: str) -> str | None:
    match = re.fullmatch(
        r"(?:git@github\.com:|ssh://git@github\.com(?::22)?/|https://github\.com/)"
        r"([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)/?",
        origin,
    )
    if match is None:
        return None
    owner, name = match.groups()
    name = name.removesuffix(".git")
    return f"{owner}/{name}" if name not in ("", ".", "..") else None


def _is_commit(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


def parse_merged_pull_requests(response: str) -> tuple[MergedPullRequest, ...]:
    """Consume the nested pages emitted by gh api --paginate --slurp."""
    try:
        pages = json.loads(response)
        if not isinstance(pages, list):
            raise TypeError("expected pages")
        pulls = []
        for page in pages:
            if not isinstance(page, list):
                raise TypeError("expected pull request list")
            for item in page:
                if not isinstance(item, dict):
                    raise TypeError("expected pull request")
                if item["merged_at"] is None:
                    continue
                number = item["number"]
                repository = item["base"]["repo"]["full_name"]
                head = item["head"]["sha"]
                merge = item["merge_commit_sha"]
                if (
                    type(number) is not int
                    or number <= 0
                    or not isinstance(repository, str)
                    or not isinstance(item["merged_at"], str)
                    or not item["merged_at"]
                    or not _is_commit(head)
                    or not _is_commit(merge)
                ):
                    raise ValueError("invalid merged pull request")
                pulls.append(MergedPullRequest(number, repository, head, merge))
        return tuple(pulls)
    except (KeyError, TypeError, ValueError) as error:
        raise OSError("Invalid GitHub merged-PR response") from error


def _stop_process(process: subprocess.Popen[str]) -> None:
    # Keep the session leader unreaped until its whole group has been stopped.
    for stop in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, stop)
        except ProcessLookupError:
            pass
        if stop == signal.SIGTERM:
            time.sleep(0.1)
    try:
        process.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        # An escaped process can retain a pipe after this owned group is dead.
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
        process.wait(timeout=1)


def _run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    allowed: tuple[int, ...] = (0,),
    timeout: float = 45,
) -> subprocess.CompletedProcess[str]:
    process: subprocess.Popen[str] | None = None
    interrupted = False

    def terminate(signum: int, _frame: FrameType | None) -> None:
        nonlocal interrupted
        interrupted = True
        if process is not None:
            raise SystemExit(128 + signum)

    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        process = subprocess.Popen(
            command,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            if interrupted:
                raise SystemExit(128 + signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            # The sweep sends TERM before KILL; stop this nested session first.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            _stop_process(process)
            raise
        result = subprocess.CompletedProcess(
            command, process.returncode, stdout, stderr
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise OSError(
            f"Merged-PR check could not run {command[0]}: {str(error)[:300]}"
        ) from error
    finally:
        signal.signal(signal.SIGTERM, previous)
    if result.returncode not in allowed:
        reason = " ".join((result.stderr or result.stdout).split())[:300]
        raise OSError(
            f"Merged-PR check failed ({command[0]}, exit {result.returncode}): {reason}"
        )
    return result


def _git(
    root: Path, *args: str, allowed: tuple[int, ...] = (0,)
) -> subprocess.CompletedProcess[str]:
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    for key in ("GIT_SSH", "GIT_SSH_COMMAND", "GIT_ALLOW_PROTOCOL"):
        if key in os.environ:
            env[key] = os.environ[key]
    return _run(
        ["git", "--no-optional-locks", "-C", str(root), *args], env=env, allowed=allowed
    )


def _has_commit(root: Path, commit: str) -> bool:
    return (
        _git(
            root, "cat-file", "-e", f"{commit}^{{commit}}", allowed=(0, 1, 128)
        ).returncode
        == 0
    )


def verify_merged_pr(
    root: Path, head: str, base_head: str, repository: str, pull: MergedPullRequest
) -> str | None:
    """Verify merged metadata against the freshly fetched base and local HEAD."""
    if not all(
        _is_commit(commit) for commit in (head, base_head, pull.head, pull.merge)
    ):
        raise OSError("Invalid commit ID in merged-PR evidence")
    if pull.repository.casefold() != repository.casefold():
        return None
    if not _has_commit(root, pull.merge):
        return None
    if _git(
        root, "merge-base", "--is-ancestor", pull.merge, base_head, allowed=(0, 1)
    ).returncode:
        return None
    if not _has_commit(root, pull.head):
        # The PR ref may advance after the API read. Never substitute its new HEAD.
        _git(root, "fetch", "--no-tags", "origin", f"refs/pull/{pull.number}/head")
        fetched = _git(root, "rev-parse", "FETCH_HEAD").stdout.strip()
        if fetched != pull.head:
            return None
    if _git(
        root, "merge-base", "--is-ancestor", head, pull.head, allowed=(0, 1)
    ).returncode:
        return None
    return pull.merge


def find_merged_pr(root: Path, head: str, base_head: str) -> str | None:
    """Return a verified merge commit, or raise on unavailable provider evidence."""
    origin = _git(root, "remote", "get-url", "origin", allowed=(0, 2))
    if origin.returncode:
        return None
    repository = github_repository(origin.stdout.strip())
    if repository is None:
        return None
    if not _is_commit(head) or not _is_commit(base_head):
        raise OSError("Invalid commit ID in merged-PR check")
    response = _run(
        [
            "with-credentials",
            "github.personal",
            "--",
            "gh",
            "api",
            f"repos/{repository}/commits/{head}/pulls",
            "--hostname",
            "github.com",
            "--paginate",
            "--slurp",
        ]
    )
    for pull in parse_merged_pull_requests(response.stdout):
        merge = verify_merged_pr(root, head, base_head, repository, pull)
        if merge is not None:
            return merge
    return None
