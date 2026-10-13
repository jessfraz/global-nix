"""Exercise pin generation and locking with disposable files and external CLIs."""

import base64
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PIN_FILES = (
    "flake.nix",
    "flake.lock",
    "pkgs/codex.nix",
    "pkgs/kicad-bin.nix",
    "pkgs/mole.nix",
    "pkgs/orca-slicer-bin.nix",
    "pkgs/ramp-cli.nix",
)

# Only the network/process boundary is substituted. The real updater reads and
# writes the repository fixtures, and the lock consumer records the pins it saw.
FAKE_CLI = r"""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([tool, *args]) + "\n")

if tool == "gh":
    repository = args[1].removeprefix("repos/").removesuffix("/releases/latest")
    tags = {
        "openai/codex": os.environ.get("CODEX_TAG", "rust-v99.1.0"),
        "KiCad/kicad-source-mirror": "99.1.0",
        "OrcaSlicer/OrcaSlicer": "v99.1.0",
    }
    print(json.dumps({"tag_name": tags[repository]}))
elif tool == "git":
    print("0" * 40 + "\trefs/tags/v99.1.0")
elif args[:2] == ["store", "prefetch-file"]:
    if os.environ.get("FAIL_FETCH") and os.environ["FAIL_FETCH"] in args[-1]:
        print("fixture download failed", file=sys.stderr)
        sys.exit(1)
    digest = base64.b64encode(hashlib.sha256(args[-1].encode()).digest()).decode()
    print(json.dumps({"hash": "sha256-" + digest}))
elif args[:2] == ["flake", "update"]:
    inputs = args[2:args.index("--option")]
    pins = {
        str(path.relative_to(root)): path.read_text()
        for path in [root / "flake.nix", *sorted((root / "pkgs").glob("*.nix"))]
    }
    (root / "flake.lock").write_text(json.dumps({"inputs": inputs, "pins": pins}))
    if os.environ.get("FAIL_LOCK"):
        print("fixture lock resolution failed", file=sys.stderr)
        sys.exit(1)
elif args[0] == "build":
    with (root / "vendor-checks.jsonl").open("a") as log:
        log.write(json.dumps({
            "rebuild": "--rebuild" in args,
            "lock": json.loads((root / "flake.lock").read_text()),
        }) + "\n")
    if os.environ.get("FAIL_VENDOR") and "--rebuild" in args:
        print("fixture vendor reproducibility failure", file=sys.stderr)
        sys.exit(1)
elif args[0] == "eval":
    print("99.1.0")
else:
    raise SystemExit(f"unexpected fixture command: {tool} {args}")
"""


class UpdatePinsTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for relative in (*PIN_FILES, "scripts/update-pins.py"):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, destination)
        # Existing user edits must survive every failed update byte for byte.
        for relative in PIN_FILES:
            path = self.root / relative
            if path.suffix == ".nix":
                with path.open("a") as file:
                    file.write("\n# existing local edit\n")
        self.original = {
            relative: (self.root / relative).read_bytes() for relative in PIN_FILES
        }
        (self.root / "unrelated.txt").write_text("untouched\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("gh", "git", "nix"):
            command = self.bin / name
            command.write_text(f"#!{sys.executable}\n{FAKE_CLI}")
            command.chmod(0o755)

    def run_update(self, *targets: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.root / "scripts/update-pins.py"), *targets],
            cwd=self.root,
            env={
                "PATH": str(self.bin),
                "HOME": str(self.root),
                "GH_TOKEN": "fixture-token",
                **env,
            },
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def commands(self) -> list[list[str]]:
        return [
            json.loads(line)
            for line in (self.root / "commands.jsonl").read_text().splitlines()
        ]

    def lock(self) -> dict:
        return json.loads((self.root / "flake.lock").read_text())

    def assert_restored(self) -> None:
        self.assertEqual(
            {relative: (self.root / relative).read_bytes() for relative in PIN_FILES},
            self.original,
        )
        self.assertEqual((self.root / "unrelated.txt").read_text(), "untouched\n")

    def test_all_locks_once_after_generating_every_pin(self) -> None:
        result = self.run_update("all")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        updates = [
            command for command in commands if command[:3] == ["nix", "flake", "update"]
        ]
        self.assertEqual(
            updates, [["nix", "flake", "update", "--option", "warn-dirty", "false"]]
        )
        lock = self.lock()
        self.assertEqual(lock["inputs"], [])
        self.assertIn("github:openai/codex/rust-v99.1.0", lock["pins"]["flake.nix"])
        for relative in PIN_FILES:
            if relative.startswith("pkgs/") and relative != "pkgs/codex.nix":
                self.assertRegex(lock["pins"][relative], r'version = "99\.1\.0";')
        for target in ("aarch64-apple-darwin", "x86_64-unknown-linux-musl"):
            url = f"https://github.com/openai/codex/releases/download/rust-v99.1.0/codex-package-{target}.tar.gz"
            expected = (
                "sha256-"
                + base64.b64encode(hashlib.sha256(url.encode()).digest()).decode()
            )
            self.assertIn(expected, lock["pins"]["pkgs/codex.nix"])
        vendor_checks = [
            json.loads(line)
            for line in (self.root / "vendor-checks.jsonl").read_text().splitlines()
        ]
        self.assertEqual(
            vendor_checks,
            [{"rebuild": False, "lock": lock}, {"rebuild": True, "lock": lock}],
        )
        self.assertIn("--rebuild", commands[-1])

    def test_zoo_refreshes_its_shared_toolchain_in_one_lock(self) -> None:
        result = self.run_update("zoo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lock()["inputs"], ["zoo-cli", "rust-overlay"])
        self.assertEqual(len(self.commands()), 3)
        for relative in PIN_FILES:
            if relative != "flake.lock":
                self.assertEqual(
                    (self.root / relative).read_bytes(), self.original[relative]
                )

    def test_combined_codex_and_zoo_lock_the_requested_inputs_once(self) -> None:
        result = self.run_update("zoo", "codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lock()["inputs"], ["codex", "zoo-cli", "rust-overlay"])
        updates = [
            command
            for command in self.commands()
            if command[:3] == ["nix", "flake", "update"]
        ]
        self.assertEqual(len(updates), 1)

    def test_unchanged_codex_does_not_relock_other_inputs(self) -> None:
        match = re.search(
            r'github:openai/codex/([^"\s]+)', (self.root / "flake.nix").read_text()
        )
        self.assertIsNotNone(match)
        result = self.run_update("codex", CODEX_TAG=match.group(1))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.commands()), 1)
        self.assert_restored()

    def test_failed_final_lock_restores_all_pins_and_existing_edits(self) -> None:
        result = self.run_update("all", FAIL_LOCK="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("fixture lock resolution failed", result.stderr)
        self.assert_restored()

    def test_later_pin_failure_restores_earlier_updates(self) -> None:
        result = self.run_update("all", FAIL_FETCH="tw93/Mole")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_restored()

    def test_vendor_rebuild_failure_restores_all_pins_and_lock(self) -> None:
        result = self.run_update("all", FAIL_VENDOR="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("fixture vendor reproducibility failure", result.stderr)
        self.assert_restored()

    def test_second_codex_platform_failure_keeps_original_archives_and_lock(
        self,
    ) -> None:
        result = self.run_update("codex", FAIL_FETCH="x86_64-unknown-linux-musl")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_restored()


if __name__ == "__main__":
    unittest.main()
