#!/usr/bin/env python3
"""Reuse or normally restart an existing Chrome profile with native CDP."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

DEFAULT_CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


class ControlError(Exception):
    """A fixed, safe diagnostic; Chrome output and state never enter errors."""


@dataclass(frozen=True)
class ChromeProcess:
    pid: int
    started: str
    arguments: str
    files: tuple[Path, ...]

    def owns(self, root: Path) -> bool:
        return any(path.is_relative_to(root) for path in self.files)

    def native_port(self, port: int) -> bool:
        return (
            re.search(
                rf"(?:^|\s)--remote-debugging-port={port}(?=\s|$)", self.arguments
            )
            is not None
        )


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class ChromeSystem:
    def __init__(self, binary: Path):
        self.binary = binary

    @staticmethod
    def read(command: list[str], allow_absent: bool = False) -> str:
        try:
            result = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ControlError("process_inspection_failed") from error
        if allow_absent and result.returncode == 1:
            return ""
        if result.returncode:
            raise ControlError("process_inspection_failed")
        return result.stdout

    def processes(self) -> list[ChromeProcess]:
        listing = self.read(["/bin/ps", "-axo", "pid=,uid=,comm="])
        processes = []
        for line in listing.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) != 3 or fields[2] != str(self.binary):
                continue
            if int(fields[1]) != os.getuid():
                raise ControlError("chrome_user_mismatch")
            pid = int(fields[0])
            # A process can exit between ps and lsof. Retry inspection rather
            # than mistake incomplete ownership evidence for a closed browser.
            try:
                arguments = self.read(["/bin/ps", "-ww", "-p", str(pid), "-o", "args="])
                started = self.read(["/bin/ps", "-p", str(pid), "-o", "lstart="])
                files = self.read(
                    ["/usr/sbin/lsof", "-a", "-p", str(pid), "-Fn"], allow_absent=True
                )
            except ControlError:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                raise
            processes.append(
                ChromeProcess(
                    pid,
                    started.strip(),
                    arguments.strip(),
                    tuple(
                        Path(line[1:])
                        for line in files.splitlines()
                        if line.startswith("n/")
                    ),
                )
            )
        return processes

    def listeners(self, port: int) -> set[int]:
        try:
            result = subprocess.run(
                ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ControlError("port_inspection_failed") from error
        if result.returncode not in (0, 1):
            raise ControlError("port_inspection_failed")
        return {
            int(line[1:])
            for line in result.stdout.splitlines()
            if re.fullmatch(r"p\d+", line)
        }

    def endpoint_ready(self, port: int) -> bool:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect()
        )
        try:
            with opener.open(
                f"http://127.0.0.1:{port}/json/version", timeout=1
            ) as response:
                data = json.loads(response.read(65537))
            if not isinstance(data, dict) or not isinstance(data.get("Browser"), str):
                return False
            if not isinstance(data.get("webSocketDebuggerUrl"), str):
                return False
            endpoint = urllib.parse.urlsplit(data["webSocketDebuggerUrl"])
            return (
                data["Browser"].startswith(("Chrome/", "HeadlessChrome/"))
                and endpoint.scheme == "ws"
                and endpoint.hostname in ("127.0.0.1", "localhost", "::1")
                and endpoint.port == port
                and endpoint.path.startswith("/devtools/browser/")
                and not endpoint.username
                and not endpoint.password
                and not endpoint.query
                and not endpoint.fragment
            )
        except urllib.error.HTTPError as error:
            error.close()
            return False
        except (OSError, ValueError, TypeError):
            return False

    def quit(self, process: ChromeProcess) -> subprocess.Popen[bytes]:
        # terminate requests normal Quit, including unsaved-work checks. Its
        # return value confirms sending only; ensure() waits for actual exit.
        script = """function run(argv) {
            ObjC.import('AppKit');
            const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
            if (ObjC.unwrap(app.executableURL.path) !== argv[1] || app.isTerminated)
                throw new Error('Chrome identity changed');
            if (!app.terminate) throw new Error('Normal Quit was not sent');
        }"""
        try:
            return subprocess.Popen(
                [
                    "/usr/bin/osascript",
                    "-l",
                    "JavaScript",
                    "-e",
                    script,
                    str(process.pid),
                    str(self.binary),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as error:
            raise ControlError("normal_quit_unavailable") from error

    def launch(self, root: Path, profile: str, port: int) -> subprocess.Popen[bytes]:
        return self.start(
            [
                f"--user-data-dir={root}",
                f"--profile-directory={profile}",
                f"--remote-debugging-port={port}",
                "--restore-last-session",
            ]
        )

    def start(self, arguments: list[str]) -> subprocess.Popen[bytes]:
        try:
            return subprocess.Popen(
                [str(self.binary), *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as error:
            raise ControlError("chrome_start_failed") from error


class ChromeControl:
    def __init__(
        self,
        root: Path,
        port: int,
        system: ChromeSystem,
        timeout: float = 40,
        lock_directory: Path | None = None,
    ):
        self.root = root
        self.port = port
        self.system = system
        self.timeout = timeout
        self.lock_directory = (
            lock_directory or Path.home() / "Library/Caches/agent/chrome-control"
        )
        self.identity: tuple[int, int] | None = None

    def check_root(self) -> None:
        metadata = self.root.lstat()
        if (
            not self.root.is_absolute()
            or not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o022
        ):
            raise ControlError("profile_root_unconfirmed")
        identity = (metadata.st_dev, metadata.st_ino)
        if self.identity is not None and identity != self.identity:
            raise ControlError("profile_root_changed")
        root = self.root.resolve()
        default_root = Path.home() / "Library/Application Support/Google/Chrome"
        if root == default_root.resolve():
            raise ControlError("default_chrome_root_unsupported")
        self.identity = identity
        self.root = root

    def state(self) -> tuple[dict, os.stat_result]:
        self.check_root()
        path = self.root / "Local State"
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise ControlError("local_state_unconfirmed")
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ControlError("local_state_unconfirmed")
        return data, metadata

    def profile(self) -> str:
        data, _ = self.state()
        profile = data.get("profile", {}).get("last_used")
        if (
            not isinstance(profile, str)
            or not profile
            or profile in (".", "..")
            or "/" in profile
            or ":" in profile
        ):
            raise ControlError("last_profile_unconfirmed")
        directory = self.root / profile
        preferences = directory / "Preferences"
        if (
            directory.is_symlink()
            or not preferences.is_file()
            or preferences.is_symlink()
        ):
            raise ControlError("last_profile_unconfirmed")
        return profile

    def process(self, starting_pid: int | None = None) -> ChromeProcess | None:
        candidates = self.system.processes()
        owned = [process for process in candidates if process.owns(self.root)]
        if len(owned) > 1:
            raise ControlError("chrome_ownership_changed")
        if not owned and any(
            process.pid != starting_pid
            and (
                "--user-data-dir=" not in process.arguments
                or f"--user-data-dir={self.root}" in process.arguments
            )
            for process in candidates
        ):
            raise ControlError("chrome_ownership_unconfirmed")
        return owned[0] if owned else None

    def require_closed(self) -> None:
        self.check_root()
        if self.process() is not None:
            raise ControlError("chrome_started_during_recovery")

    def disable_approval(self) -> None:
        self.require_closed()
        data, before = self.state()
        devtools = data.get("devtools")
        debugging = (
            devtools.get("remote_debugging") if isinstance(devtools, dict) else None
        )
        if not isinstance(debugging, dict) or debugging.get("user-enabled") is not True:
            return
        debugging["user-enabled"] = False
        path = self.root / "Local State"
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", dir=self.root, delete=False
            ) as target:
                temporary = Path(target.name)
                json.dump(data, target, ensure_ascii=False)
                target.flush()
                os.fsync(target.fileno())
            temporary.chmod(stat.S_IMODE(before.st_mode))
            self.require_closed()
            after = path.lstat()
            if (after.st_ino, after.st_mtime_ns, after.st_size) != (
                before.st_ino,
                before.st_mtime_ns,
                before.st_size,
            ):
                raise ControlError("local_state_changed")
            os.replace(temporary, path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    @contextmanager
    def lock(self, deadline: float) -> Iterator[None]:
        self.lock_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory = self.lock_directory.lstat()
        if (
            not stat.S_ISDIR(directory.st_mode)
            or directory.st_uid != os.getuid()
            or directory.st_mode & 0o077
        ):
            raise ControlError("lock_directory_unconfirmed")
        name = hashlib.sha256(os.fsencode(self.root)).hexdigest() + ".lock"
        descriptor = os.open(
            self.lock_directory / name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600
        )
        try:
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077
            ):
                raise ControlError("lock_file_unconfirmed")
            while True:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise ControlError("recovery_busy") from None
                    time.sleep(0.05)
            yield
        finally:
            # Keep this inode: unlinking would let a waiter and a new caller
            # acquire different lock files for the same browser.
            os.close(descriptor)

    def ensure(self) -> dict[str, str | int | bool]:
        self.check_root()
        deadline = time.monotonic() + self.timeout
        with self.lock(deadline):
            self.profile()
            process = self.process()
            listeners = self.system.listeners(self.port)
            if listeners - ({process.pid} if process is not None else set()):
                raise ControlError("port_in_use")
            if process is not None:
                if (
                    process.native_port(self.port)
                    and process.pid in listeners
                    and self.system.endpoint_ready(self.port)
                ):
                    return {
                        "status": "ready",
                        "pid": process.pid,
                        "port": self.port,
                        "reused": True,
                    }
                current = self.process()
                if current is None or (current.pid, current.started) != (
                    process.pid,
                    process.started,
                ):
                    raise ControlError("chrome_ownership_changed")
                if self.system.listeners(self.port) - {process.pid}:
                    raise ControlError("port_in_use")
                request = self.system.quit(current)
                while True:
                    current = self.process()
                    exit_code = request.poll()
                    if current is None and exit_code is not None:
                        break
                    if exit_code is not None and exit_code != 0:
                        raise ControlError("normal_quit_unavailable")
                    if current is not None and (current.pid, current.started) != (
                        process.pid,
                        process.started,
                    ):
                        raise ControlError("chrome_ownership_changed")
                    if time.monotonic() >= deadline:
                        raise ControlError("normal_quit_pending")
                    time.sleep(0.1)
            self.require_closed()
            if self.system.listeners(self.port):
                raise ControlError("port_in_use")
            self.disable_approval()
            profile = self.profile()
            self.require_closed()
            launched = self.system.launch(self.root, profile, self.port)
            while time.monotonic() < deadline:
                process = self.process(starting_pid=launched.pid)
                listeners = self.system.listeners(self.port)
                if listeners - ({process.pid} if process is not None else set()):
                    raise ControlError("port_in_use")
                if (
                    process is not None
                    and process.native_port(self.port)
                    and process.pid in listeners
                    and self.system.endpoint_ready(self.port)
                ):
                    return {
                        "status": "ready",
                        "pid": process.pid,
                        "port": self.port,
                        "reused": False,
                    }
                time.sleep(0.1)
            raise ControlError("native_chrome_not_ready")


def main() -> int:
    parser = argparse.ArgumentParser(prog="chrome-control", description=__doc__)
    parser.add_argument("--user-data-dir", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--chrome-binary", type=Path, default=DEFAULT_CHROME)
    parser.add_argument("--timeout", type=float, default=40)
    args = parser.parse_args()
    try:
        if sys.platform != "darwin":
            raise ControlError("macos_required")
        if not 1 <= args.port <= 65535 or not 0 < args.timeout <= 120:
            raise ControlError("invalid_options")
        result = ChromeControl(
            args.user_data_dir,
            args.port,
            ChromeSystem(args.chrome_binary),
            args.timeout,
        ).ensure()
    except ControlError as error:
        print(json.dumps({"status": "error", "reason": str(error)}))
        return 1
    except KeyboardInterrupt:
        print(json.dumps({"status": "error", "reason": "interrupted"}))
        return 1
    except (OSError, ValueError, TypeError, AttributeError):
        print(json.dumps({"status": "error", "reason": "system_verification_failed"}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
