#!/usr/bin/env python3
"""Check an assembled Codex package using its actual isolated daemon lifecycle."""

import argparse
import importlib
import inspect
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class DaemonStatus:
    status: str
    pid: int | None
    managed_path: Path
    managed_version: str | None
    server_version: str | None
    socket_path: Path

    @classmethod
    def parse(cls, output: str) -> "DaemonStatus":
        value = json.loads(output)
        return cls(
            status=value["status"],
            pid=value.get("pid"),
            managed_path=Path(value["managedCodexPath"]),
            managed_version=value.get("managedCodexVersion"),
            server_version=value.get("appServerVersion"),
            socket_path=Path(value["socketPath"]),
        )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def finish_process_group(group: int) -> None:
    def running() -> bool:
        result = subprocess.run(
            ["ps", "-A", "-o", "pgid=,stat="],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        return any(
            int(pid_group) == group and not state.startswith("Z")
            for pid_group, state in (
                line.split() for line in result.stdout.splitlines()
            )
        )

    for termination in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(group, termination)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + 5
        while running():
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        else:
            return
    raise RuntimeError("isolated daemon process group survived cleanup")


def validate_layout(package: Path, source: Path) -> bool:
    # Use the matching release's layout contract, including platform helpers.
    sys.dont_write_bytecode = True
    os.environ["CODEX_REPO_ROOT"] = str(source)
    sys.path.insert(0, str(source / "scripts"))
    layout = importlib.import_module("codex_package.layout")
    targets = importlib.import_module("codex_package.targets")
    manifest = json.loads((package / "codex-package.json").read_text())
    # Releases before 0.163 bundle zsh and require explicitly validating it.
    includes_zsh = (
        "include_zsh" in inspect.signature(layout.validate_package_dir).parameters
    )
    layout_options = {"include_zsh": True} if includes_zsh else {}
    layout.validate_package_dir(
        package,
        targets.PACKAGE_VARIANTS["codex"],
        targets.TARGET_SPECS[manifest["target"]],
        **layout_options,
    )
    return includes_zsh


def check_package(
    package: Path, version: str, source: Path, *, layout_only: bool = False
) -> None:
    home = Path(tempfile.mkdtemp(prefix="codex-package-check-")).resolve()
    codex_home = home / ".codex"
    state = codex_home / "app-server-daemon"
    state.mkdir(parents=True)
    (home / "tmp").mkdir()
    (state / "settings.json").write_text(
        json.dumps(
            {
                "remoteControlEnabled": False,
                "shutdownGraceSeconds": 5,
                "updater": {"autoUpdateEnabled": False},
            }
        )
    )
    (codex_home / "config.toml").write_text(
        'cli_auth_credentials_store = "file"\n'
        "[analytics]\nenabled = false\n"
        '[otel]\nexporter = "none"\ntrace_exporter = "none"\nmetrics_exporter = "none"\n'
    )
    # Do not inherit provider credentials, daemon overrides, or personal config.
    environment = {
        "PATH": os.environ["PATH"],
        "HOME": str(home),
        "CODEX_HOME": str(codex_home),
        "CODEX_SQLITE_HOME": str(codex_home),
        "TMPDIR": str(home / "tmp"),
        "XDG_CONFIG_HOME": str(home / "config"),
        "XDG_CACHE_HOME": str(home / "cache"),
        "XDG_DATA_HOME": str(home / "data"),
        "CI": "1",
        "NO_COLOR": "1",
    }
    codex = package / "bin/codex"

    def run(program: Path, *arguments: str) -> str:
        result = subprocess.run(
            [str(program), *arguments],
            cwd=home,
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        require(
            result.returncode == 0,
            f"{program.name} {' '.join(arguments)} failed ({result.returncode}):\n"
            f"{result.stdout}{result.stderr}",
        )
        return result.stdout

    def lifecycle(action: str) -> DaemonStatus:
        return DaemonStatus.parse(run(codex, "app-server", "daemon", action))

    started: DaemonStatus | None = None
    process_group: int | None = None
    daemon_attempted = False
    try:
        includes_zsh = validate_layout(package, source)
        require(
            run(codex, "--version").strip() == f"codex-cli {version}",
            "CLI version mismatch",
        )
        run(package / "bin/codex-code-mode-host", "--help")
        if layout_only:
            run(package / "codex-path/rg", "--version")
            print(f"Codex {version}: package layout and basic executables passed")
            return
        daemon_attempted = True
        started = lifecycle("start")
        require(
            started.status == "started", f"unexpected daemon status: {started.status}"
        )
        require(
            started.managed_path.resolve().is_relative_to(codex_home),
            "daemon package was not copied into the isolated home",
        )
        require(
            started.socket_path.is_relative_to(codex_home),
            "daemon socket is not scoped to the isolated home",
        )
        if started.pid is None:
            raise RuntimeError("started daemon did not return its PID")
        group = os.getpgid(started.pid)
        require(
            group == started.pid and group != os.getpgrp(),
            "daemon did not create its own process group",
        )
        process_group = group
        running = lifecycle("version")
        require(
            running.status == "running"
            and running.managed_version == version
            and running.server_version == version,
            f"daemon version mismatch: {running}",
        )
        run(started.managed_path.resolve().parent / "codex-code-mode-host", "--help")
        run(package / "codex-path/rg", "--version")
        if includes_zsh:
            require(
                run(
                    package / "codex-resources/zsh/bin/zsh",
                    "-f",
                    "-c",
                    "print $((2 + 3))",
                ).strip()
                == "5",
                "bundled zsh could not execute a command",
            )
        voice = package / "codex-resources/voice"
        voice_manifest = json.loads((voice / "manifest.json").read_text())
        # This identity command loads linked libraries without opening audio devices.
        require(
            run(voice / "bin/codex-voice-host", "--build-commit").strip()
            == voice_manifest["buildCommit"],
            "voice helper build identity mismatch",
        )
        require(
            not (state / "daemon-updater.pid").exists(), "updater unexpectedly started"
        )
    finally:
        if daemon_attempted:
            # Stop via the same isolated home, including failed/partial starts.
            # Preserve its files if cleanup fails so a live process is never orphaned.
            try:
                stopped = lifecycle("stop")
            except Exception as error:
                raise RuntimeError(f"daemon cleanup failed; inspect {home}") from error
            require(
                stopped.status in ("stopped", "notRunning")
                and (started is None or stopped.status == "stopped"),
                f"daemon cleanup failed; inspect {home}: {stopped.status}",
            )
            if started is not None:
                require(
                    not started.socket_path.exists()
                    and not started.socket_path.is_symlink(),
                    f"daemon socket survived shutdown; inspect {home}",
                )
            if process_group is not None:
                # Plugin Git children can outlive the stopped daemon. Only its
                # verified isolated group belongs to this check.
                try:
                    finish_process_group(process_group)
                except Exception as error:
                    raise RuntimeError(
                        f"daemon cleanup failed; inspect {home}"
                    ) from error
        shutil.rmtree(home)
    print(
        f"Codex {version}: package layout, helpers, daemon startup/version/shutdown passed"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("version")
    parser.add_argument(
        "source", type=Path, help="matching upstream Codex source checkout"
    )
    parser.add_argument(
        "--layout-only",
        action="store_true",
        help="check layout and basic executables without starting a daemon or native media helpers",
    )
    args = parser.parse_args()
    check_package(
        args.package.resolve(),
        args.version,
        args.source.resolve(),
        layout_only=args.layout_only,
    )


if __name__ == "__main__":
    main()
