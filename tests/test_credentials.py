"""Exercise the executable with real cached files and child processes."""

import base64
import concurrent.futures
import http.server
import importlib.util
import json
import netrc
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request
from pathlib import Path
from unittest.mock import patch

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

    def install_switchboard(self, config: str = "") -> Path:
        trusted = self.config / "switchboard/config.toml"
        trusted.parent.mkdir(exist_ok=True)
        trusted.write_text(config)
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        executable = directory / "switchboard"
        # This disposable CLI reads the selected config and implements the public
        # discovery/native envelopes. It never calls a provider or credential store.
        executable.write_text(
            f"#!{sys.executable}\n"
            + r"""
import json, os, pathlib, sys, tomllib
root = pathlib.Path(os.environ["HOME"])
args = sys.argv[1:]
with (root / "switchboard-calls").open("a") as log:
    log.write(json.dumps({"argv": args, "op_env": any(k.startswith("OP_") for k in os.environ)}) + "\n")
if args[:1] == ["--config"]:
    path = pathlib.Path(args[1])
    args = args[2:]
else:
    path = pathlib.Path(os.environ.get("SWITCHBOARD_CONFIG", "switchboard.toml"))
settings_path = root / "discovery-settings"
settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
if args == ["ns", "list", "--json"]:
    if "stdout" in settings:
        sys.stdout.write(settings["stdout"])
        sys.stderr.write(settings.get("stderr", ""))
        sys.exit(settings.get("exit", 0))
    try:
        config = tomllib.loads(path.read_text())
        namespaces = [
            {"id": f"{group}.{name}", "provider": ns["provider"]}
            for group, accounts in config.get("namespace", {}).items()
            for name, ns in accounts.items()
        ]
    except Exception:
        print("unsafe-config-diagnostic", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"schema_version": 1, "namespaces": namespaces}))
else:
    print(json.dumps({"status": "executed", "fields": {"response": {"config": str(path), "argv": args}}}))
"""
        )
        executable.chmod(0o700)
        self.env["PATH"] = str(directory)
        return trusted

    def switchboard_calls(self) -> list[dict]:
        path = self.root / "switchboard-calls"
        return [json.loads(line) for line in path.read_text().splitlines()]

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

    def batched_profile(self, selections: list[dict]) -> None:
        self.scoped_profile()
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "auth_profile": "fixture-auth",
                            "account": "fixture.example",
                            "vault": "Fixture Vault",
                            "item": "fixture",
                            **selection,
                        }
                        for selection in selections
                    ]
                }
            }
        )
        (self.root / "bin/op").write_text(
            f"#!{sys.executable}\n"
            "import json,os,pathlib,sys\n"
            "args = sys.argv[1:]\n"
            "token = os.environ.get('OP_SERVICE_ACCOUNT_TOKEN')\n"
            "scope = {None: 'desktop', 'test-only-bootstrap-token': 'primary', "
            "'test-only-second-bootstrap': 'secondary'}[token]\n"
            "if token:\n"
            "    assert os.environ['OP_BIOMETRIC_UNLOCK_ENABLED'] == 'false'\n"
            "    assert 'OP_ACCOUNT' not in os.environ\n"
            "    assert not any(key.startswith('OP_SESSION') for key in os.environ)\n"
            "assert 'OP_CONNECT_TOKEN' not in os.environ\n"
            "with pathlib.Path(os.environ['HOME'],'op-calls.jsonl').open('a') as log:\n"
            "    log.write(json.dumps({'args': args, 'scope': scope}) + '\\n')\n"
            "if 'FIXTURE_RESPONSE' in os.environ:\n"
            "    print(os.environ['FIXTURE_RESPONSE'])\n"
            "elif '--fields' not in args:\n"
            "    assert args[-2:] == ['--format', 'json']\n"
            "    print(json.dumps({'urls': [{'label': 'website', 'href': 'https://fixture.example'}]}))\n"
            "else:\n"
            "    selectors = args[args.index('--fields') + 1].split(',')\n"
            "    fields = []\n"
            "    for selector in selectors:\n"
            "        name = selector.removeprefix('label=')\n"
            "        fields.append({'id': name if name.endswith('-id') else 'generated-' + name, "
            "'label': 'id-selected label' if name.endswith('-id') else name, "
            "'value': 'test-only-provider-' + scope + '-' + name})\n"
            "    if '--format' in args:\n"
            "        assert args[args.index('--format') + 1] == 'json'\n"
            "        print(json.dumps(list(reversed(fields))))\n"
            "    else:\n"
            "        assert len(fields) == 1\n"
            "        print(fields[0]['value'])\n"
        )

    def lookup_calls(self) -> list[dict]:
        return [
            json.loads(line)
            for line in (self.root / "op-calls.jsonl").read_text().splitlines()
        ]

    def run_credential_child(
        self, expected: dict[str, str]
    ) -> subprocess.CompletedProcess[str]:
        return self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "import json,os,pathlib,sys; "
            "assert all(os.environ[key] == value for key,value in json.loads(sys.argv[1]).items()); "
            "assert not any(key.startswith('OP_') for key in os.environ); "
            "pathlib.Path.home().joinpath('started').touch()",
            json.dumps(expected),
        )

    def test_selected_fields_share_one_lookup_only_within_each_invocation(
        self,
    ) -> None:
        self.batched_profile(
            [
                {"field": "first-id", "env": ["FIRST"]},
                {"field": "label=second key", "env": ["SECOND"]},
                {"field": "third key", "env": ["THIRD"]},
            ]
        )
        for call_count in (1, 2):
            result = self.run_credential_child(
                {
                    "FIRST": "test-only-provider-primary-first-id",
                    "SECOND": "test-only-provider-primary-second key",
                    "THIRD": "test-only-provider-primary-third key",
                }
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.marker.exists())
            self.assertNotIn("test-only-", result.stdout + result.stderr)
            calls = self.lookup_calls()
            self.assertEqual(len(calls), call_count)
            self.assertEqual(
                calls[-1]["args"],
                [
                    "item",
                    "get",
                    "--vault",
                    "Fixture Vault",
                    "fixture",
                    "--fields",
                    "first-id,label=second key,third key",
                    "--format",
                    "json",
                    "--reveal",
                ],
            )
        self.assertFalse((self.config / "with-credentials/files").exists())

    def test_duplicate_field_uses_one_single_field_lookup(self) -> None:
        self.batched_profile(
            [
                {"field": "first-id", "env": ["FIRST"]},
                {"field": "first-id", "env": ["SECOND"]},
            ]
        )
        result = self.run_credential_child(
            dict.fromkeys(("FIRST", "SECOND"), "test-only-provider-primary-first-id")
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.lookup_calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["args"][-3:], ["--fields", "first-id", "--reveal"])

    def test_field_batches_keep_item_vault_account_and_auth_profile_separate(
        self,
    ) -> None:
        variants = [
            {},
            {"item": "second-item"},
            {"vault": "Second Vault"},
            {"account": "second.example"},
            {"auth_profile": "second-auth"},
            {"auth_profile": None},
        ]
        self.batched_profile(
            [
                {"field": field, "env": [f"VALUE_{index}_{part}"], **variant}
                for index, variant in enumerate(variants)
                for part, field in enumerate(("first-id", "second key"))
            ]
        )
        token = self.config / "agent-credentials/second.token"
        token.write_text("test-only-second-bootstrap\n")
        token.chmod(0o600)
        auth_path = self.config / "with-credentials/auth-profiles.json"
        auth = json.loads(auth_path.read_text())
        auth["second-auth"] = {"token_file": str(token)}
        auth_path.write_text(json.dumps(auth))
        expected = {}
        for index, variant in enumerate(variants):
            scope = {"second-auth": "secondary", None: "desktop"}.get(
                variant.get("auth_profile", "fixture-auth"), "primary"
            )
            for part, field in enumerate(("first-id", "second key")):
                expected[f"VALUE_{index}_{part}"] = (
                    f"test-only-provider-{scope}-{field}"
                )
        result = self.run_credential_child(expected)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.lookup_calls()
        self.assertEqual(len(calls), len(variants))
        self.assertEqual(
            [call["scope"] for call in calls],
            ["primary", "primary", "primary", "primary", "secondary", "desktop"],
        )
        self.assertEqual(calls[-1]["args"][:2], ["--account", "fixture.example"])

    def test_url_selection_stays_separate_from_selected_field_lookup(self) -> None:
        self.batched_profile(
            [
                {"url_label": "website", "env": ["URL"]},
                {"field": "first-id", "env": ["FIRST"]},
            ]
        )
        result = self.run_credential_child(
            {
                "URL": "https://fixture.example",
                "FIRST": "test-only-provider-primary-first-id",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.lookup_calls()
        self.assertEqual(len(calls), 2)
        self.assertNotIn("--fields", calls[0]["args"])
        self.assertEqual(calls[1]["args"][-3:], ["--fields", "first-id", "--reveal"])

    def test_bad_selected_field_response_never_starts_child_or_prints_values(
        self,
    ) -> None:
        self.batched_profile(
            [
                {"field": "first-id", "env": ["FIRST"]},
                {"field": "second key", "env": ["SECOND"]},
                {"item": "later-item", "field": "third", "env": ["THIRD"]},
            ]
        )
        first = {"id": "first-id", "value": "test-only-response-value"}
        second = {"label": "second key", "value": "test-only-second-value"}
        responses = [
            "test-only-invalid-json",
            json.dumps({"fields": [first, second]}),
            json.dumps([first]),
            json.dumps([first, first, second]),
            json.dumps([first, {**second, "value": None}]),
            json.dumps([first, {**second, "value": ""}]),
            json.dumps([first, {**second, "value": "test-only-\u0000"}]),
        ]
        for count, response in enumerate(responses, start=1):
            with self.subTest(response=count):
                self.env["FIXTURE_RESPONSE"] = response
                result = self.run_credential_child({})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker.exists())
                self.assertEqual(result.stdout, "")
                self.assertNotIn("test-only-", result.stderr)
                self.assertEqual(len(self.lookup_calls()), count)

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

    def slack_profile(self) -> Path:
        cache = self.root / ".slack/read-auth/credential.json"
        cache.parent.mkdir(parents=True, mode=0o700)
        cache.write_text(
            json.dumps(
                {
                    "access_token": "test-only-current-access",
                    "refresh_token": "test-only-current-refresh",
                    "client_id": "test-only-client",
                    "client_secret": "test-only-client-secret",
                    "expires_at": None,
                    "scopes": ["identify", "groups:history", "search:read"],
                    "team_id": "TEXAMPLE",
                    "user_id": "UEXAMPLE",
                }
            )
        )
        cache.chmod(0o600)
        self.set_profiles(
            {
                "slack.work": {
                    "provider": "slack",
                    "slack_oauth": {
                        "cache_file": str(cache),
                        "team_id": "TEXAMPLE",
                        "user_id": "UEXAMPLE",
                        "read_only": True,
                    },
                }
            }
        )
        return cache

    def test_slack_oauth_profile_uses_current_cache_not_environment(self) -> None:
        self.slack_profile()
        self.env.update(
            {
                "SLACK_BOT_TOKEN": "test-only-broad",
                "SLACK_USER_TOKEN": "test-only-stale",
                "SLACK_API_HOST": "invalid",
                "OP_SERVICE_ACCOUNT_TOKEN": "test-only-bootstrap",
            }
        )
        result = self.run_cli(
            "slack.work",
            "--",
            sys.executable,
            "-c",
            "import os; assert os.environ['SLACK_USER_TOKEN']=='test-only-current-access'; assert [k for k in os.environ if k.startswith('SLACK_')]==['SLACK_USER_TOKEN']; assert not any(k.startswith('OP_') for k in os.environ); print('native output')",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "native output\n")
        self.assertEqual(result.stderr, "")

    def test_slack_oauth_permission_policy_is_profile_data(self) -> None:
        cache = self.slack_profile()
        credential = json.loads(cache.read_text())
        credential["scopes"] = ["chat:write"]
        cache.write_text(json.dumps(credential))
        path = self.config / "with-credentials/profiles.json"
        profile = json.loads(path.read_text())["slack.work"]
        for policy in (True, False, None, "false"):
            with self.subTest(policy=policy):
                profile["slack_oauth"]["read_only"] = policy
                self.set_profiles({"slack.fixture": profile})
                result = self.run_cli(
                    "slack.fixture",
                    "--",
                    sys.executable,
                    "-c",
                    "import os; assert os.environ['SLACK_USER_TOKEN']=='test-only-current-access'",
                )
                self.assertEqual(result.returncode == 0, policy is False, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("test-only-", result.stderr)

    def test_slack_oauth_never_exports_or_falls_back(self) -> None:
        cache = self.slack_profile()
        for mode in ("--shell", "--accounts"):
            result = self.run_cli(mode, "slack.work")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("child-only", result.stderr)
        cache.unlink()
        result = self.run_cli(
            "slack.work", "--", sys.executable, "-c", "raise SystemExit(0)"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("test-only-", result.stderr)

    def test_slack_oauth_rejects_bad_identity_scopes_and_expiry(self) -> None:
        cache = self.slack_profile()
        original = json.loads(cache.read_text())
        for key, value in (
            ("team_id", "OTHER"),
            ("user_id", "OTHER"),
            ("scopes", ["chat:write"]),
            ("scopes", []),
            ("expires_at", True),
            ("expires_at", float("nan")),
            ("refresh_token", 12),
        ):
            with self.subTest(key=key, value=value):
                cache.write_text(json.dumps({**original, key: value}))
                result = self.run_cli(
                    "slack.work", "--", sys.executable, "-c", "raise SystemExit(0)"
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("test-only-", result.stderr)

    def test_slack_oauth_rejects_insecure_cache_paths(self) -> None:
        cache = self.slack_profile()
        for path, bad_mode, good_mode in (
            (cache, 0o640, 0o600),
            (cache.parent, 0o750, 0o700),
        ):
            path.chmod(bad_mode)
            result = self.run_cli(
                "slack.work", "--", sys.executable, "-c", "raise SystemExit(0)"
            )
            self.assertNotEqual(result.returncode, 0)
            path.chmod(good_mode)
        for path in (cache, cache.parent / ".refresh.lock", cache.parent):
            with self.subTest(path=path.name):
                target = path.with_name(path.name + "-real")
                path.rename(target)
                path.symlink_to(target)
                try:
                    result = self.run_cli(
                        "slack.work", "--", sys.executable, "-c", "raise SystemExit(0)"
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                finally:
                    path.unlink()
                    target.rename(path)

    def test_slack_refresh_serializes_single_use_token_and_replaces_atomically(
        self,
    ) -> None:
        cache = self.slack_profile()
        original = json.loads(cache.read_text())
        cache.write_text(json.dumps({**original, "expires_at": 1}))
        spec = importlib.util.spec_from_file_location(
            "slack_credentials_fixture", SCRIPT
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        auth = module.SlackOAuth(str(cache), "TEXAMPLE", "UEXAMPLE", True)
        requests = []
        refresh_started, release_refresh = threading.Event(), threading.Event()
        payload = {
            "ok": True,
            "team": {"id": "TEXAMPLE"},
            "authed_user": {
                "id": "UEXAMPLE",
                "token_type": "user",
                "access_token": "test-only-new-access",
                "refresh_token": "test-only-new-refresh",
                "expires_in": 3600,
                "scope": "groups:history,search:read",
            },
        }

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                requests.append(
                    urllib.parse.parse_qs(
                        self.rfile.read(int(self.headers["Content-Length"])).decode()
                    )
                )
                refresh_started.set()
                release_refresh.wait(timeout=5)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def log_message(self, _format: str, *args: object) -> None:
                pass

        real_urlopen = urllib.request.urlopen

        def local_request(request: urllib.request.Request, timeout: float):
            self.assertEqual(request.full_url, "https://slack.com/api/oauth.v2.access")
            return real_urlopen(
                f"http://127.0.0.1:{server.server_port}/",
                data=request.data,
                timeout=timeout,
            )

        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                before_inode = cache.stat().st_ino
                # Readers holding the old descriptor still see a complete old file.
                with (
                    cache.open() as old,
                    patch.object(module.urllib.request, "urlopen", local_request),
                    concurrent.futures.ThreadPoolExecutor(max_workers=1) as readers,
                ):
                    owner = readers.submit(auth.token)
                    try:
                        self.assertTrue(refresh_started.wait(timeout=2))
                        before = cache.read_bytes()
                        real_open = module.os.open
                        with (
                            patch.object(module.os, "open", wraps=real_open) as opened,
                            self.assertRaisesRegex(
                                module.CredentialError, "already in progress"
                            ),
                        ):
                            auth.token()
                        self.assertEqual(
                            [call.args[0] for call in opened.call_args_list],
                            [cache.parent, ".refresh.lock"],
                        )
                        self.assertEqual(len(requests), 1)
                        self.assertEqual(cache.read_bytes(), before)
                    finally:
                        release_refresh.set()
                    self.assertEqual(owner.result(timeout=2), "test-only-new-access")
                    self.assertEqual(auth.token(), "test-only-new-access")
                    self.assertEqual(
                        json.load(old)["access_token"], original["access_token"]
                    )
                self.assertNotEqual(cache.stat().st_ino, before_inode)
                self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
                self.assertEqual(cache.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(
                    json.loads(cache.read_text())["refresh_token"],
                    "test-only-new-refresh",
                )
                self.assertEqual(len(requests), 1)
                self.assertEqual(
                    requests[0],
                    {
                        "grant_type": ["refresh_token"],
                        "refresh_token": [original["refresh_token"]],
                        "client_id": [original["client_id"]],
                        "client_secret": [original["client_secret"]],
                    },
                )
                self.assertEqual(
                    sorted(p.name for p in cache.parent.iterdir()),
                    [".refresh.lock", "credential.json"],
                )
                # Invalid refresh responses must never replace the valid cache.
                for replacement in (
                    {"ok": False, "error": "test-only-private"},
                    {**payload, "team": {"id": "OTHER"}},
                    {
                        **payload,
                        "authed_user": {
                            **payload["authed_user"],
                            "scope": "chat:write",
                        },
                    },
                    {
                        **payload,
                        "authed_user": {
                            **payload["authed_user"],
                            "refresh_token": None,
                        },
                    },
                ):
                    payload = replacement
                    cache.write_text(json.dumps({**original, "expires_at": 1}))
                    before = cache.read_bytes()
                    with (
                        patch.object(module.urllib.request, "urlopen", local_request),
                        self.assertRaises(module.CredentialError),
                    ):
                        auth.token()
                    self.assertEqual(cache.read_bytes(), before)
                with (
                    patch.object(module.os, "getuid", return_value=os.getuid() + 1),
                    self.assertRaisesRegex(module.CredentialError, "owned"),
                ):
                    auth.token()
            finally:
                server.shutdown()
                worker.join()

    def test_slack_refresh_failure_does_not_change_cache_or_leak_diagnostics(
        self,
    ) -> None:
        cache = self.slack_profile()
        original = json.loads(cache.read_text())
        cache.write_text(json.dumps({**original, "expires_at": 1}))
        spec = importlib.util.spec_from_file_location("slack_failure_fixture", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        auth = module.SlackOAuth(str(cache), "TEXAMPLE", "UEXAMPLE", True)
        before = cache.read_bytes()
        with (
            patch.object(
                module.urllib.request,
                "urlopen",
                side_effect=OSError("test-only-private"),
            ),
            self.assertRaises(module.CredentialError) as error,
        ):
            auth.token()
        self.assertNotIn("test-only-", str(error.exception))
        self.assertEqual(cache.read_bytes(), before)
        cache.write_text(
            json.dumps({**original, "expires_at": 1, "refresh_token": None})
        )
        with self.assertRaisesRegex(module.CredentialError, "expired"):
            auth.token()

    def test_cancelled_child_group_is_killed_and_reaped(self) -> None:
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum):
                self.marker.unlink(missing_ok=True)
                code = "import os,pathlib,subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); pathlib.Path.home().joinpath('started').write_text(str(os.getpid())); time.sleep(60)"
                with subprocess.Popen(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "fixture",
                        "--",
                        sys.executable,
                        "-c",
                        code,
                    ],
                    env=self.env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                ) as process:
                    try:
                        deadline = time.monotonic() + 5
                        while not self.marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(self.marker.exists())
                        child_pid = int(self.marker.read_text())
                        process.send_signal(signum)
                        stdout, stderr = process.communicate(timeout=5)
                        self.assertEqual(process.returncode, 128 + signum)
                        self.assertEqual(stdout, "")
                        self.assertNotIn("test-only-", stderr)
                        for _ in range(100):
                            try:
                                os.killpg(child_pid, 0)
                            except ProcessLookupError:
                                break
                            time.sleep(0.01)
                        else:
                            self.fail(
                                "credential-bearing child group survived cancellation"
                            )
                    finally:
                        if process.poll() is None:
                            process.kill()
                        if self.marker.exists():
                            try:
                                os.killpg(int(self.marker.read_text()), signal.SIGKILL)
                            except ProcessLookupError:
                                pass

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
        self.install_switchboard('[namespace.google.work]\nprovider="google"\n')
        self.set_profiles({"fixture": {"provider": "google", "secrets": []}})
        result = self.run_cli(
            "fixture", "--", sys.executable, "-c", "raise SystemExit(0)"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("select its namespace", result.stderr)

    def test_namespace_requires_its_provider_binary(self) -> None:
        self.install_switchboard('[namespace.google.work]\nprovider="google"\n')
        result = self.run_cli(
            "google.work", "--", sys.executable, "-c", "raise SystemExit(0)"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot bypass Switchboard", result.stderr)

    def test_discovery_and_dispatch_share_trusted_config_despite_overrides(
        self,
    ) -> None:
        trusted = self.install_switchboard(
            '[namespace.google.work]\nprovider="google"\n'
        )
        override = self.root / "override.toml"
        override.write_text('[namespace.google.other]\nprovider="google"\n')
        (self.root / "switchboard.toml").write_text(override.read_text())
        self.env.update(
            SWITCHBOARD_CONFIG=str(override),
            OP_SERVICE_ACCOUNT_TOKEN="must-not-inherit",
        )
        for flags, tool, intent in (
            ([], "google.cli.read", []),
            (["--draft"], "google.cli.write", ["--draft"]),
            (["--apply"], "google.cli.write", ["--approve-and-apply"]),
        ):
            with self.subTest(flags=flags):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        *flags,
                        "google.work",
                        "--",
                        "gws",
                        "gmail",
                        "argument with spaces",
                    ],
                    env=self.env,
                    cwd=self.root,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                response = (
                    payload["fields"]["response"] if flags == ["--draft"] else payload
                )
                self.assertEqual(
                    response,
                    {
                        "config": str(trusted),
                        "argv": [
                            tool,
                            "--ns",
                            "google.work",
                            "--json",
                            *intent,
                            "--",
                            "gmail",
                            "argument with spaces",
                        ],
                    },
                )
        calls = self.switchboard_calls()
        self.assertEqual(len(calls), 6)
        for discovery, dispatch in zip(calls[::2], calls[1::2], strict=True):
            self.assertEqual(
                discovery["argv"], ["--config", str(trusted), "ns", "list", "--json"]
            )
            self.assertEqual(dispatch["argv"][:2], ["--config", str(trusted)])
            self.assertFalse(discovery["op_env"])
            self.assertFalse(dispatch["op_env"])

    def test_discovery_uses_default_home_config(self) -> None:
        self.install_switchboard('[namespace.google.work]\nprovider="google"\n')
        self.config.rename(self.root / ".config")
        self.env.pop("XDG_CONFIG_HOME")
        result = self.run_cli("google.work", "--", "gws", "gmail")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout)["config"],
            str(self.root / ".config/switchboard/config.toml"),
        )

    def test_relative_config_home_is_not_cwd_authority(self) -> None:
        self.env["XDG_CONFIG_HOME"] = "relative-config"
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            f"open({str(self.marker)!r}, 'w').close()",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute path", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_valid_empty_discovery_allows_unconfigured_cached_profile(self) -> None:
        self.install_switchboard()
        result = self.run_cli(
            "fixture",
            "--",
            sys.executable,
            "-c",
            "import os; assert os.environ['TEST_CREDENTIAL'] == 'test-only-fixture-value'",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.switchboard_calls()), 1)

    def test_discovery_failures_are_safe_and_never_fall_back(self) -> None:
        self.install_switchboard()
        # A credential lookup, a direct consumer, or a second Switchboard call
        # would all leave evidence. No live credentials/providers are involved.
        op = self.root / "bin/op"
        op.write_text(
            f"#!{sys.executable}\nfrom pathlib import Path\nPath({str(self.marker)!r}).touch()\n"
        )
        op.chmod(0o700)
        self.set_profiles(
            {
                "fixture": {
                    "secrets": [
                        {
                            "account": "fixture.example",
                            "item": "fixture",
                            "field": "token",
                            "env": ["TEST_CREDENTIAL"],
                        }
                    ]
                }
            }
        )
        cases = [
            {
                "stdout": "unsafe-json-diagnostic",
                "stderr": "unsafe-stderr-diagnostic",
                "exit": 1,
            },
            {"stdout": "unsafe-json-diagnostic"},
            {"stdout": json.dumps({"schema_version": 2, "namespaces": []})},
            {"stdout": json.dumps({"schema_version": True, "namespaces": []})},
            {"stdout": json.dumps({"schema_version": 1})},
            {"stdout": json.dumps({"schema_version": 1, "namespaces": {}})},
            {
                "stdout": json.dumps(
                    {"schema_version": 1, "namespaces": ["unsafe-entry-diagnostic"]}
                )
            },
            {
                "stdout": json.dumps(
                    {
                        "schema_version": 1,
                        "namespaces": [{"id": "google.work", "provider": None}],
                    }
                )
            },
            {
                "stdout": json.dumps(
                    {
                        "schema_version": 1,
                        "namespaces": [{"id": "google.work", "provider": "google"}] * 2,
                    }
                )
            },
            {"stdout": "\udcff"},
        ]
        for settings in cases:
            (self.root / "discovery-settings").write_text(json.dumps(settings))
            for arguments in (
                (
                    "fixture",
                    "--",
                    sys.executable,
                    "-c",
                    f"open({str(self.marker)!r}, 'w').close()",
                ),
                ("google.work", "--", "gws", "gmail"),
                ("--shell", "fixture"),
            ):
                with self.subTest(settings=settings, arguments=arguments[:1]):
                    (self.root / "switchboard-calls").unlink(missing_ok=True)
                    result = self.run_cli(*arguments)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("discovery", result.stderr)
                    self.assertNotIn("unsafe-", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertFalse(self.marker.exists())
                    self.assertEqual(len(self.switchboard_calls()), 1)

    def test_missing_binary_and_broken_config_are_not_unconfigured(self) -> None:
        trusted = self.install_switchboard()
        executable = self.root / "bin/switchboard"
        for failure in (
            "missing-binary",
            "invalid-config",
            "dangling-config",
            "directory-config",
        ):
            with self.subTest(failure=failure):
                if failure == "missing-binary":
                    executable.rename(executable.with_suffix(".disabled"))
                elif failure == "invalid-config":
                    executable.with_suffix(".disabled").rename(executable)
                    trusted.write_text('broken = "unsafe-config-diagnostic')
                elif failure == "dangling-config":
                    trusted.unlink()
                    trusted.symlink_to(self.root / "missing-config")
                else:
                    trusted.unlink()
                    trusted.mkdir()
                result = self.run_cli(
                    "fixture",
                    "--",
                    sys.executable,
                    "-c",
                    f"open({str(self.marker)!r}, 'w').close()",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("unsafe-", result.stderr)
                self.assertFalse(self.marker.exists())

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
                self.config / "switchboard/config.toml",
            ),
            [
                "switchboard",
                "--config",
                str(self.config / "switchboard/config.toml"),
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
                self.config / "switchboard/config.toml",
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
                self.config / "switchboard/config.toml",
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
