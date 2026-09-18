"""Exercise the executable with real cached files and child processes."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/with-credentials.py"


class CredentialsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / "config"
        (self.config / "with-credentials").mkdir(parents=True)
        self.env = {
            "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.config),
            "PATH": "",
        }
        self.marker = self.root / "started"
        self.cache = self.root / "credential"
        self.cache.write_text("test-only-fixture-value")
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {"cache_file": str(self.cache), "env": ["TEST_CREDENTIAL"]}
                    ]
                }
            }
        )

    def set_profiles(self, profiles: dict) -> None:
        (self.config / "with-credentials/profiles.json").write_text(
            json.dumps(profiles)
        )

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_cached_credentials_reach_child_without_stdout_or_parent_exports(
        self,
    ) -> None:
        child = "import os,pathlib; assert os.environ['TEST_CREDENTIAL'] == 'test-only-fixture-value'; pathlib.Path(os.environ['HOME'],'started').touch()"
        result = self.run_cli("fixture", "--", sys.executable, "-c", child)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertEqual(result.stdout, "")
        self.assertNotIn("test-only-fixture-value", result.stderr)
        self.assertNotIn("TEST_CREDENTIAL", self.env)

    def test_missing_second_credential_never_starts_child(self) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {"cache_file": str(self.cache), "env": ["FIRST"]},
                        {"cache_file": str(self.root / "missing"), "env": ["SECOND"]},
                    ]
                }
            }
        )
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "from pathlib import Path; Path.home().joinpath('started').touch()",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertNotIn("test-only-fixture-value", result.stdout + result.stderr)

    def test_failed_credential_command_never_starts_child(self) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "account": "invalid.example",
                            "item": "fixture",
                            "field": "credential",
                            "env": ["TEST_CREDENTIAL"],
                        }
                    ]
                }
            }
        )
        # An empty PATH proves executable lookup failure without touching a vault.
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "from pathlib import Path; Path.home().joinpath('started').touch()",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertIn("lookup unavailable", result.stderr)

    def test_file_credential_is_private_and_deleted_after_child(self) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {"cache_file": str(self.cache), "file_env": "TEST_FILE"}
                    ]
                }
            }
        )
        child = "import os,pathlib,stat; p=pathlib.Path(os.environ['TEST_FILE']); assert stat.S_IMODE(p.stat().st_mode)==0o600; assert p.read_text()=='test-only-fixture-value'; pathlib.Path.home().joinpath('started').write_text(str(p))"
        result = self.run_cli("fixture", "--", sys.executable, "-c", child)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.marker.read_text()).exists())

    def test_noninteractive_bash_and_zsh_preserve_argv(self) -> None:
        for shell in ("bash", "zsh"):
            executable = shutil.which(shell)
            if executable is None:
                continue
            with self.subTest(shell=shell):
                result = self.run_cli(
                    "fixture",
                    "--",
                    executable,
                    "-c",
                    '[ "$1" = "argument with spaces" ] && [ -n "$TEST_CREDENTIAL" ]',
                    "child",
                    "argument with spaces",
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_child_exit_status_is_preserved(self) -> None:
        result = self.run_cli(
            "fixture", "--", sys.executable, "-c", "raise SystemExit(17)"
        )
        self.assertEqual(result.returncode, 17)

    def test_child_signal_status_is_preserved_after_cleanup(self) -> None:
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "import os,signal; os.kill(os.getpid(), signal.SIGTERM)",
        )
        self.assertEqual(result.returncode, 143)

    def test_doctor_does_not_read_credentials(self) -> None:
        self.cache.unlink()
        result = self.run_cli("--doctor")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["ssh_agent"], "gpgconf_unavailable")
        self.assertNotIn("credential lookup", result.stderr)

    def test_configured_provider_cannot_use_direct_profile(self) -> None:
        (self.config / "switchboard").mkdir()
        (self.config / "switchboard/config.toml").write_text(
            '[namespace.google.work]\nprovider="google"\n'
        )
        self.set_profiles({"fixture": {"provider": "google", "secrets": []}})
        result = self.run_cli(
            "fixture", "--", sys.executable, "-c", "raise SystemExit(0)"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("select its namespace", result.stderr)

    def test_namespace_requires_its_provider_binary(self) -> None:
        (self.config / "switchboard").mkdir()
        (self.config / "switchboard/config.toml").write_text(
            '[namespace.google.work]\nprovider="google"\n'
        )
        result = self.run_cli(
            "google.work", "--", sys.executable, "-c", "raise SystemExit(0)"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot bypass Switchboard", result.stderr)

    def test_switchboard_argv_preserves_read_and_write_intent(self) -> None:
        spec = importlib.util.spec_from_file_location("credential_launcher", SCRIPT)
        self.assertIsNotNone(spec)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(
            module.provider_command(
                "google.work",
                "google",
                ["gws", "gmail", "users", "getProfile", "--params", '{"userId":"me"}'],
                False,
                False,
            ),
            [
                "switchboard",
                "google.cli.read",
                "--ns",
                "google.work",
                "--json",
                "--",
                "gmail",
                "users",
                "getProfile",
                "--params",
                '{"userId":"me"}',
            ],
        )
        self.assertIn(
            "--approve-and-apply",
            module.provider_command(
                "github.personal",
                "github",
                ["gh", "pr", "review", "12", "--approve"],
                False,
                True,
            ),
        )
        self.assertIn(
            "--draft",
            module.provider_command(
                "github.personal",
                "github",
                ["gh", "pr", "review", "12", "--approve"],
                True,
                False,
            ),
        )

    def test_native_result_never_reports_unknown_write_as_success(self) -> None:
        spec = importlib.util.spec_from_file_location("credential_launcher", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        output = '{"status":"error","failure":{"code":"outcome_unknown"}}'
        self.assertEqual(module.native_result(output, 1, False, True).exit_code, 70)
        self.assertEqual(
            module.native_result("truncated", 1, False, True).exit_code, 70
        )
        planned = module.native_result('{"status":"planned"}', 0, False, False)
        self.assertNotEqual(planned.exit_code, 0)
        parsed = module.native_result(
            '{"status":"executed","fields":{"response":{"items":[1]},"cli_stderr":"warning\\n"}}',
            0,
            False,
            False,
        )
        self.assertEqual(json.loads(parsed.stdout), {"items": [1]})
        self.assertEqual(parsed.stderr, "warning\n")

    def test_uncertain_automerge_stops_the_calling_script(self) -> None:
        executable = shutil.which("bash")
        self.assertIsNotNone(executable)
        script = SCRIPT.parent / "kittycad-pr-automerge"
        result = subprocess.run(
            [
                executable,
                "-c",
                'source "$1"; stop_if_uncertain 70; touch "$2"',
                "test",
                str(script),
                str(self.marker),
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertFalse(self.marker.exists())

    def test_ssh_launcher_repairs_socket_with_an_empty_isolated_agent(self) -> None:
        executable = shutil.which("gpgconf")
        if executable is None:
            self.skipTest("gpgconf unavailable")
        directory = self.root / "gnupg"
        directory.mkdir(mode=0o700)
        self.env.update(
            PATH=os.environ["PATH"],
            GNUPGHOME=str(directory),
            SSH_AUTH_SOCK="/nonexistent-agent",
        )
        self.addCleanup(
            lambda: subprocess.run(
                [executable, "--kill", "gpg-agent"],
                env=self.env,
                capture_output=True,
                check=False,
            )
        )
        result = self.run_cli(
            "ssh",
            "--",
            sys.executable,
            "-c",
            "import os,socket; p=os.environ['SSH_AUTH_SOCK']; assert p != '/nonexistent-agent'; s=socket.socket(socket.AF_UNIX); s.connect(p)",
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
