"""Exercise recovery ownership, real profile writes, and caller serialization."""

import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/chrome-control.py"
SPEC = importlib.util.spec_from_file_location(
    "chrome_control", os.environ.get("CHROME_CONTROL_UNDER_TEST", SCRIPT)
)
control = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = control
SPEC.loader.exec_module(control)


class IsolatedChromeFixture(control.ChromeSystem):
    def __init__(self, binary, receipt):
        super().__init__(binary)
        if "Google Chrome for Testing.app" not in binary.parts:
            raise ValueError("Only Chrome for Testing may use this fixture")
        self.receipt = receipt
        self.children = []
        self.created = []

    def start(self, arguments):
        # Cold start and every recovery relaunch use this same boundary.
        child = super().start(
            [
                # Normal macOS Quit requires the GUI application's lifecycle.
                "--use-mock-keychain",
                "--password-store=basic",
                "--no-first-run",
                "--no-default-browser-check",
                *arguments,
            ]
        )
        self.children.append(child)
        root = next(
            argument.removeprefix("--user-data-dir=")
            for argument in arguments
            if argument.startswith("--user-data-dir=")
        )
        metadata = {"pid": child.pid, "pgid": child.pid, "root": root, "tabs": []}
        self.created.append(metadata)
        self.receipt.write_text(json.dumps(self.created))
        print(json.dumps({"fixture_created": metadata}), flush=True)
        return child

    def endpoint_ready(self, port):
        if not super().endpoint_ready(port):
            return False
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), control.NoRedirect()
        )
        with opener.open(f"http://127.0.0.1:{port}/json/list", timeout=1) as response:
            targets = json.load(response)
        tabs = sorted(
            target["id"]
            for target in targets
            if target.get("type") == "page" and isinstance(target.get("id"), str)
        )
        if tabs != self.created[-1]["tabs"]:
            self.created[-1]["tabs"] = tabs
            self.receipt.write_text(json.dumps(self.created))
            print(json.dumps({"fixture_targets": self.created[-1]}), flush=True)
        return True

    def close(self, grace=3):
        # These groups were created with start_new_session by this fixture.
        # Never discover a browser to close through a reusable TCP port.
        groups = {child.pid for child in self.children}
        errors = []
        for group in groups:
            try:
                os.killpg(group, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except OSError:
                errors.append(group)
        for child in self.children:
            try:
                child.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass
            except OSError:
                errors.append(child.pid)

        def alive(group):
            try:
                os.killpg(group, 0)
                return True
            except ProcessLookupError:
                return False

        for group in groups:
            try:
                if alive(group):
                    os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                errors.append(group)
        for child in self.children:
            try:
                child.wait(timeout=grace)
            except (OSError, subprocess.TimeoutExpired):
                errors.append(child.pid)
        deadline = time.monotonic() + grace
        while any(alive(group) for group in groups) and time.monotonic() < deadline:
            time.sleep(0.02)
        remaining = [group for group in groups if alive(group)]
        if errors or remaining:
            raise RuntimeError("Owned fixture process group cleanup incomplete")


class Forwarder:
    def __init__(self, pending: bool = False, exit_code: int = 0):
        self.pending = pending
        self.exit_code = exit_code
        self.pid = 202

    def poll(self):
        return None if self.pending else self.exit_code


class FixtureSystem:
    """Substitute only macOS process/network boundaries, never profile logic."""

    def __init__(self, root: Path):
        self.root = root
        self.running = True
        self.native = False
        self.endpoint = False
        self.cancel_quit = False
        self.foreign_listener = False
        self.changing_files = False
        self.foreign_root = False
        self.replace_before_quit = False
        self.profile_after_quit = None
        self.after_quit = None
        self.launch_endpoint = True
        self.foreign_after_launch = False
        self.inspections = 0
        self.quits = []
        self.launches = []

    def processes(self):
        self.inspections += 1
        if not self.running:
            return []
        root = self.root.parent / "foreign" if self.foreign_root else self.root
        files = [root / "Default/History"]
        if self.changing_files:
            files.append(root / f"Cache/{self.inspections}")
        started = (
            "replaced"
            if self.replace_before_quit and self.inspections > 1
            else "original"
        )
        return [
            control.ChromeProcess(
                101,
                started,
                "--remote-debugging-port=9222" if self.native else "",
                tuple(files),
            )
        ]

    def listeners(self, port):
        if self.foreign_after_launch and self.launches:
            return {101, 999}
        if self.foreign_listener:
            return {999}
        return {101} if self.running else set()

    def endpoint_ready(self, port):
        return self.endpoint

    def quit(self, process):
        self.quits.append(process.pid)
        if not self.cancel_quit:
            self.running = False
            if self.profile_after_quit:
                path = self.root / "Local State"
                data = json.loads(path.read_text())
                data["profile"]["last_used"] = self.profile_after_quit
                path.write_text(json.dumps(data))
            if self.after_quit:
                self.after_quit()
        return Forwarder(self.cancel_quit)

    def launch(self, root, profile, port):
        self.launches.append((root, profile, port))
        self.running = self.native = True
        self.endpoint = self.launch_endpoint
        return Forwarder()


class ChromeControlTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.root = self.directory / "existing Chrome"
        self.root.mkdir(mode=0o700)
        for profile in ("Default", "Profile 2"):
            (self.root / profile).mkdir()
            (self.root / profile / "Preferences").write_text("{}")
        self.state = {
            "profile": {"last_used": "Default"},
            "devtools": {
                "remote_debugging": {
                    "user-enabled": True,
                    "pairing-token": "fixture-private",
                },
                "remote_debugging_enabled": True,
            },
            "unrelated": {"keep": [1, 2, 3]},
        }
        self.state_path = self.root / "Local State"
        self.state_path.write_text(json.dumps(self.state, indent=2))
        self.state_path.chmod(0o600)
        self.system = FixtureSystem(self.root)

    def helper(self, timeout=0.4):
        return control.ChromeControl(
            self.root, 9222, self.system, timeout, self.directory / "locks"
        )

    def test_default_root_is_refused_before_quit_or_profile_writes(self):
        home = self.directory / "home"
        root = home / "Library/Application Support/Google/Chrome"
        root.parent.mkdir(parents=True)
        self.root.rename(root)
        system = FixtureSystem(root)
        before = (root / "Local State").read_bytes()
        alias_directory = root.parent / "alias"
        alias_directory.mkdir()
        for candidate in (root, alias_directory / ".." / "Chrome"):
            with self.subTest(root=candidate):
                with patch.object(control.Path, "home", return_value=home):
                    helper = control.ChromeControl(
                        candidate, 9222, system, 0.4, self.directory / "locks"
                    )
                    with self.assertRaisesRegex(
                        control.ControlError, "default_chrome_root_unsupported"
                    ):
                        helper.ensure()
                self.assertEqual(system.inspections, 0)
                self.assertEqual(system.quits, [])
                self.assertEqual(system.launches, [])
                self.assertEqual((root / "Local State").read_bytes(), before)

    def test_ready_native_process_is_reused_without_profile_writes(self):
        self.system.native = self.system.endpoint = True
        before = self.state_path.read_bytes()
        result = self.helper().ensure()
        self.assertTrue(result["reused"])
        self.assertEqual(result["pid"], 101)
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(self.system.quits, [])
        self.assertEqual(self.system.launches, [])

    def test_approval_recovery_changes_only_exact_nested_preference(self):
        result = self.helper().ensure()
        expected = json.loads(json.dumps(self.state))
        expected["devtools"]["remote_debugging"]["user-enabled"] = False
        self.assertEqual(json.loads(self.state_path.read_text()), expected)
        self.assertEqual(self.state_path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(result["reused"])
        self.assertEqual(self.system.quits, [101])
        self.assertEqual(self.system.launches, [(self.root, "Default", 9222)])

    def test_background_file_activity_does_not_change_process_identity(self):
        self.system.changing_files = True
        self.assertEqual(self.helper().ensure()["status"], "ready")
        self.assertEqual(len(self.system.quits), 1)
        self.assertEqual(len(self.system.launches), 1)

    def test_foreign_port_owner_is_rejected_before_quit(self):
        self.system.foreign_listener = True
        before = self.state_path.read_bytes()
        with self.assertRaisesRegex(control.ControlError, "port_in_use"):
            self.helper().ensure()
        self.assertTrue(self.system.running)
        self.assertEqual(self.system.quits, [])
        self.assertEqual(self.system.launches, [])
        self.assertEqual(self.state_path.read_bytes(), before)

    def test_canceled_normal_quit_preserves_state_and_never_launches(self):
        self.system.cancel_quit = True
        before = self.state_path.read_bytes()
        with self.assertRaisesRegex(control.ControlError, "normal_quit_pending"):
            self.helper(timeout=0.12).ensure()
        self.assertTrue(self.system.running)
        self.assertEqual(len(self.system.quits), 1)
        self.assertEqual(self.system.launches, [])
        self.assertEqual(self.state_path.read_bytes(), before)

    def test_rejected_quit_is_reported_without_waiting_or_relaunching(self):
        before = self.state_path.read_bytes()

        def reject(process):
            self.system.quits.append(process.pid)
            return Forwarder(exit_code=1)

        with (
            patch.object(self.system, "quit", side_effect=reject),
            self.assertRaisesRegex(control.ControlError, "normal_quit_unavailable"),
        ):
            self.helper(timeout=0.12).ensure()
        self.assertEqual(self.system.quits, [101])
        self.assertEqual(self.system.launches, [])
        self.assertTrue(self.system.running)
        self.assertEqual(self.state_path.read_bytes(), before)

    def test_unconfirmed_root_owner_is_never_quit(self):
        self.system.foreign_root = True
        with self.assertRaisesRegex(
            control.ControlError, "chrome_ownership_unconfirmed"
        ):
            self.helper().ensure()
        self.assertEqual(self.system.quits, [])
        self.assertEqual(self.system.launches, [])

    def test_replaced_process_is_never_quit(self):
        self.system.replace_before_quit = True
        with self.assertRaisesRegex(control.ControlError, "chrome_ownership_changed"):
            self.helper().ensure()
        self.assertEqual(self.system.quits, [])
        self.assertEqual(self.system.launches, [])

    def test_last_used_profile_is_reread_after_normal_quit(self):
        self.system.profile_after_quit = "Profile 2"
        self.helper().ensure()
        self.assertEqual(self.system.quits, [101])
        self.assertEqual(self.system.launches, [(self.root, "Profile 2", 9222)])

    def test_replaced_root_is_not_modified_or_launched(self):
        saved = self.directory / "original root"
        before = self.state_path.read_bytes()

        def replace_root():
            self.root.rename(saved)
            self.root.mkdir(mode=0o700)
            (self.root / "Local State").write_text("replacement must survive")

        self.system.after_quit = replace_root
        with self.assertRaisesRegex(control.ControlError, "profile_root_changed"):
            self.helper().ensure()
        self.assertEqual((saved / "Local State").read_bytes(), before)
        self.assertEqual(self.state_path.read_text(), "replacement must survive")
        self.assertEqual(self.system.launches, [])

    def test_failed_native_readiness_does_not_repeat_quit_or_launch(self):
        self.system.launch_endpoint = False
        with self.assertRaisesRegex(control.ControlError, "native_chrome_not_ready"):
            self.helper(timeout=0.12).ensure()
        self.assertEqual(len(self.system.quits), 1)
        self.assertEqual(len(self.system.launches), 1)
        self.assertTrue(self.system.running)

    def test_foreign_listener_appearing_during_launch_is_not_accepted(self):
        self.system.foreign_after_launch = True
        with self.assertRaisesRegex(control.ControlError, "port_in_use"):
            self.helper().ensure()
        self.assertEqual(len(self.system.quits), 1)
        self.assertEqual(len(self.system.launches), 1)
        self.assertTrue(self.system.running)

    def test_native_flag_with_unusable_endpoint_is_recovered(self):
        self.system.native = True
        self.assertFalse(self.helper().ensure()["reused"])
        self.assertEqual(len(self.system.quits), 1)
        self.assertEqual(len(self.system.launches), 1)

    def test_concurrent_callers_recover_once_then_reuse(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(
                pool.map(lambda _: self.helper(timeout=2).ensure(), range(2))
            )
        self.assertEqual(sorted(result["reused"] for result in results), [False, True])
        self.assertEqual(len(self.system.quits), 1)
        self.assertEqual(len(self.system.launches), 1)

    def test_symlink_root_and_missing_profile_are_preserved(self):
        alias = self.directory / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(control.ControlError, "profile_root_unconfirmed"):
            control.ChromeControl(alias, 9222, self.system).ensure()
        (self.root / "Default/Preferences").unlink()
        with self.assertRaisesRegex(control.ControlError, "last_profile_unconfirmed"):
            self.helper().ensure()
        self.assertEqual(self.system.quits, [])

    def test_cli_failure_has_only_a_safe_diagnostic(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--user-data-dir",
                str(self.directory / "missing-private-marker"),
                "--port",
                "9222",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["status"], "error")
        self.assertNotIn("missing-private-marker", result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")

    def test_real_http_endpoint_rejects_approval_404_and_accepts_native_cdp(self):
        class Handler(BaseHTTPRequestHandler):
            native = False

            def do_GET(self):
                self.send_response(200 if self.native else 404)
                self.end_headers()
                if self.native:
                    self.wfile.write(
                        json.dumps(
                            {
                                "Browser": "Chrome/156.0.0.0",
                                "webSocketDebuggerUrl": f"ws://127.0.0.1:{self.server.server_port}/devtools/browser/fixture",
                            }
                        ).encode()
                    )

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            system = control.ChromeSystem(control.DEFAULT_CHROME)
            self.assertFalse(system.endpoint_ready(server.server_port))
            Handler.native = True
            self.assertTrue(system.endpoint_ready(server.server_port))
        finally:
            server.shutdown()
            worker.join()
            server.server_close()

    def test_fixture_isolates_every_recovery_launch_and_records_ownership(self):
        binary = Path(
            "/fixture/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        )
        receipt = self.directory / "fixture-processes.json"
        fixture = IsolatedChromeFixture(binary, receipt)
        child = Forwarder()
        with (
            patch.object(control.subprocess, "Popen", return_value=child) as spawn,
            patch("builtins.print"),
        ):
            fixture.launch(self.root, "Default", 9222)
            fixture.launch(self.root, "Profile 2", 9223)
        self.assertEqual(spawn.call_count, 2)
        for call in spawn.call_args_list:
            arguments = call.args[0]
            self.assertEqual(arguments.count("--use-mock-keychain"), 1)
            self.assertEqual(arguments.count("--password-store=basic"), 1)
            self.assertIn(f"--user-data-dir={self.root}", arguments)
            self.assertTrue(call.kwargs["start_new_session"])
        self.assertEqual(
            json.loads(receipt.read_text()),
            [
                {
                    "pid": child.pid,
                    "pgid": child.pid,
                    "root": str(self.root),
                    "tabs": [],
                },
                {
                    "pid": child.pid,
                    "pgid": child.pid,
                    "root": str(self.root),
                    "tabs": [],
                },
            ],
        )
        with self.assertRaisesRegex(ValueError, "Only Chrome for Testing"):
            IsolatedChromeFixture(control.DEFAULT_CHROME, receipt)

    def test_fixture_reaps_all_owned_groups_even_when_one_child_times_out(self):
        class Child:
            def __init__(self, pid):
                self.pid = pid
                self.waits = 0

            def wait(self, timeout):
                self.waits += 1
                if self.pid == 70001 and self.waits == 1:
                    raise subprocess.TimeoutExpired("fixture", timeout)
                return 0

        fixture = IsolatedChromeFixture(
            Path(
                "/fixture/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
            ),
            self.directory / "ownership.json",
        )
        fixture.children = [Child(70001), Child(70002)]
        groups = {70001, 70002}
        calls = []

        def kill(group, sig):
            calls.append((group, sig))
            if group not in groups:
                raise ProcessLookupError
            if sig == signal.SIGKILL or group == 70002 and sig == signal.SIGTERM:
                groups.remove(group)

        with patch.object(os, "killpg", side_effect=kill):
            fixture.close(grace=0.01)
        self.assertEqual(groups, set())
        self.assertTrue(all(child.waits == 2 for child in fixture.children))
        self.assertIn((70001, signal.SIGTERM), calls)
        self.assertIn((70002, signal.SIGTERM), calls)
        self.assertIn((70001, signal.SIGKILL), calls)


@unittest.skipUnless(
    sys.platform == "darwin" and os.environ.get("CHROME_CONTROL_TEST_BINARY"),
    "explicit disposable Chrome for Testing fixture required",
)
class NativeChromeFixtureTests(unittest.TestCase):
    def test_cold_launch_reuse_and_normal_quit_recovery(self):
        binary = Path(os.environ["CHROME_CONTROL_TEST_BINARY"]).resolve()
        self.assertIn("Google Chrome for Testing.app", binary.parts)
        directory = Path(tempfile.mkdtemp(prefix="chrome-control-fixture-")).resolve()
        system = IsolatedChromeFixture(binary, directory / "fixture-processes.json")

        def cleanup():
            system.close()
            # Preserve ownership evidence if group cleanup cannot be verified.
            shutil.rmtree(directory)

        self.addCleanup(cleanup)
        root = directory / "existing profile"
        (root / "Profile 2").mkdir(parents=True, mode=0o700)
        root.chmod(0o700)
        (root / "Profile 2/Preferences").write_text("{}")
        (root / "Local State").write_text(
            json.dumps(
                {
                    "profile": {"last_used": "Profile 2"},
                    "devtools": {"remote_debugging": {"user-enabled": True}},
                }
            )
        )
        ports = []
        for _ in range(2):
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                ports.append(listener.getsockname()[1])

        first = control.ChromeControl(
            root, ports[0], system, 20, directory / "locks"
        ).ensure()
        self.assertFalse(first["reused"])
        second = control.ChromeControl(
            root, ports[0], system, 20, directory / "locks"
        ).ensure()
        self.assertTrue(second["reused"])
        self.assertEqual(first["pid"], second["pid"])
        third = control.ChromeControl(
            root, ports[1], system, 20, directory / "locks"
        ).ensure()
        self.assertFalse(third["reused"])
        self.assertNotEqual(first["pid"], third["pid"])
        self.assertTrue(system.endpoint_ready(ports[1]))
        self.assertFalse(
            json.loads((root / "Local State").read_text())["devtools"][
                "remote_debugging"
            ]["user-enabled"]
        )
        self.assertTrue(all(child.poll() is not None for child in system.children[:-1]))


if __name__ == "__main__":
    unittest.main()
