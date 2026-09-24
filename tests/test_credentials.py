"""Exercise the executable with real cached files and child processes."""

import base64
import http.server
import importlib.util
import json
import netrc
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
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

    def run_shell(
        self, shell: str, code: str, *args: str
    ) -> subprocess.CompletedProcess[str]:
        executable = shutil.which(shell)
        if executable is None:
            self.skipTest(f"{shell} unavailable")
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        launcher = directory / "with-credentials"
        launcher.write_text(
            f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(SCRIPT))} "$@"\n'
        )
        launcher.chmod(0o700)
        return subprocess.run(
            [
                executable,
                "-f",
                "-c",
                'source "$1"; shift; function fetch-fixture() { _fetch_credentials fixture "$@"; }; '
                + code,
                "test",
                str(SCRIPT.parent / "credentials.sh"),
                *args,
            ],
            env={**self.env, "PATH": str(directory)},
            text=True,
            capture_output=True,
            check=False,
        )

    def test_shell_exports_quote_values_and_clear_conflicting_overrides(self) -> None:
        value = "test-only 'quotes' \"double\"; $(touch started) `touch started` $HOME\nsecond line"
        self.cache.write_text(value)
        self.set_profiles(
            {
                "fixture": {
                    "unset": ["STALE_CREDENTIAL"],
                    "secrets": [
                        {
                            "cache_file": str(self.cache),
                            "env": ["TEST_CREDENTIAL", "ALIAS"],
                        }
                    ],
                }
            }
        )
        self.env["STALE_CREDENTIAL"] = "old-value"
        exports = self.run_cli("--shell", "fixture")
        self.assertEqual(exports.returncode, 0, exports.stderr)
        for shell in ("bash", "zsh"):
            executable = shutil.which(shell)
            if executable is None:
                continue
            with self.subTest(shell=shell):
                result = subprocess.run(
                    [
                        executable,
                        "-c",
                        'eval "$1"; exec "$2" -c "$3"',
                        "test",
                        exports.stdout,
                        sys.executable,
                        "import os,json; print(json.dumps([os.environ['TEST_CREDENTIAL'],os.environ['ALIAS'],'STALE_CREDENTIAL' in os.environ]))",
                    ],
                    env=self.env,
                    cwd=self.root,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [value, value, False])
                self.assertFalse(self.marker.exists())

    def test_bare_shell_helper_exports_without_trace_leaks_and_preserves_command_mode(
        self,
    ) -> None:
        self.env["OP_BIOMETRIC_UNLOCK_ENABLED"] = "false"
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell):
                result = self.run_shell(
                    shell,
                    "set -x; fetch-fixture || exit $?; case $- in *x*) ;; *) exit 1;; esac; set +x; "
                    '"$1" -c \'import os; assert os.environ["TEST_CREDENTIAL"] == "test-only-fixture-value"\'',
                    sys.executable,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("test-only-fixture-value", result.stderr)
                result = self.run_shell(
                    shell,
                    'fetch-fixture "$1" -c \'import os,sys; assert os.environ["TEST_CREDENTIAL"] == "test-only-fixture-value"; assert sys.argv[1] == "argument with spaces"; raise SystemExit(17)\' "argument with spaces"; '
                    'result=$?; [ -z "${TEST_CREDENTIAL+x}" ] || exit 1; exit "$result"',
                    sys.executable,
                )
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertNotIn(
                    "test-only-fixture-value", result.stdout + result.stderr
                )

    def test_bare_shell_failure_keeps_callers_credentials_and_unsets_unchanged(
        self,
    ) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "unset": ["STALE_CREDENTIAL"],
                    "secrets": [
                        {"cache_file": str(self.cache), "env": ["TEST_CREDENTIAL"]},
                        {"cache_file": str(self.root / "missing"), "env": ["SECOND"]},
                    ],
                }
            }
        )
        self.env.update(TEST_CREDENTIAL="original", STALE_CREDENTIAL="original")
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell):
                result = self.run_shell(
                    shell,
                    "if fetch-fixture; then exit 1; fi; "
                    '[ "$TEST_CREDENTIAL" = original ] && [ "$STALE_CREDENTIAL" = original ] && [ -z "${SECOND+x}" ]',
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("test-only-fixture-value", result.stderr)

    def test_shell_file_remains_private_and_available_after_helper(self) -> None:
        self.cache.write_text('"first line"\n"second line"\n')
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "cache_file": str(self.cache),
                            "file_env": "TEST_FILE",
                            "shell_file": "$XDG_CONFIG_HOME/certificates/ca.crt",
                            "strip_quotes": True,
                        }
                    ]
                }
            }
        )
        result = self.run_shell("bash", 'fetch-fixture && printf "%s" "$TEST_FILE"')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.config / "certificates/ca.crt"
        self.assertEqual(result.stdout, str(path))
        self.assertEqual(path.read_text(), "first line\nsecond line")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_accounts_skip_cached_credentials_and_use_default_config_home(self) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "cache_file": "$XDG_CONFIG_HOME/cached-token",
                            "account": "fixture.example",
                            "item": "fixture",
                            "field": "token",
                            "env": ["TEST_CREDENTIAL"],
                        }
                    ]
                }
            }
        )
        self.config.rename(self.root / ".config")
        self.config = self.root / ".config"
        self.env.pop("XDG_CONFIG_HOME")
        needed = self.run_cli("--accounts", "fixture")
        self.assertEqual(needed.returncode, 0, needed.stderr)
        self.assertEqual(needed.stdout.strip(), "fixture.example")
        (self.config / "cached-token").write_text("cached-fixture")
        cached = self.run_cli("--accounts", "fixture")
        self.assertEqual(cached.returncode, 0, cached.stderr)
        self.assertEqual(cached.stdout.strip(), "")
        result = self.run_cli("--shell", "fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TEST_CREDENTIAL=cached-fixture", result.stdout)

    def test_github_shell_credentials_update_consumers_preserving_other_entries(
        self,
    ) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "github_username": "fixture-user",
                    "secrets": [
                        {"cache_file": str(self.cache), "env": ["GITHUB_TOKEN"]}
                    ],
                }
            }
        )
        netrc_path = self.root / ".netrc"
        nix_path = self.config / "nix/nix.conf"
        netrc_path.write_text(
            "default login fallback-user password fallback-password\n"
        )
        first = self.run_cli("--shell", "fixture")
        self.assertEqual(first.returncode, 0, first.stderr)
        for host in ("github.com", "api.github.com"):
            self.assertEqual(
                netrc.netrc(str(netrc_path)).authenticators(host),
                ("fixture-user", "", self.cache.read_text()),
            )
        netrc_path.write_text(
            netrc_path.read_text()
            + 'machine other.example login "another user" password "other password"\n'
        )
        nix_path.write_text(
            "max-jobs = 2\naccess-tokens = gitlab.com=other github.com=old # keep comment\n"
        )
        self.cache.write_text("replacement-fixture")
        second = self.run_cli("--shell", "fixture")
        self.assertEqual(second.returncode, 0, second.stderr)
        parsed = netrc.netrc(str(netrc_path))
        self.assertEqual(
            parsed.authenticators("github.com"),
            ("fixture-user", "", "replacement-fixture"),
        )
        self.assertEqual(
            parsed.authenticators("other.example"),
            ("another user", "", "other password"),
        )
        self.assertEqual(
            parsed.authenticators("unknown.example"),
            ("fallback-user", "", "fallback-password"),
        )
        self.assertEqual(
            nix_path.read_text(),
            "max-jobs = 2\naccess-tokens = gitlab.com=other github.com=replacement-fixture # keep comment\n",
        )
        for path in (netrc_path, nix_path):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

        curl = shutil.which("curl")
        if curl is None:
            self.skipTest("curl unavailable for netrc consumer check")

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(self.headers.get("Authorization", "").encode())

            def log_message(self, _format: str, *args: object) -> None:
                pass

        with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for host in ("github.com", "api.github.com"):
                    response = subprocess.run(
                        [
                            curl,
                            "--disable",
                            "--silent",
                            "--show-error",
                            "--max-time",
                            "3",
                            "--noproxy",
                            "*",
                            "--netrc-file",
                            str(netrc_path),
                            "--resolve",
                            f"{host}:{server.server_port}:127.0.0.1",
                            f"http://{host}:{server.server_port}/",
                        ],
                        env=self.env,
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=False,
                    )
                    self.assertEqual(response.returncode, 0, response.stderr)
                    expected = base64.b64encode(
                        b"fixture-user:replacement-fixture"
                    ).decode()
                    self.assertEqual(response.stdout, f"Basic {expected}", host)
            finally:
                server.shutdown()
                worker.join()

    def test_shell_rejects_invalid_export_names_without_output(self) -> None:
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "cache_file": str(self.cache),
                            "env": ["TOKEN; touch started"],
                        }
                    ]
                }
            }
        )
        result = self.run_cli("--shell", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("test-only-fixture-value", result.stderr)

    def test_url_credentials_select_the_label_and_reject_ambiguous_results(
        self,
    ) -> None:
        spec = importlib.util.spec_from_file_location("credential_launcher", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        secret = module.Secret.parse(
            {
                "account": "fixture.example",
                "item": "fixture",
                "url_label": "website",
            }
        )
        selected = {"label": "website", "href": "https://fixture.example"}
        self.assertEqual(
            secret.response_value(
                json.dumps(
                    {
                        "urls": [
                            {"label": "admin", "href": "https://admin.example"},
                            selected,
                        ]
                    }
                )
            ),
            "https://fixture.example",
        )
        for urls in ([], [selected, selected]):
            with self.subTest(urls=urls), self.assertRaises(module.CredentialError):
                secret.response_value(json.dumps({"urls": urls}))

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

    def scoped_profile(self) -> Path:
        token_directory = self.config / "agent-credentials"
        token_directory.mkdir(mode=0o700)
        token = token_directory / "fixture.token"
        token.write_text("test-only-bootstrap-token\n")
        token.chmod(0o600)
        (self.config / "with-credentials/auth-profiles.json").write_text(
            json.dumps({"fixture-auth": {"token_file": str(token)}})
        )
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "auth_profile": "fixture-auth",
                            "account": "fixture.example",
                            "vault": "Fixture Vault",
                            "item": "fixture",
                            "field": "credential",
                            "env": ["TEST_CREDENTIAL"],
                        }
                    ]
                }
            }
        )
        directory = self.root / "bin"
        directory.mkdir()
        executable = directory / "op"
        executable.write_text(
            f"#!{sys.executable}\n"
            "import os,pathlib,sys\n"
            "assert sys.argv[1:] == ['item','get','--vault','Fixture Vault','fixture','--fields','credential','--reveal']\n"
            "assert os.environ['OP_SERVICE_ACCOUNT_TOKEN'] == 'test-only-bootstrap-token'\n"
            "assert os.environ['OP_BIOMETRIC_UNLOCK_ENABLED'] == 'false'\n"
            "assert not any(name.startswith('OP_SESSION') for name in os.environ)\n"
            "assert 'OP_CONNECT_TOKEN' not in os.environ\n"
            "assert 'OP_ACCOUNT' not in os.environ\n"
            "pathlib.Path(os.environ['HOME'],'op-called').touch()\n"
            "if os.environ.get('FIXTURE_OP_FAIL'):\n"
            "    print(os.environ['OP_SERVICE_ACCOUNT_TOKEN'], file=sys.stderr)\n"
            "    raise SystemExit(23)\n"
            "print('test-only-provider-value')\n"
        )
        executable.chmod(0o700)
        self.env.update(
            PATH=str(directory),
            OP_SERVICE_ACCOUNT_TOKEN="wrong-inherited-bootstrap",
            OP_SESSION_fixture="wrong-inherited-session",
            OP_CONNECT_TOKEN="wrong-connect-token",
            OP_ACCOUNT="wrong.example",
        )
        return token

    def test_scoped_token_only_reaches_op_and_provider_value_reaches_child(
        self,
    ) -> None:
        self.scoped_profile()
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "import os,pathlib; assert os.environ['TEST_CREDENTIAL']=='test-only-provider-value'; "
            "assert not any(name.startswith('OP_') for name in os.environ); "
            "pathlib.Path.home().joinpath('started').touch()",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertTrue((self.root / "op-called").exists())
        self.assertNotIn("test-only-", result.stdout + result.stderr)
        accounts = self.run_cli("--accounts", "fixture")
        self.assertEqual(accounts.returncode, 0, accounts.stderr)
        self.assertEqual(accounts.stdout.strip(), "")

    def test_missing_or_unsafe_bootstrap_never_invokes_op_or_child(self) -> None:
        token = self.scoped_profile()
        command = "from pathlib import Path; Path.home().joinpath('started').touch()"
        for case in ("permissions", "directory", "symlink", "missing", "empty"):
            with self.subTest(case=case):
                token.unlink(missing_ok=True)
                token.write_text("test-only-bootstrap-token\n")
                token.chmod(0o600)
                token.parent.chmod(0o700)
                if case == "permissions":
                    token.chmod(0o644)
                elif case == "directory":
                    token.parent.chmod(0o755)
                elif case == "symlink":
                    token.unlink()
                    token.symlink_to(self.cache)
                elif case == "missing":
                    token.unlink()
                else:
                    token.write_text("")
                result = self.run_cli("fixture", "--", sys.executable, "-c", command)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "op-called").exists())
                self.assertFalse(self.marker.exists())
                self.assertNotIn("test-only-", result.stdout + result.stderr)

    def test_scoped_lookup_failure_does_not_fall_back_or_expose_stderr(self) -> None:
        self.scoped_profile()
        self.env["FIXTURE_OP_FAIL"] = "1"
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "from pathlib import Path; Path.home().joinpath('started').touch()",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "op-called").exists())
        self.assertFalse(self.marker.exists())
        self.assertIn("exit 23", result.stderr)
        self.assertNotIn("test-only-", result.stdout + result.stderr)

    def test_scoped_profile_rejects_unbound_cache_before_reading_it(self) -> None:
        token = self.scoped_profile()
        path = self.config / "with-credentials/profiles.json"
        profiles = json.loads(path.read_text())
        profiles["fixture"]["secrets"][0]["cache_file"] = str(self.cache)
        self.set_profiles(profiles)
        token.unlink()
        result = self.run_cli("--shell", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("test-only-", result.stdout + result.stderr)

    def test_commit_hook_uses_scoped_resolver_and_missing_token_does_not_block_commit(
        self,
    ) -> None:
        token = self.scoped_profile()
        profile_path = self.config / "with-credentials/profiles.json"
        profiles = json.loads(profile_path.read_text())
        profile = profiles.pop("fixture")
        profile["secrets"][0]["env"] = ["OPENAI_API_KEY"]
        self.set_profiles({"openai": profile})
        git = shutil.which("git")
        self.assertIsNotNone(git)
        (self.root / "bin/git").symlink_to(git)
        launcher = self.root / "bin/with-credentials"
        launcher.write_text(
            f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(SCRIPT))} "$@"\n'
        )
        launcher.chmod(0o700)
        repository = self.root / "repository"
        repository.mkdir()
        subprocess.run(
            [git, "init", "--quiet", str(repository)], env=self.env, check=True
        )
        message = self.root / "commit-message"
        message.write_text("")
        for available in (True, False):
            with self.subTest(available=available):
                (self.root / "op-called").unlink(missing_ok=True)
                if not available:
                    token.unlink()
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT.parent / "prepare-commit-msg.py"),
                        str(message),
                    ],
                    env=self.env,
                    cwd=repository,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.root / "op-called").exists(), available)
                self.assertEqual(message.read_text(), "")
                self.assertNotIn("test-only-", result.stdout + result.stderr)

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
        context = "rerun failed CI jobs for KittyCAD/cli#123 run 456"
        detail = "operation op_unknown has an unknown remote outcome\nrun op verify before retrying"
        for status in (1, 70):
            with self.subTest(status=status):
                self.marker.unlink(missing_ok=True)
                result = subprocess.run(
                    [
                        executable,
                        "-c",
                        'source "$1"; stop_if_uncertain "$3" "$4" "$5"; printf continued > "$2"',
                        "test",
                        str(script),
                        str(self.marker),
                        str(status),
                        context,
                        detail,
                    ],
                    env=self.env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if status == 70:
                    self.assertEqual(result.returncode, 70, result.stderr)
                    self.assertFalse(self.marker.exists())
                    self.assertIn(context, result.stderr)
                    self.assertIn(detail, result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(self.marker.exists())
                    self.assertEqual(result.stderr, "")

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
