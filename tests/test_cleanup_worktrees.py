"""Run the real global sweep against disposable linked repositories."""

import importlib.util
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path

import test_git_cleanup

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cleanup-worktrees.py"
SPEC = importlib.util.spec_from_file_location("cleanup_worktrees", SCRIPT)
SWEEP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SWEEP)


@unittest.skipUnless(shutil.which("lsof"), "lsof is required to inspect worktree use")
class SweepTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = test_git_cleanup.CleanupTests()
        self.repo.setUp()
        self.addCleanup(self.repo.doCleanups)
        self.repo.merge()
        self.env = {**self.repo.env, "XDG_STATE_HOME": str(self.repo.root / "state")}

    def run_sweep(self, *args: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.repo.root), *args],
            cwd=self.repo.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def another_checkout(self, branch: str) -> Path:
        path = self.repo.root / branch
        self.repo.git(self.repo.primary, "worktree", "add", "-b", branch, str(path))
        return path

    def test_sweep_removes_merged_checkout_but_keeps_unmerged_and_primary(self) -> None:
        container = self.repo.root / "finished"
        container.mkdir()
        destination = container / "repo"
        self.repo.git(
            self.repo.primary,
            "worktree",
            "move",
            str(self.repo.target),
            str(destination),
        )
        self.repo.target = destination
        (container / ".codex-worktree-name").touch()
        cache = self.repo.add_build_cache()
        self.repo.merge()
        unmerged = self.another_checkout("pending")
        (unmerged / "pending").write_text("unmerged work")
        self.repo.git(unmerged, "add", "pending")
        self.repo.git(unmerged, "commit", "-m", "not merged")
        result = self.run_sweep()
        self.assertFalse(self.repo.target.exists(), result.stdout)
        self.assertFalse(container.exists(), result.stdout)
        self.assertFalse(cache.exists())
        self.assertEqual((unmerged / "pending").read_text(), "unmerged work")
        self.assertTrue(self.repo.primary.exists())
        self.assertIn("Removed 1 worktrees; skipped 1", result.stdout)
        plans = list((self.repo.root / "state/cleanup").glob("*/*.plan.json"))
        self.assertEqual(len(plans), 1)
        self.assertFalse(json.loads(plans[0].read_text())["force"])
        rerun = self.run_sweep()
        self.assertIn("Removed 0 worktrees", rerun.stdout)

    def test_busy_checkout_is_skipped_while_other_merged_checkout_is_removed(
        self,
    ) -> None:
        busy = self.another_checkout("busy")
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; print('ready', flush=True); sys.stdin.read()",
            ],
            cwd=busy,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            result = self.run_sweep()
            self.assertTrue(busy.exists(), result.stdout)
            self.assertFalse(self.repo.target.exists(), result.stdout)
            self.assertIn("in use by", result.stdout)
        finally:
            process.communicate(timeout=10)

    def test_reviewed_preview_rechecks_changes_and_continues_other_plans(self) -> None:
        other = self.another_checkout("another")
        preview = self.run_sweep("--dry-run")
        self.assertTrue(self.repo.target.exists(), preview.stdout)
        self.assertTrue(other.exists())
        receipt_dirs = list((self.repo.root / "state/cleanup").iterdir())
        self.assertEqual(len(receipt_dirs), 1)
        (self.repo.target / "unsaved").write_text("keep this")
        result = self.run_sweep("--execute", str(receipt_dirs[0]))
        self.assertEqual((self.repo.target / "unsaved").read_text(), "keep this")
        self.assertFalse(other.exists(), result.stdout)
        self.assertIn("Removed 1 worktrees; skipped 1", result.stdout)

    def test_symlink_container_never_selects_an_external_worktree(self) -> None:
        outside = self.repo.root / "outside"
        self.repo.target.rename(outside)
        self.repo.git(self.repo.primary, "worktree", "repair", str(outside))
        containers = self.repo.root / "containers"
        containers.mkdir()
        (containers / "linked").symlink_to(outside, target_is_directory=True)
        result = self.run_sweep("--root", str(containers))
        self.assertTrue(outside.exists(), result.stdout)
        self.assertIn("Removed 0 worktrees", result.stdout)

    @unittest.skipIf(os.getuid() == 0, "root can traverse unreadable directories")
    def test_unreadable_container_does_not_prevent_other_cleanup(self) -> None:
        unreadable = self.repo.root / "aaa-unreadable"
        unreadable.mkdir()
        unreadable.chmod(0)
        try:
            result = self.run_sweep()
            self.assertFalse(self.repo.target.exists(), result.stdout)
            self.assertIn(f"SKIP {unreadable}", result.stdout)
            self.assertIn("Removed 1 worktrees; skipped 1", result.stdout)
        finally:
            unreadable.chmod(0o700)

    def test_registered_consumer_outside_root_preserves_shared_output_donor(
        self,
    ) -> None:
        consumer = self.repo.root / "outside/nested/consumer"
        self.repo.git(
            self.repo.primary, "worktree", "add", "-b", "consumer", str(consumer)
        )
        binding = consumer / "rust/kcl-lib/bindings"
        binding.parent.mkdir(parents=True)
        binding.symlink_to(self.repo.target / "file")
        disposable = self.another_checkout("disposable")
        result = self.run_sweep()
        self.assertTrue(self.repo.target.exists(), result.stdout)
        self.assertEqual(binding.read_text(), "changed\n")
        self.assertFalse(disposable.exists(), result.stdout)
        self.assertIn(
            f"referenced by symlink {binding.parent.resolve() / binding.name}",
            result.stdout,
        )
        self.assertIn("Removed 1 worktrees; skipped 1", result.stdout)

    def test_execute_rechecks_scoped_npm_link_inside_primary_cache(self) -> None:
        preview = self.run_sweep("--dry-run")
        self.assertTrue(self.repo.target.exists(), preview.stdout)
        receipt_dir = next((self.repo.root / "state/cleanup").iterdir())
        link = self.repo.primary / "node_modules/@workspace/local-package"
        link.parent.mkdir(parents=True)
        link.symlink_to(self.repo.target, target_is_directory=True)
        # --execute retains the preview root even when it is not specified again.
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--execute", str(receipt_dir)],
            cwd=self.repo.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.repo.target.exists(), result.stdout)
        self.assertTrue((link / "file").exists())
        self.assertIn(
            f"referenced by symlink {link.parent.resolve() / link.name}", result.stdout
        )

    def test_timeout_stops_git_transport_descendants(self) -> None:
        transport_pid = self.repo.root / "transport.pid"
        transport = self.repo.root / "slow-upload-pack"
        transport.write_text(
            "#!/bin/sh\n"
            "trap '' TERM\n"
            f"printf '%s\\n' \"$$\" > {shlex.quote(str(transport_pid))}\n"
            "exec sleep 60\n"
        )
        transport.chmod(0o755)
        self.repo.git(
            self.repo.primary,
            "config",
            "remote.origin.uploadpack",
            shlex.quote(str(transport)),
        )
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                SWEEP.invoke(self.repo.target, "--plan", timeout=2)
            self.assertTrue(transport_pid.exists(), "Git did not start its transport")
            pid = int(transport_pid.read_text())
            deadline = time.monotonic() + 5
            while True:
                status = subprocess.run(
                    ["ps", "-p", str(pid), "-o", "stat="],
                    capture_output=True,
                    text=True,
                    check=False,
                ).stdout.strip()
                if not status or status.startswith("Z") or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            self.assertFalse(status and not status.startswith("Z"), status)
        finally:
            if transport_pid.exists():
                try:
                    os.kill(int(transport_pid.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_dirty_checkout_skips_remote_contact(self) -> None:
        contacted = self.repo.root / "remote-contacted"
        transport = self.repo.root / "record-upload-pack"
        transport.write_text(
            "#!/bin/sh\n"
            f"touch {shlex.quote(str(contacted))}\n"
            'exec git-upload-pack "$@"\n'
        )
        transport.chmod(0o755)
        self.repo.git(
            self.repo.primary,
            "config",
            "remote.origin.uploadpack",
            shlex.quote(str(transport)),
        )
        unsaved = self.repo.target / "unsaved"
        unsaved.write_text("keep this")
        result = self.run_sweep()
        self.assertEqual(unsaved.read_text(), "keep this")
        self.assertFalse(contacted.exists(), result.stdout)
        self.assertIn("tracked or untracked changes", result.stdout)

    def test_cleanup_keeps_primary_branch_and_files_unchanged(self) -> None:
        self.repo.git(self.repo.primary, "switch", "-c", "ongoing")
        source = self.repo.primary / "ongoing"
        source.write_text("another task's source")
        self.repo.git(self.repo.primary, "add", "ongoing")
        self.repo.git(self.repo.primary, "commit", "-m", "ongoing work")
        head = self.repo.git(self.repo.primary, "rev-parse", "HEAD")
        result = self.run_sweep()
        self.assertFalse(self.repo.target.exists(), result.stdout)
        self.assertEqual(
            self.repo.git(self.repo.primary, "branch", "--show-current"), "ongoing"
        )
        self.assertEqual(self.repo.git(self.repo.primary, "rev-parse", "HEAD"), head)
        self.assertEqual(source.read_text(), "another task's source")


if __name__ == "__main__":
    unittest.main()
