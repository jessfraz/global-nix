"""Real repository regressions for destructive cleanup boundaries."""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(
    os.environ.get(
        "GIT_CLEANUP_SCRIPT",
        Path(__file__).resolve().parents[1] / "scripts/git-cleanup",
    )
)

# Frozen from 6b6c80a^: existing shells can retain this receipt-consuming function.
LEGACY_GCLEANUP = r"""
function gcleanup() {
    local receipt primary argument
    for argument in "$@"; do
        case "$argument" in
            -h|--help) git cleanup "$@"; return $? ;;
        esac
    done
    receipt=$(git cleanup "$@") || return $?
    printf '%s\n' "$receipt"
    primary=$(printf '%s' "$receipt" | python3 -c 'import json,sys; result=json.load(sys.stdin); print(result["primary_worktree"] if result.get("status") == "completed" and result.get("worktree_removed") else "")') || return $?
    if [ -n "$primary" ]; then
        cd "$primary" || return $?
    fi
}
"""


class CleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.primary = self.root / "primary"
        self.remote = self.root / "remote.git"
        self.target = self.root / "feature space"
        self.env = dict(
            os.environ,
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_ALLOW_PROTOCOL="file",
            GIT_TERMINAL_PROMPT="0",
        )
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.primary))
        self.git(self.primary, "config", "user.name", "Test")
        self.git(self.primary, "config", "user.email", "test@example.invalid")
        self.git(self.primary, "config", "commit.gpgsign", "false")
        self.git(self.primary, "config", "core.hooksPath", "/dev/null")
        (self.primary / "file").write_text("original\n")
        (self.primary / ".gitignore").write_text("ignored\n")
        self.git(self.primary, "add", ".")
        self.git(self.primary, "commit", "-m", "base")
        self.git(self.primary, "push", "origin", "main")
        self.git(self.primary, "remote", "set-head", "origin", "main")
        self.git(self.primary, "worktree", "add", "-b", "feature", str(self.target))
        (self.target / "file").write_text("changed\n")
        self.git(self.target, "commit", "-am", "feature")

    def git(self, root: Path, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            env=self.env,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

    def run_cleanup(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=self.target,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def run_legacy_gcleanup(
        self, shell: str = "bash"
    ) -> subprocess.CompletedProcess[str]:
        self.git(
            self.primary, "config", "alias.cleanup", f"!{shlex.quote(str(SCRIPT))}"
        )
        startup = ["--noprofile", "--norc"] if shell == "bash" else ["-f"]
        return subprocess.run(
            [
                shell,
                *startup,
                "-c",
                LEGACY_GCLEANUP
                + '\ngcleanup\ncleanup_status=$?\npwd -P > "$1"\nexit "$cleanup_status"\n',
                "legacy-gcleanup",
                str(self.root / "shell-cwd"),
            ],
            cwd=self.target,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def merge(self, squash: bool = False) -> None:
        self.git(
            self.primary, "merge", "--squash" if squash else "--ff-only", "feature"
        )
        if squash:
            self.git(self.primary, "commit", "-m", "squashed")
        self.git(self.primary, "push", "origin", "main")

    def plan(self, *args: str) -> Path:
        result = self.run_cleanup("--plan", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root / "plan.json"
        path.write_text(result.stdout)
        return path

    def use_primary_checkout(self) -> None:
        self.git(self.target, "switch", "--detach")
        self.git(self.primary, "switch", "feature")
        self.target = self.primary

    def advance_remote(self, filename: str = "upstream-only") -> str:
        checkout = self.root / "remote update"
        self.git(self.root, "clone", str(self.remote), str(checkout))
        self.git(checkout, "config", "user.name", "Test")
        self.git(checkout, "config", "user.email", "test@example.invalid")
        (checkout / filename).write_text("remote update\n")
        self.git(checkout, "add", "--force", filename)
        self.git(checkout, "commit", "-m", "remote update")
        self.git(checkout, "push", "origin", "main")
        return self.git(checkout, "rev-parse", "HEAD")

    def test_untracked_file_survives_cleanup(self) -> None:
        self.merge()
        marker = self.target / "unsaved"
        marker.write_text("irreplaceable")
        result = self.run_cleanup()
        self.assertTrue(marker.exists(), result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_merged_detached_worktree_cleanup_preserves_branches(self) -> None:
        self.merge()
        self.git(self.target, "switch", "--detach")
        branches = self.git(self.primary, "show-ref", "--heads")
        plan = self.plan()
        self.assertIsNone(json.loads(plan.read_text())["branch"])
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git(self.primary, "show-ref", "--heads"), branches)
        receipt = json.loads(result.stdout)
        self.assertTrue(receipt["worktree_removed"])
        self.assertIsNone(receipt["branch_deleted"])
        self.assertNotIn("Branch deleted", receipt["summary"])

    def test_unmerged_detached_worktree_is_preserved(self) -> None:
        self.git(self.target, "switch", "--detach")
        head = self.git(self.target, "rev-parse", "HEAD")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not merged or squash-equivalent", result.stderr)
        self.assertTrue(self.target.exists())
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), head)
        self.assertEqual((self.target / "file").read_text(), "changed\n")

    def test_detached_primary_checkout_is_preserved(self) -> None:
        self.merge()
        self.git(self.primary, "switch", "--detach")
        self.target = self.primary
        head = self.git(self.target, "rev-parse", "HEAD")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("detached primary", result.stderr.lower())
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "")

    def test_detached_plan_refuses_new_branch_attachment(self) -> None:
        self.merge()
        self.git(self.target, "switch", "--detach")
        plan = self.plan()
        self.git(self.target, "switch", "feature")
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("evidence changed", result.stderr.lower())
        self.assertTrue(self.target.exists())
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")

    def test_legacy_gcleanup_preserves_primary_ignored_files(self) -> None:
        self.merge()
        self.use_primary_checkout()
        marker = self.primary / "ignored"
        marker.write_text("local")
        result = self.run_legacy_gcleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("JSONDecodeError", result.stderr)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.primary, "branch", "--show-current"), "main")
        self.assertNotIn("refs/heads/feature", self.git(self.primary, "show-ref"))
        self.assertEqual(
            (self.root / "shell-cwd").read_text().strip(), str(self.primary.resolve())
        )

    def test_legacy_gcleanup_relocates_shell_after_worktree_removal(self) -> None:
        self.merge()
        result = self.run_legacy_gcleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("JSONDecodeError", result.stderr)
        self.assertFalse(self.target.exists())
        self.assertNotIn("refs/heads/feature", self.git(self.primary, "show-ref"))
        self.assertEqual(
            (self.root / "shell-cwd").read_text().strip(), str(self.primary.resolve())
        )

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_legacy_gcleanup_relocates_zsh_after_worktree_removal(self) -> None:
        self.merge()
        result = self.run_legacy_gcleanup("zsh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("JSONDecodeError", result.stderr)
        self.assertFalse(self.target.exists())
        self.assertNotIn("refs/heads/feature", self.git(self.primary, "show-ref"))
        self.assertEqual(
            (self.root / "shell-cwd").read_text().strip(), str(self.primary.resolve())
        )

    def test_legacy_gcleanup_preserves_dirty_worktree_and_shell_directory(self) -> None:
        self.merge()
        marker = self.target / "unsaved"
        marker.write_text("local")
        result = self.run_legacy_gcleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("JSONDecodeError", result.stderr)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")
        self.assertEqual(
            (self.root / "shell-cwd").read_text().strip(), str(self.target.resolve())
        )

    def test_terminal_cleanup_prints_readable_completion(self) -> None:
        self.merge()
        self.git(
            self.primary, "config", "alias.cleanup", f"!{shlex.quote(str(SCRIPT))}"
        )
        master, slave = os.openpty()
        try:
            with os.fdopen(slave, "w") as terminal:
                result = subprocess.run(
                    ["git", "cleanup"],
                    cwd=self.target,
                    env=self.env,
                    text=True,
                    stdout=terminal,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                os.set_blocking(master, False)
                output = os.read(master, 65536).decode()
        finally:
            os.close(master)
        self.assertTrue(output.startswith("Cleanup complete:"), output)
        self.assertFalse(self.target.exists())
        self.assertNotIn("refs/heads/feature", self.git(self.primary, "show-ref"))

    def test_fetch_failure_preserves_worktree(self) -> None:
        self.merge()
        self.git(
            self.primary, "remote", "set-url", "origin", str(self.root / "missing")
        )
        result = self.run_cleanup()
        self.assertTrue(self.target.exists(), result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_cleanup_fetches_only_base_despite_conflicting_configured_tags(
        self,
    ) -> None:
        self.merge()
        original = self.git(self.primary, "rev-parse", "HEAD")
        self.git(self.primary, "tag", "conflicting-release", original)
        self.git(self.primary, "update-ref", "refs/remotes/origin/unrelated", original)
        latest = self.advance_remote()
        self.git(self.remote, "tag", "conflicting-release", latest)
        self.git(self.remote, "branch", "unrelated", latest)
        self.git(self.primary, "config", "remote.origin.tagOpt", "--tags")
        self.git(
            self.primary,
            "config",
            "--add",
            "remote.origin.fetch",
            "refs/tags/*:refs/tags/*",
        )
        self.git(self.primary, "config", "fetch.prune", "true")
        self.git(self.primary, "config", "fetch.pruneTags", "true")
        plan = self.plan()
        self.assertEqual(json.loads(plan.read_text())["base_head"], latest)
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git(self.primary, "rev-parse", "origin/main"), latest)
        self.assertEqual(
            self.git(self.primary, "rev-parse", "refs/tags/conflicting-release"),
            original,
        )
        self.assertEqual(
            self.git(self.primary, "rev-parse", "refs/remotes/origin/unrelated"),
            original,
        )

    def test_missing_remote_branch_is_not_merge_evidence(self) -> None:
        self.git(self.target, "push", "-u", "origin", "feature")
        self.git(self.primary, "push", "origin", "--delete", "feature")
        result = self.run_cleanup()
        self.assertTrue(self.target.exists(), result.stderr)
        self.assertEqual(
            self.git(self.primary, "rev-parse", "feature"),
            self.git(self.target, "rev-parse", "HEAD"),
        )
        self.assertNotEqual(result.returncode, 0)

    def test_plan_then_execute_merged_worktree(self) -> None:
        self.merge()
        plan = self.plan()
        self.assertTrue(self.target.exists())
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")
        self.assertEqual(json.loads(plan.read_text())["evidence"], "ancestor")
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertNotIn("refs/heads/feature", self.git(self.primary, "show-ref"))

    def test_default_cleanup_removes_merged_worktree_and_branch(self) -> None:
        self.merge()
        latest = self.advance_remote()
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertNotIn("refs/heads/feature", self.git(self.primary, "show-ref"))
        self.assertEqual(self.git(self.primary, "rev-parse", "HEAD"), latest)
        self.assertEqual(
            (self.primary / "upstream-only").read_text(), "remote update\n"
        )

    def test_previous_plan_format_remains_executable(self) -> None:
        self.merge()
        path = self.plan()
        plan = json.loads(path.read_text())
        plan["version"] = 1
        del plan["build_directories"]
        del plan["build_symlinks"]
        del plan["build_bytes"]
        path.write_text(json.dumps(plan))
        result = self.run_cleanup("--execute", str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())

    def test_version_two_plan_remains_executable(self) -> None:
        self.merge()
        path = self.plan()
        plan = json.loads(path.read_text())
        plan["version"] = 2
        del plan["build_symlinks"]
        path.write_text(json.dumps(plan))
        result = self.run_cleanup("--execute", str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())

    def add_build_cache(self) -> Path:
        (self.target / "Cargo.toml").write_text('[package]\nname = "fixture"\n')
        (self.target / ".gitignore").write_text("ignored\ntarget/\n")
        self.git(self.target, "add", "Cargo.toml", ".gitignore")
        self.git(self.target, "commit", "-m", "build configuration")
        cache = self.target / "target"
        cache.mkdir()
        (cache / "artifact").write_bytes(b"rebuildable" * 1024)
        return cache

    def test_merged_worktree_cleanup_reclaims_ignored_build_cache(self) -> None:
        cache = self.add_build_cache()
        self.merge()
        plan = self.plan()
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertFalse(cache.exists())
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["build_directories_removed"], [str(cache.resolve())])
        self.assertGreater(receipt["build_bytes_estimate"], 0)

    def add_nested_build_caches(self) -> list[Path]:
        project = self.target / "dashboard/app"
        project.mkdir(parents=True)
        (project / "package.json").write_text('{"name":"fixture"}\n')
        (project / ".gitignore").write_text("node_modules/\ndist/\n.next/\n")
        self.git(self.target, "add", "dashboard/app")
        self.git(self.target, "commit", "-m", "nested package configuration")
        caches = [project / "node_modules", project / "dist", project / ".next"]
        for cache in caches:
            cache.mkdir()
            (cache / "artifact").write_text("rebuildable")
        return caches

    def test_nested_package_build_caches_are_removed_with_merged_worktree(self) -> None:
        caches = self.add_nested_build_caches()
        self.merge()
        plan = self.plan()
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        receipt = json.loads(result.stdout)
        self.assertEqual(
            receipt["build_directories_removed"],
            sorted(str(cache.resolve()) for cache in caches),
        )
        self.assertEqual(
            (self.primary / "dashboard/app/package.json").read_text(),
            '{"name":"fixture"}\n',
        )

    def test_merged_checkout_removes_generated_links_without_their_destinations(
        self,
    ) -> None:
        self.add_nested_build_caches()
        cache = self.target / "dashboard/app/node_modules"
        shared = self.root / "shared-dependencies"
        cache.rename(shared)
        cache.symlink_to(shared, target_is_directory=True)
        (self.target / "dashboard/app/.gitignore").write_text(
            "node_modules\ndist/\n.next/\n.vite/\nplaywright-report/\ntest-results/\n"
        )
        self.git(self.target, "commit", "-am", "ignore generated test output")
        for name in (".vite", "playwright-report", "test-results"):
            generated = self.target / "dashboard/app" / name
            generated.mkdir()
            (generated / "output").write_text("regenerable")
        self.merge()
        plan = self.plan()
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertEqual((shared / "artifact").read_text(), "rebuildable")
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["build_symlinks_removed"], [str(cache.resolve())])

    def test_nested_repository_build_caches_are_preserved(self) -> None:
        caches = self.add_nested_build_caches()
        self.merge()
        self.git(self.target, "init", "dashboard/app")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        for cache in caches:
            self.assertEqual((cache / "artifact").read_text(), "rebuildable")

    def test_build_cache_does_not_allow_neighboring_ignored_data_to_be_deleted(
        self,
    ) -> None:
        cache = self.add_build_cache()
        self.merge()
        (self.target / "ignored").write_text("local credentials")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((cache / "artifact").exists())
        self.assertEqual((self.target / "ignored").read_text(), "local credentials")

    def test_primary_checkout_keeps_its_build_cache(self) -> None:
        self.add_build_cache()
        self.merge()
        self.target = self.primary
        cache = self.primary / "target"
        cache.mkdir()
        (cache / "artifact").write_text("keep")
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((cache / "artifact").read_text(), "keep")

    def test_build_cache_symlink_replacement_preserves_destination(self) -> None:
        cache = self.add_build_cache()
        self.merge()
        plan = self.plan()
        outside = self.root / "outside"
        cache.rename(outside)
        cache.symlink_to(outside, target_is_directory=True)
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((outside / "artifact").exists())
        self.assertTrue(self.target.exists())

    def test_mixed_tracked_and_ignored_build_directory_is_preserved(self) -> None:
        cache = self.add_build_cache()
        self.git(self.target, "add", "--force", "target/artifact")
        self.git(self.target, "commit", "-m", "tracked artifact")
        self.merge()
        (cache / "other-build-output").write_text("ignored build")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((cache / "artifact").exists())

    def test_nested_bare_repository_is_preserved(self) -> None:
        cache = self.add_build_cache()
        self.merge()
        nested = cache / "local-history.git"
        self.git(self.root, "init", "--bare", str(nested))
        self.git(self.target, "push", str(nested), "HEAD:refs/heads/saved")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(nested.exists())
        self.assertEqual(
            self.git(nested, "rev-parse", "saved"),
            self.git(self.target, "rev-parse", "HEAD"),
        )

    @unittest.skipUnless(shutil.which("lsof"), "lsof is not installed")
    def test_busy_build_cache_skips_checkout_without_failing(self) -> None:
        cache = self.add_build_cache()
        self.merge()
        with subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; f=open(sys.argv[1]); print('ready', flush=True); sys.stdin.read()",
                str(cache / "artifact"),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as reader:
            self.assertEqual(reader.stdout.readline().strip(), "ready")
            try:
                result = self.run_cleanup()
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(result.stdout)
                self.assertEqual(receipt["status"], "skipped")
                self.assertIn("is using build cache", receipt["summary"])
                self.assertTrue((cache / "artifact").exists())
            finally:
                reader.communicate(timeout=10)
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())

    def test_cleanup_already_on_base_updates_to_remote(self) -> None:
        self.merge()
        latest = self.advance_remote()
        self.target = self.primary
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.primary, "rev-parse", "HEAD"), latest)
        self.assertEqual(self.git(self.primary, "branch", "--show-current"), "main")
        self.assertEqual(
            (self.primary / "upstream-only").read_text(), "remote update\n"
        )

    def test_linked_cleanup_preserves_dirty_primary(self) -> None:
        self.merge()
        self.advance_remote()
        previous = self.git(self.primary, "rev-parse", "HEAD")
        (self.primary / "file").write_text("unsaved primary work")
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.git(self.primary, "rev-parse", "HEAD"), previous)
        self.assertEqual((self.primary / "file").read_text(), "unsaved primary work")

    def test_no_gc_keeps_unreachable_object_until_default_cleanup(self) -> None:
        self.merge()
        self.git(self.primary, "config", "gc.auto", "0")
        self.git(self.primary, "config", "gc.pruneExpire", "now")
        blob = self.root / "unreachable"
        blob.write_text("unreferenced content")
        object_id = self.git(self.primary, "hash-object", "-w", str(blob))
        os.utime(
            self.primary / ".git" / "objects" / object_id[:2] / object_id[2:],
            (1, 1),
        )
        result = self.run_cleanup("--no-gc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.git(self.primary, "cat-file", "-p", object_id),
            "unreferenced content",
        )
        self.target = self.primary
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.assertRaises(subprocess.CalledProcessError):
            self.git(self.primary, "cat-file", "-e", object_id)

    def test_plan_and_execute_cannot_be_combined(self) -> None:
        self.merge()
        plan = self.plan()
        result = self.run_cleanup("--plan", "--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.exists())
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")

    def test_squash_proof_survives_unrelated_later_commit(self) -> None:
        self.merge(squash=True)
        (self.primary / "unrelated").write_text("later")
        self.git(self.primary, "add", "unrelated")
        self.git(self.primary, "commit", "-m", "later")
        self.git(self.primary, "push", "origin", "main")
        plan = self.plan()
        self.assertEqual(
            json.loads(plan.read_text())["evidence"], "squash-patch-and-content"
        )
        self.assertEqual(self.run_cleanup("--execute", str(plan)).returncode, 0)

    def test_stale_head_rejects_execution(self) -> None:
        self.merge()
        plan = self.plan()
        self.git(self.target, "commit", "--allow-empty", "-m", "new work")
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.exists())

    def test_stale_base_rejects_execution(self) -> None:
        self.merge()
        plan = self.plan()
        self.git(self.primary, "commit", "--allow-empty", "-m", "base advanced")
        self.git(self.primary, "push", "origin", "main")
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.exists())

    def test_force_never_discards_ignored_files(self) -> None:
        marker = self.target / "ignored"
        marker.write_text("local")
        result = self.run_cleanup("--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")
        self.assertIn("!! ignored", result.stderr)

    def test_ignored_file_created_after_plan_preserves_linked_worktree(self) -> None:
        self.merge()
        plan = self.plan()
        marker = self.target / "ignored"
        marker.write_text("local")
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")

    def test_default_primary_cleanup_preserves_ignored_files(self) -> None:
        self.merge()
        self.use_primary_checkout()
        marker = self.target / "ignored"
        marker.write_text("local")
        result = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "main")
        self.assertNotIn("refs/heads/feature", self.git(self.target, "show-ref"))

    def test_primary_cleanup_updates_base_and_preserves_new_ignored_file(self) -> None:
        self.merge()
        latest = self.advance_remote()
        self.use_primary_checkout()
        plan = self.plan()
        self.assertNotEqual(self.git(self.primary, "rev-parse", "main"), latest)
        marker = self.target / "ignored"
        marker.write_text("local")
        result = self.run_cleanup("--execute", str(plan))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "main")
        self.assertNotIn("refs/heads/feature", self.git(self.target, "show-ref"))
        self.assertEqual(self.git(self.primary, "rev-parse", "HEAD"), latest)
        self.assertEqual(
            (self.primary / "upstream-only").read_text(), "remote update\n"
        )

    def test_primary_cleanup_preserves_feature_when_base_diverged(self) -> None:
        self.merge()
        self.advance_remote()
        self.git(self.primary, "commit", "--allow-empty", "-m", "local base work")
        local_base = self.git(self.primary, "rev-parse", "HEAD")
        self.use_primary_checkout()
        feature = self.git(self.primary, "rev-parse", "feature")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.primary, "rev-parse", "feature"), feature)
        self.assertEqual(self.git(self.primary, "rev-parse", "main"), local_base)

    def test_primary_cleanup_refuses_to_overwrite_ignored_file(self) -> None:
        self.merge()
        (self.primary / "ignored").write_text("upstream")
        self.git(self.primary, "add", "--force", "ignored")
        self.git(self.primary, "commit", "-m", "track formerly ignored file")
        self.git(self.primary, "push", "origin", "main")
        self.use_primary_checkout()
        marker = self.target / "ignored"
        marker.write_text("local")
        plan = self.plan()
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")

    def test_primary_update_refuses_to_overwrite_ignored_file(self) -> None:
        self.merge()
        self.advance_remote("ignored")
        self.use_primary_checkout()
        feature = self.git(self.primary, "rev-parse", "feature")
        marker = self.target / "ignored"
        marker.write_text("local")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.primary, "rev-parse", "feature"), feature)

    def test_primary_cleanup_preserves_submodule_replaced_by_base_file(self) -> None:
        submodule = self.root / "submodule"
        self.git(self.root, "clone", str(self.remote), str(submodule))
        self.git(self.target, "submodule", "add", str(submodule), "sub")
        self.git(self.target, "commit", "-am", "submodule")
        self.merge()
        self.git(self.primary, "rm", "sub")
        (self.primary / "sub").write_text("replacement")
        self.git(self.primary, "add", "sub")
        self.git(self.primary, "commit", "-am", "replace submodule on main")
        self.git(self.primary, "push", "origin", "main")
        self.use_primary_checkout()
        self.git(self.target, "submodule", "update", "--init")
        self.git(self.target, "config", "submodule.recurse", "true")
        plan = self.plan()
        marker = self.target / "sub" / "ignored"
        marker.write_text("local")
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "local")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")

    def test_explicit_force_plan_requires_explicit_force_execution(self) -> None:
        plan = self.plan("--force")
        self.assertNotEqual(self.run_cleanup("--execute", str(plan)).returncode, 0)
        result = self.run_cleanup("--execute", str(plan), "--force")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_locked_worktree_is_preserved(self) -> None:
        self.merge()
        plan = self.plan()
        self.git(self.primary, "worktree", "lock", str(self.target))
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.exists())

    def test_symlinked_submodule_storage_is_preserved(self) -> None:
        submodule = self.root / "submodule"
        self.git(self.root, "clone", str(self.remote), str(submodule))
        self.git(self.target, "submodule", "add", str(submodule), "sub")
        self.git(self.target, "commit", "-am", "submodule")
        self.merge()
        git_dir = Path(self.git(self.target, "rev-parse", "--absolute-git-dir"))
        storage = git_dir / "modules"
        relocated = git_dir / "relocated-modules"
        storage.rename(relocated)
        storage.symlink_to(relocated, target_is_directory=True)
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(relocated.is_dir())
        self.assertTrue(self.target.exists())
        self.assertIn("symlink", result.stderr)

    def test_populated_submodule_is_checked_before_removal(self) -> None:
        submodule = self.root / "submodule"
        self.git(self.root, "clone", str(self.remote), str(submodule))
        self.git(self.target, "submodule", "add", str(submodule), "sub")
        self.git(self.target, "commit", "-am", "submodule")
        self.merge()
        marker = self.target / "sub" / "ignored"
        marker.write_text("local")
        result = self.run_cleanup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sub\n!! ignored", result.stderr)
        self.assertTrue(marker.exists())
        marker.unlink()
        plan = self.plan()
        marker.write_text("created after planning")
        result = self.run_cleanup("--execute", str(plan))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "created after planning")
        self.assertEqual(self.git(self.target, "branch", "--show-current"), "feature")
        marker.unlink()
        self.git(self.target / "sub", "config", "user.name", "Test")
        self.git(self.target / "sub", "config", "user.email", "test@example.invalid")
        original = self.git(self.target / "sub", "rev-parse", "HEAD")
        self.git(self.target / "sub", "switch", "-c", "unique-local-work")
        self.git(self.target / "sub", "commit", "--allow-empty", "-m", "only local")
        unique = self.git(self.target / "sub", "rev-parse", "HEAD")
        self.git(self.target / "sub", "checkout", "--detach", original)
        plan = self.plan()
        result = self.run_cleanup("--execute", str(plan), "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())
        archive = Path(json.loads(result.stdout)["retained_submodules"])
        self.assertEqual(
            self.git(
                self.primary,
                "--git-dir",
                str(archive / "modules/sub"),
                "--work-tree",
                str(self.primary),
                "rev-parse",
                "unique-local-work",
            ),
            unique,
        )
        self.assertEqual(
            self.git(
                self.primary,
                "--git-dir",
                str(archive / "modules/sub"),
                "--work-tree",
                str(self.primary),
                "cat-file",
                "-t",
                unique,
            ),
            "commit",
        )


if __name__ == "__main__":
    unittest.main()
