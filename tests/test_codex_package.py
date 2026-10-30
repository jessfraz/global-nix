"""Exercise package-check teardown with a real daemon process group."""

import importlib.util
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-codex-package.py"
SPEC = importlib.util.spec_from_file_location(
    "codex_package_check", os.environ.get("CODEX_PACKAGE_CHECK_UNDER_TEST", SCRIPT)
)
checker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = checker
SPEC.loader.exec_module(checker)


class CodexPackageTests(unittest.TestCase):
    def test_shutdown_finishes_plugin_children_before_removing_home(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            voice = package / "codex-resources/voice"
            voice.mkdir(parents=True)
            (voice / "manifest.json").write_text('{"buildCommit":"test-commit"}')
            ready = root / "plugin-ready"
            report = root / "plugin-stopped.json"
            read_fd, write_fd = os.pipe()
            daemon: subprocess.Popen[bytes] | None = None
            homes: list[Path] = []
            real_run = subprocess.run

            # The daemon exits on stop, but its plugin worker remains in the
            # daemon's isolated session, as an in-flight marketplace Git does.
            worker = """
import json, os, signal, sys
from pathlib import Path
if os.fork() == 0:
    def stop(signum, frame):
        Path(sys.argv[3]).write_text(json.dumps({"home_present": Path.home().is_dir()}))
        os._exit(0)
    signal.signal(signal.SIGTERM, stop)
    Path(sys.argv[2]).touch()
    while True:
        signal.pause()
os.close(int(sys.argv[1]))
while True:
    signal.pause()
"""

            def run(
                arguments: list[str],
                *,
                env: dict[str, str] | None = None,
                **options: object,
            ) -> subprocess.CompletedProcess[str]:
                nonlocal daemon, write_fd
                if arguments[0] == "ps":
                    return real_run(arguments, env=env, **options)
                assert env is not None
                home = Path(env["HOME"])
                output = ""
                if arguments[-3:-1] == ["app-server", "daemon"]:
                    action = arguments[-1]
                    if action == "start":
                        homes.append(home)
                        daemon = subprocess.Popen(
                            [
                                sys.executable,
                                "-c",
                                worker,
                                str(write_fd),
                                str(ready),
                                str(report),
                            ],
                            env=env,
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            pass_fds=(write_fd,),
                            start_new_session=True,
                        )
                        os.close(write_fd)
                        write_fd = -1
                        deadline = time.monotonic() + 5
                        while not ready.exists():
                            self.assertLess(
                                time.monotonic(), deadline, "plugin did not start"
                            )
                            time.sleep(0.01)
                    assert daemon is not None
                    if action == "stop":
                        daemon.terminate()
                        daemon.wait(timeout=5)
                    output = json.dumps(
                        {
                            "status": {
                                "start": "started",
                                "version": "running",
                                "stop": "stopped",
                            }[action],
                            "pid": daemon.pid if action == "start" else None,
                            "managedCodexPath": str(home / ".codex/bin/codex"),
                            "managedCodexVersion": "0.165.0",
                            "appServerVersion": "0.165.0",
                            "socketPath": str(
                                home / ".codex/app-server-daemon/check.sock"
                            ),
                        }
                    )
                elif arguments[-1] == "--version":
                    output = "codex-cli 0.165.0\n"
                elif arguments[-1] == "--build-commit":
                    output = "test-commit\n"
                return subprocess.CompletedProcess(arguments, 0, output, "")

            try:
                with (
                    patch.object(checker, "validate_layout", return_value=False),
                    patch.object(checker.subprocess, "run", side_effect=run),
                ):
                    checker.check_package(package, "0.165.0", root / "source")
                readable, _, _ = select.select([read_fd], [], [], 0.2)
                self.assertEqual(
                    readable, [read_fd], "plugin worker survived package-check teardown"
                )
                self.assertEqual(os.read(read_fd, 1), b"")
                self.assertTrue(json.loads(report.read_text())["home_present"])
                self.assertTrue(all(not home.exists() for home in homes))
            finally:
                if daemon is not None:
                    try:
                        os.killpg(daemon.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    daemon.wait(timeout=5)
                if write_fd >= 0:
                    os.close(write_fd)
                os.close(read_fd)
                for home in homes:
                    shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
