#!/usr/bin/env python3
"""Run one command with credentials, without exporting secrets to the caller."""

import argparse
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import tomllib


class CredentialError(Exception):
    pass


def optional_string(data: dict, key: str) -> str | None:
    value = data.get(key)
    if value is not None and not isinstance(value, str):
        raise CredentialError(f"Credential field {key} must be a string")
    return value


@dataclass(frozen=True)
class Secret:
    env: tuple[str, ...]
    cache_file: str | None
    account: str | None
    item: str | None
    field: str | None
    vault: str | None
    file_env: str | None
    strip_quotes: bool

    @classmethod
    def parse(cls, data: object) -> "Secret":
        if not isinstance(data, dict):
            raise CredentialError("Invalid credential source")
        env = data.get("env", [])
        if not isinstance(env, list) or any(not isinstance(name, str) for name in env):
            raise CredentialError("Credential env must be a list of variable names")
        result = cls(
            tuple(env),
            *(
                optional_string(data, key)
                for key in (
                    "cache_file",
                    "account",
                    "item",
                    "field",
                    "vault",
                    "file_env",
                )
            ),
            data.get("strip_quotes", False),
        )
        if type(result.strip_quotes) is not bool:
            raise CredentialError("strip_quotes must be a boolean")
        if not result.cache_file and not (
            result.item and result.account and result.field
        ):
            raise CredentialError(
                "Credential requires a cache file or complete 1Password reference"
            )
        if result.item and not (result.account and result.field):
            raise CredentialError("Incomplete 1Password reference")
        return result


@dataclass(frozen=True)
class Profile:
    environment: dict[str, str]
    secrets: tuple[Secret, ...]
    provider: str | None

    @classmethod
    def parse(cls, data: object) -> "Profile":
        if not isinstance(data, dict):
            raise CredentialError("Invalid credential profile")
        environment = data.get("environment", {})
        secrets = data.get("secrets", [])
        if not isinstance(environment, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in environment.items()
        ):
            raise CredentialError(
                "Credential environment requires string names and values"
            )
        if not isinstance(secrets, list):
            raise CredentialError("Credential sources must be a list")
        return cls(
            environment,
            tuple(Secret.parse(secret) for secret in secrets),
            optional_string(data, "provider"),
        )


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))


def namespaces() -> dict[str, str]:
    path = config_home() / "switchboard/config.toml"
    if not path.exists():
        return {}
    config = tomllib.loads(path.read_text())
    result: dict[str, str] = {}
    for provider, accounts in config.get("namespace", {}).items():
        for name, namespace in accounts.items():
            result[f"{provider}.{name}"] = namespace["provider"]
    return result


def profiles() -> dict[str, Profile]:
    path = config_home() / "with-credentials/profiles.json"
    if not path.exists():
        return {}
    result = json.loads(path.read_text())
    if not isinstance(result, dict):
        raise CredentialError("Invalid credential profiles")
    return {name: Profile.parse(profile) for name, profile in result.items()}


