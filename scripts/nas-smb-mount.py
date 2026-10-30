#!/usr/bin/env python3
"""Mount a credential-managed SMB share without a login dialog or disk secrets."""

import argparse
import ctypes
import fcntl
import hashlib
import os
import plistlib
import signal
import stat
import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path
from urllib.parse import unquote, urlsplit


class MountError(Exception):
    pass


def mounted_source(path: Path) -> str | None:
    # Reading the mount table does not touch a possibly disconnected server.
    result = subprocess.run(
        ["/sbin/mount", "-t", "smbfs"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    marker = f" on {path} ("
    for line in result.stdout.splitlines():
        source, separator, _ = line.rpartition(marker)
        if separator:
            return source
    return None


def native_mount(url: str, username: str, password: str, path: Path) -> None:
    cf = ctypes.CDLL(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    )
    netfs = ctypes.CDLL("/System/Library/Frameworks/NetFS.framework/NetFS")
    pointer = ctypes.c_void_p
    index = ctypes.c_long
    cf.CFRelease.argtypes = [pointer]
    cf.CFRelease.restype = None
    cf.CFDataCreate.argtypes = [pointer, ctypes.c_char_p, index]
    cf.CFDataCreate.restype = pointer
    cf.CFPropertyListCreateWithData.argtypes = [
        pointer,
        pointer,
        ctypes.c_ulong,
        pointer,
        pointer,
    ]
    cf.CFPropertyListCreateWithData.restype = pointer
    cf.CFURLCreateWithString.argtypes = [pointer, pointer, pointer]
    cf.CFURLCreateWithString.restype = pointer
    netfs.NetFSMountURLSync.argtypes = [pointer] * 7
    netfs.NetFSMountURLSync.restype = ctypes.c_int

    with ExitStack() as owned:

        def retain(value: int | None) -> int:
            if not value:
                raise MountError("Could not allocate native mount options")
            owned.callback(cf.CFRelease, value)
            return value

        def property_list(value: object) -> int:
            data = plistlib.dumps(value)
            buffer = retain(cf.CFDataCreate(None, data, len(data)))
            # Mutable containers are required by the NetFS option dictionaries.
            return retain(cf.CFPropertyListCreateWithData(None, buffer, 1, None, None))

        server = retain(cf.CFURLCreateWithString(None, property_list(url), None))
        mountpoint = retain(
            cf.CFURLCreateWithString(None, property_list(path.as_uri()), None)
        )
        points = pointer()
        try:
            status = netfs.NetFSMountURLSync(
                server,
                mountpoint,
                property_list(username),
                property_list(password),
                property_list({"UIOption": "NoUI", "ForceNewSession": True}),
                property_list({"MountAtMountDir": True, "SoftMount": True}),
                ctypes.byref(points),
            )
        finally:
            if points.value:
                cf.CFRelease(points)
        if status:
            raise MountError(f"Native SMB mount failed, status {status}")


def authenticated_mount(path: Path, identity: Path) -> None:
    url = os.environ.pop("NAS_SMB_URL", "")
    username = os.environ.pop("NAS_SMB_USERNAME", "")
    password = os.environ.pop("NAS_SMB_PASSWORD", "")
    parsed = urlsplit(url)
    if (
        parsed.scheme != "smb"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or len(parsed.path.strip("/").split("/")) != 1
        or not parsed.path.strip("/")
        or not username
        or not password
    ):
        raise MountError("Invalid or missing SMB credentials")
    native_mount(url, username, password, path)
    source = mounted_source(path)
    actual = urlsplit("smb:" + source) if source else None
    if (
        actual is None
        or actual.hostname != parsed.hostname
        or unquote(actual.path.rstrip("/")) != unquote(parsed.path.rstrip("/"))
    ):
        raise MountError("Expected SMB share was not mounted at the configured path")
    identity.write_text(hashlib.sha256(source.encode()).hexdigest())
    print("NAS SMB share mounted")


def run_with_credentials(command: list[str]) -> int:
    # Bound both credential lookup and NetFS, including their child processes.
    child = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )

    def interrupted(signum: int, frame: object) -> None:
        raise MountError("SMB login mount interrupted")

    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        output, _ = child.communicate(timeout=90)
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        raise
    finally:
        signal.signal(signal.SIGTERM, previous)
    if child.returncode:
        raise MountError(
            "SMB login mount failed; retrying on the next launchd interval"
        )
    print(output, end="")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mount-point", required=True, type=Path)
    parser.add_argument("--credentials-command", required=True)
    parser.add_argument("--authenticated", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    os.umask(0o077)
    path = Path(os.path.abspath(args.mount_point.expanduser()))
    if not path.is_relative_to(Path.home()) or path == Path.home():
        raise MountError("Mount point must be a directory below the current home")
    state = Path.home() / ".local/state/nas-smb-mount"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = state.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise MountError("Invalid private mount state directory")
    state.chmod(0o700)
    identity = state / (hashlib.sha256(os.fsencode(path)).hexdigest() + ".identity")
    if args.authenticated:
        authenticated_mount(path, identity)
        return 0
    with (state / "mount.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        source = mounted_source(path)
        if source:
            if (
                identity.is_file()
                and identity.read_text() == hashlib.sha256(source.encode()).hexdigest()
            ):
                return 0
            raise MountError(
                "Mount point already in use; existing mount left unchanged"
            )
        if any(parent.is_symlink() for parent in (path, *path.parents)):
            raise MountError("Mount point must not contain symlinks")
        if os.path.ismount(path):
            raise MountError("Mount point already in use by another filesystem")
        path.mkdir(mode=0o500, parents=True, exist_ok=True)
        if (
            not path.is_dir()
            or path.stat().st_uid != os.getuid()
            or any(path.iterdir())
        ):
            raise MountError("Mount point must be an empty, user-owned directory")
        # Failed mounts must not leave a writable local substitute for NAS data.
        path.chmod(0o500)
        return run_with_credentials(
            [
                args.credentials_command,
                "nas-smb",
                "--",
                sys.executable,
                __file__,
                "--mount-point",
                str(path),
                "--credentials-command",
                args.credentials_command,
                "--authenticated",
            ]
        )


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (MountError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"nas-smb-mount: {error}", file=sys.stderr)
        sys.exit(1)
