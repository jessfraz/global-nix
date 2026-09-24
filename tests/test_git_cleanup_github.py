"""Exercise native GitHub merge evidence against real disposable Git history."""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path

from scripts.git_cleanup_github import (
    find_merged_pr,
    github_repository,
    parse_merged_pull_requests,
    verify_merged_pr,
)

# Captured from gh api --paginate --slurp for modeling-app #13988, 2026-09-24.
# Unconsumed fields are omitted; the provider's page and object shapes are intact.
CAPTURED_RESPONSE = """[[{
  "merge_commit_sha": "d2f7712388efe52ec89594a4142f52493d8d6cf2",
  "merged_at": "2026-09-24T01:54:26Z",
  "number": 13988,
  "state": "closed",
  "head": {"sha": "0a89275399f5381a11e2a944fcd81e9fe78961a6"},
  "base": {"repo": {"full_name": "KittyCAD/modeling-app"}}
}]]"""


class GitHubCommandLifetimeTests(unittest.TestCase):
    def test_timeout_and_termination_stop_descendants_with_closed_output(self) -> None:
        script = Path(
            os.environ.get(
                "GIT_CLEANUP_GITHUB_SCRIPT",
                Path(__file__).resolve().parents[1] / "scripts/git_cleanup_github.py",
            )
        )
        child = (
            "import os,signal,sys,time; from pathlib import Path; "
            "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
            "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        )
        parent = (
            "import os,subprocess,sys,time; from pathlib import Path; "
            "Path(sys.argv[2]+'.parent').write_text(str(os.getpid())); "
            "subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(30)"
        )
        driver = (
            "import runpy,sys; runpy.run_path(sys.argv[1])['_run']("
            "[sys.executable,'-c',sys.argv[2],sys.argv[3],sys.argv[4]],"
            "timeout=float(sys.argv[5]))"
        )
        with tempfile.TemporaryDirectory() as temporary:
            for mode in ("timeout", "termination"):
                with self.subTest(mode=mode):
                    marker = Path(temporary) / mode
                    process = subprocess.Popen(
                        [
                            sys.executable,
                            "-c",
                            driver,
                            str(script),
                            parent,
                            child,
                            str(marker),
                            "0.5" if mode == "timeout" else "30",
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    child_pid = None
                    try:
                        deadline = time.monotonic() + 5
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertTrue(marker.exists(), "child did not start")
                        child_pid = int(marker.read_text())
                        if mode == "termination":
                            process.send_signal(signal.SIGTERM)
                        process.communicate(timeout=5)
                        self.assertNotEqual(process.returncode, 0)
                        status = subprocess.run(
                            ["ps", "-p", str(child_pid), "-o", "stat="],
                            capture_output=True,
                            text=True,
                            check=False,
                        ).stdout.strip()
                        self.assertTrue(not status or status.startswith("Z"), status)
                    finally:
                        parent_marker = marker.with_suffix(".parent")
                        if parent_marker.exists():
                            try:
                                os.killpg(
                                    int(parent_marker.read_text()), signal.SIGKILL
                                )
                            except ProcessLookupError:
                                pass
                        if child_pid is not None:
                            try:
                                os.kill(child_pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        if process.poll() is None:
                            process.kill()
                        process.communicate(timeout=5)


class GitHubResponseTests(unittest.TestCase):
    def test_closed_unmerged_pr_is_not_evidence(self) -> None:
        pages = json.loads(CAPTURED_RESPONSE)
        pages[0][0]["merged_at"] = None
        self.assertEqual(parse_merged_pull_requests(json.dumps(pages)), ())

    def test_native_paginated_response_preserves_merge_identity(self) -> None:
        pages = json.loads(CAPTURED_RESPONSE)
        pages.insert(0, [])
        (pull,) = parse_merged_pull_requests(json.dumps(pages))
        self.assertEqual(pull.number, 13988)
        self.assertEqual(pull.repository, "KittyCAD/modeling-app")
        self.assertEqual(pull.head, "0a89275399f5381a11e2a944fcd81e9fe78961a6")
        self.assertEqual(pull.merge, "d2f7712388efe52ec89594a4142f52493d8d6cf2")

    def test_invalid_provider_evidence_is_an_error(self) -> None:
        for response in ('{"message":"Bad credentials"}', "[{}]", "not json"):
            with self.subTest(response=response), self.assertRaises(OSError):
                parse_merged_pull_requests(response)

    def test_origin_must_identify_public_github_without_credentials(self) -> None:
        for origin in (
            "git@github.com:KittyCAD/modeling-app.git",
            "ssh://git@github.com/KittyCAD/modeling-app.git",
            "https://github.com/KittyCAD/modeling-app",
        ):
            with self.subTest(origin=origin):
                self.assertEqual(github_repository(origin), "KittyCAD/modeling-app")
        for origin in (
            "/tmp/repository.git",
            "git@github.zoogov.dev:zoo/configs.git",
            "https://github.com.evil.invalid/KittyCAD/modeling-app",
            "https://example-token@github.com/KittyCAD/modeling-app.git",
        ):
            with self.subTest(origin=origin):
                self.assertIsNone(github_repository(origin))


class GitHubMergeEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote.git"
        self.publisher = self.root / "publisher"
        self.checkout = self.root / "checkout"
        self.env = dict(
            os.environ,
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
        )
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.publisher))
        self.configure(self.publisher)
        self.initial = self.commit(self.publisher, "base", "base\n")
        self.git(self.publisher, "push", "origin", "main")
        self.git(self.root, "clone", str(self.remote), str(self.checkout))
        self.configure(self.checkout)
        self.git(self.publisher, "switch", "-c", "feature")
        self.baseline = self.commit(self.publisher, "feature", "first change\n")
        self.git(self.publisher, "tag", "baseline")
        self.published_head = self.commit(self.publisher, "feature", "second change\n")
        self.git(
            self.publisher, "push", "origin", "HEAD:refs/pull/13988/head", "baseline"
        )
        self.git(self.publisher, "switch", "main")
        self.commit(self.publisher, "unrelated", "new upstream work\n")
        self.git(self.publisher, "merge", "--squash", "feature")
        self.git(self.publisher, "commit", "-m", "squash feature")
        self.merged = self.git(self.publisher, "rev-parse", "HEAD")
        self.git(self.publisher, "push", "origin", "main")
        self.git(self.checkout, "fetch", "origin", "main", "tag", "baseline")
        self.git(self.checkout, "switch", "--detach", self.baseline)
        self.pull = replace(
            parse_merged_pull_requests(CAPTURED_RESPONSE)[0],
            head=self.published_head,
            merge=self.merged,
        )

    def git(self, root: Path, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
            timeout=15,
        ).stdout.strip()

    def configure(self, root: Path) -> None:
        for key, value in (
            ("user.name", "Test"),
            ("user.email", "test@example.invalid"),
            ("commit.gpgsign", "false"),
            ("core.hooksPath", "/dev/null"),
        ):
            self.git(root, "config", key, value)

    def commit(self, root: Path, name: str, content: str) -> str:
        (root / name).write_text(content)
        self.git(root, "add", name)
        self.git(root, "commit", "-m", name)
        return self.git(root, "rev-parse", "HEAD")

    def verify(self, head: str | None = None, base: str | None = None) -> str | None:
        return verify_merged_pr(
            self.checkout,
            head or self.baseline,
            base or self.merged,
            "kittycad/modeling-app",
            self.pull,
        )

    def test_squashed_baseline_fetches_published_head_without_changing_checkout(
        self,
    ) -> None:
        with self.assertRaises(subprocess.CalledProcessError):
            self.git(self.checkout, "cat-file", "-e", self.published_head)
        self.assertNotEqual(
            self.git(self.publisher, "rev-parse", "feature^{tree}"),
            self.git(self.publisher, "rev-parse", "main^{tree}"),
        )
        self.assertEqual(self.verify(), self.merged)
        self.assertEqual(self.verify(head=self.published_head), self.merged)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.baseline)
        self.assertEqual(self.git(self.checkout, "status", "--porcelain"), "")

    def test_changed_pr_ref_is_not_substituted_for_published_head(self) -> None:
        self.git(self.publisher, "switch", "feature")
        self.commit(self.publisher, "feature", "later unmerged change\n")
        self.git(self.publisher, "push", "origin", "HEAD:refs/pull/13988/head")
        self.assertIsNone(self.verify())
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), self.baseline)

    def test_new_local_commit_is_not_covered_by_merged_pr(self) -> None:
        local_head = self.commit(self.checkout, "unsent", "keep this work\n")
        self.assertIsNone(self.verify(head=local_head))
        self.assertEqual((self.checkout / "unsent").read_text(), "keep this work\n")

    def test_merge_must_be_reachable_from_fetched_base(self) -> None:
        self.assertIsNone(self.verify(base=self.initial))

    def test_foreign_repository_is_not_merge_evidence(self) -> None:
        self.pull = replace(self.pull, repository="another-owner/modeling-app")
        self.assertIsNone(self.verify())

    def test_missing_pr_ref_reports_transport_failure(self) -> None:
        self.git(self.publisher, "push", "origin", ":refs/pull/13988/head")
        with self.assertRaisesRegex(OSError, "Merged-PR check failed"):
            self.verify()
        self.assertTrue(self.checkout.exists())

    def test_local_and_missing_origins_skip_provider_lookup(self) -> None:
        self.assertIsNone(find_merged_pr(self.checkout, self.baseline, self.merged))
        self.git(self.checkout, "remote", "remove", "origin")
        self.assertIsNone(find_merged_pr(self.checkout, self.baseline, self.merged))


if __name__ == "__main__":
    unittest.main()