def ssh_socket(launch: bool = False) -> tuple[str | None, str]:
    executable = shutil.which("gpgconf")
    if executable is None:
        return None, "gpgconf_unavailable"
    try:
        result = subprocess.run(
            [executable, "--list-dirs", "agent-ssh-socket"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        path = result.stdout.strip()
        if not path:
            return None, "socket_unconfigured"
        if launch and not Path(path).exists():
            subprocess.run(
                [executable, "--launch", "gpg-agent"],
                capture_output=True,
                timeout=5,
                check=True,
            )
        if not Path(path).exists() or not stat.S_ISSOCK(Path(path).stat().st_mode):
            return None, "socket_unavailable"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(1)
            connection.connect(path)
        return path, "ready"
    except (OSError, subprocess.SubprocessError):
        return None, "socket_unavailable"


def provider_command(
    profile: str, provider: str, command: list[str], draft: bool, apply: bool
) -> list[str]:
    binaries = {"google": "gws", "github": "gh"}
    expected = binaries.get(provider, provider)
    if Path(command[0]).name != expected:
        raise CredentialError(
            f"{profile} requires the {expected} CLI; arbitrary commands cannot bypass Switchboard"
        )
    args = [
        "switchboard",
        f"{provider}.cli.{'write' if draft or apply else 'read'}",
        "--ns",
        profile,
        "--json",
    ]
    if draft:
        args.append("--draft")
    if apply:
        args.append("--approve-and-apply")
    return [*args, "--", *command[1:]]


@dataclass(frozen=True)
class NativeResult:
    exit_code: int
    stdout: str
    stderr: str


def native_result(
    output: str, exit_code: int, draft: bool, applying: bool
) -> NativeResult:
    try:
        payload = json.loads(output)
    except ValueError:
        return NativeResult(
            70 if applying else 1,
            "",
            "Switchboard returned no valid result; command outcome is unavailable\n",
        )
    if not isinstance(payload, dict):
        return NativeResult(70 if applying else 1, "", "Invalid Switchboard result\n")
    if draft:
        return NativeResult(exit_code, json.dumps(payload) + "\n", "")
    if exit_code or payload.get("status") != "executed":
        failure = payload.get("failure") or {}
        uncertain = (
            isinstance(failure, dict) and failure.get("code") == "outcome_unknown"
        )
        return NativeResult(
            70 if uncertain or (applying and exit_code < 0) else exit_code or 1,
            "",
            json.dumps(payload) + "\n",
        )
    fields = payload.get("fields", {})
    if not isinstance(fields, dict):
        return NativeResult(
            70 if applying else 1, "", "Invalid Switchboard result fields\n"
        )
    stdout = ""
    if "response" in fields:
        stdout = json.dumps(fields["response"]) + "\n"
    elif "stdout_text" in fields:
        stdout = fields["stdout_text"]
    stderr = fields.get("cli_stderr", "")
    if not isinstance(stdout, str) or not isinstance(stderr, str):
        return NativeResult(
            70 if applying else 1, "", "Invalid Switchboard native output\n"
        )
    return NativeResult(0, stdout, stderr)


def run_provider(
    command: list[str], env: dict[str, str], draft: bool, applying: bool
) -> int:
    result = subprocess.run(
        command, env=env, text=True, capture_output=True, check=False
    )
    native = native_result(result.stdout, result.returncode, draft, applying)
    print(native.stdout, end="")
    print(native.stderr, end="", file=sys.stderr)
    return native.exit_code


def resolve(profile: str, spec: Profile, directory: Path) -> dict[str, str]:
    result = dict(spec.environment)
    deadline = time.monotonic() + 60
    for index, secret in enumerate(spec.secrets):
        cached = secret.cache_file
        value = ""
        if cached:
            path = Path(os.path.expandvars(cached)).expanduser()
            if path.exists():
                value = path.read_text()
        if not value:
            if not (secret.item and secret.account and secret.field):
                raise CredentialError(
                    f"Required credential file is unavailable for {profile}"
                )
            args = ["op", "--account", secret.account, "item", "get"]
            if secret.vault:
                args.extend(["--vault", secret.vault])
            args.extend([secret.item, "--fields", secret.field, "--reveal"])
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CredentialError(
                    f"Credential recovery exceeded 60 seconds for {profile}"
                )
            try:
                response = subprocess.run(
                    args, capture_output=True, text=True, timeout=remaining, check=False
                )
            except (OSError, subprocess.SubprocessError) as error:
                raise CredentialError(
                    f"Credential lookup unavailable or timed out for {profile}"
                ) from error
            if response.returncode:
                raise CredentialError(
                    f"Credential lookup failed for {profile} (exit {response.returncode}); command was not started"
                )
            value = response.stdout.rstrip("\n")
        if not value:
            raise CredentialError(
                f"Empty credential for {profile}; command was not started"
            )
        for name in secret.env:
            result[name] = value
        if secret.file_env:
            path = directory / f"credential-{index}"
            if secret.strip_quotes:
                value = value.strip('"')
            path.write_text(value)
            path.chmod(0o600)
            result[secret.file_env] = str(path)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--doctor",
        action="store_true",
        help="Report configuration and SSH socket health without reading credentials",
    )
    write_mode = parser.add_mutually_exclusive_group()
    write_mode.add_argument(
        "--draft",
        action="store_true",
        help="Prepare a configured provider write through Switchboard",
    )
    write_mode.add_argument(
        "--apply",
        action="store_true",
        help="Explicitly approve and execute the selected provider command through Switchboard",
    )
    parser.add_argument("profile", nargs="?")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        configured = namespaces()
        available = profiles()
        if args.doctor:
            _, status = ssh_socket()
            print(
                json.dumps(
                    {
                        "version": 1,
                        "namespaces": configured,
                        "profiles": sorted(available),
                        "ssh_agent": status,
                        "switchboard_available": shutil.which("switchboard")
                        is not None,
                    }
                )
            )
            return 0
        if not args.profile or not args.command:
            parser.error(
                "use PROFILE -- COMMAND [ARG ...]; bare fetch aliases no longer change the parent shell"
            )
        command = args.command[1:] if args.command[0] == "--" else args.command
        if not command:
            parser.error("a command is required after --")
        env = dict(os.environ)
        provider = configured.get(args.profile)
        if provider or args.profile == "ssh":
            if provider == "github" or args.profile == "ssh":
                path, status = ssh_socket(launch=True)
                if path is None:
                    raise CredentialError(
                        f"Configured SSH agent is unavailable ({status}); run with-credentials --doctor"
                    )
                env["SSH_AUTH_SOCK"] = path
            if provider:
                command = provider_command(
                    args.profile, provider, command, args.draft, args.apply
                )
                return run_provider(command, env, args.draft, args.apply)
            elif args.draft or args.apply:
                raise CredentialError(
                    "Write mode requires a configured Switchboard namespace"
                )
            return subprocess.run(command, env=env, check=False).returncode
        if "." in args.profile:
            raise CredentialError(
                f"Namespace {args.profile} is not configured in Switchboard"
            )
        if args.draft or args.apply:
            raise CredentialError(
                "Write mode requires a configured Switchboard namespace"
            )
        spec = available.get(args.profile)
        if spec is None:
            raise CredentialError(f"Unknown credential profile: {args.profile}")
        if spec.provider in configured.values():
            raise CredentialError(
                "This provider is configured in Switchboard; select its namespace instead"
            )
        # Resolve the entire set before starting the child; temporary files outlive
        # that child only, and secrets are never emitted as shell source or JSON.
        with tempfile.TemporaryDirectory(prefix="with-credentials-") as temporary:
            env.update(resolve(args.profile, spec, Path(temporary)))
            return subprocess.run(command, env=env, check=False).returncode
    except (CredentialError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"with-credentials: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    status = main()
    sys.exit(128 - status if status < 0 else status)
