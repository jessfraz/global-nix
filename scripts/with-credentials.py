#!/usr/bin/env python3
"""Run a command with credentials, or restore credentials through a shell helper."""

import argparse
import fcntl
import json
import math
import netrc
import os
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path


class CredentialError(Exception):
    pass


def environment_name(name: object) -> str:
    if (
        not isinstance(name, str)
        or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) is None
    ):
        raise CredentialError("Invalid credential environment variable name")
    return name


def credential_path(value: str) -> Path:
    return Path(
        os.path.expandvars(value.replace("$XDG_CONFIG_HOME", str(config_home())))
    ).expanduser()


def write_private(path: Path, value: str) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(value)
            output.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


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
    auth_profile: str | None
    item: str | None
    field: str | None
    vault: str | None
    file_env: str | None
    strip_quotes: bool
    shell_file: str | None
    url_label: str | None

    @classmethod
    def parse(cls, data: object) -> "Secret":
        if not isinstance(data, dict):
            raise CredentialError("Invalid credential source")
        env = data.get("env", [])
        if not isinstance(env, list) or any(not isinstance(name, str) for name in env):
            raise CredentialError("Credential env must be a list of variable names")
        result = cls(
            tuple(environment_name(name) for name in env),
            *(
                optional_string(data, key)
                for key in (
                    "cache_file",
                    "account",
                    "auth_profile",
                    "item",
                    "field",
                    "vault",
                    "file_env",
                )
            ),
            data.get("strip_quotes", False),
            optional_string(data, "shell_file"),
            optional_string(data, "url_label"),
        )
        if result.file_env:
            environment_name(result.file_env)
        if type(result.strip_quotes) is not bool:
            raise CredentialError("strip_quotes must be a boolean")
        if result.field and result.url_label:
            raise CredentialError("Select either a credential field or a URL label")
        if not result.cache_file and not result.item:
            raise CredentialError(
                "Credential requires a cache file or complete 1Password reference"
            )
        if result.item and not (
            (result.account or result.auth_profile)
            and (result.field or result.url_label)
        ):
            raise CredentialError("Incomplete 1Password reference")
        if result.auth_profile:
            if not result.vault or not result.item:
                raise CredentialError(
                    "Scoped credentials require an explicit vault and item"
                )
            if result.cache_file:
                raise CredentialError(
                    "Scoped credentials cannot use an unbound cache file"
                )
        return result

    def response_value(self, output: str) -> str:
        if self.url_label is None:
            return output.rstrip("\n")
        try:
            urls = json.loads(output)["urls"]
            matches = [
                url["href"] for url in urls if url.get("label") == self.url_label
            ]
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise CredentialError("Invalid 1Password URL response") from error
        if len(matches) != 1 or not isinstance(matches[0], str) or not matches[0]:
            raise CredentialError(
                "Expected one nonempty 1Password URL with the configured label"
            )
        return matches[0]


@dataclass(frozen=True)
class SlackOAuth:
    cache_file: str
    team_id: str
    user_id: str
    read_only: bool

    @classmethod
    def parse(cls, data: object) -> "SlackOAuth":
        if not isinstance(data, dict) or any(
            not isinstance(data.get(key), str) or not data[key]
            for key in ("cache_file", "team_id", "user_id")
        ):
            raise CredentialError(
                "Slack OAuth authorization requires cache and identity"
            )
        if type(data.get("read_only")) is not bool:
            raise CredentialError("Slack OAuth requires an explicit read_only policy")
        return cls(
            data["cache_file"], data["team_id"], data["user_id"], data["read_only"]
        )

    def validate(self, value: object) -> dict:
        if not isinstance(value, dict):
            raise CredentialError("Invalid Slack OAuth credential")
        if value.get("team_id") != self.team_id or value.get("user_id") != self.user_id:
            raise CredentialError(
                "Slack OAuth credential belongs to an unexpected identity"
            )
        for key in ("access_token", "client_id", "client_secret"):
            if (
                not isinstance(value.get(key), str)
                or not value[key]
                or any(c.isspace() or c == "\0" for c in value[key])
            ):
                raise CredentialError("Incomplete Slack OAuth credential")
        refresh = value.get("refresh_token")
        if refresh is not None and (
            not isinstance(refresh, str)
            or not refresh
            or any(c.isspace() or c == "\0" for c in refresh)
        ):
            raise CredentialError("Invalid Slack OAuth refresh credential")
        expiry = value.get("expires_at")
        if expiry is not None and (
            type(expiry) not in (int, float) or not math.isfinite(expiry) or expiry <= 0
        ):
            raise CredentialError("Invalid Slack OAuth credential expiry")
        scopes = value.get("scopes")
        if (
            not isinstance(scopes, list)
            or not scopes
            or any(
                not isinstance(scope, str)
                or not scope
                or any(c.isspace() or c == "\0" for c in scope)
                for scope in scopes
            )
        ):
            raise CredentialError("Slack OAuth credential has invalid scopes")
        if self.read_only and any(
            scope != "identify" and not scope.endswith((":read", ":history"))
            for scope in scopes
        ):
            raise CredentialError(
                "Slack OAuth credential violates the profile's read-only policy"
            )
        return value

    def refresh(self, credential: dict, timeout: float) -> dict:
        if not credential.get("refresh_token"):
            raise CredentialError(
                "Slack OAuth authorization expired; local recovery required"
            )
        request = urllib.request.Request(
            "https://slack.com/api/oauth.v2.access",
            data=urllib.parse.urlencode(
                {
                    "grant_type": "refresh_token",
                    "refresh_token": credential["refresh_token"],
                    "client_id": credential["client_id"],
                    "client_secret": credential["client_secret"],
                }
            ).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.load(response)
        if not isinstance(result, dict) or result.get("ok") is not True:
            code = result.get("error") if isinstance(result, dict) else None
            safe = (
                code
                if code
                in (
                    "invalid_refresh_token",
                    "token_revoked",
                    "invalid_client_id",
                    "bad_client_secret",
                    "invalid_grant",
                    "invalid_auth",
                    "account_inactive",
                )
                else "refresh_failed"
            )
            raise CredentialError(
                f"Slack OAuth refresh rejected ({safe}); local recovery required"
            )
        token = result.get("authed_user", result)
        if not isinstance(token, dict) or token.get("token_type", "user") != "user":
            raise CredentialError(
                "Slack OAuth refresh returned an unexpected token type"
            )
        if "team" in result and (
            not isinstance(result["team"], dict)
            or result["team"].get("id") != self.team_id
        ):
            raise CredentialError(
                "Slack OAuth refresh returned an unexpected workspace"
            )
        for source, key, expected in (
            (result, "team_id", self.team_id),
            (result, "user_id", self.user_id),
            (token, "id", self.user_id),
        ):
            if key in source and source[key] != expected:
                raise CredentialError(
                    "Slack OAuth refresh returned an unexpected identity"
                )
        duration = token.get("expires_in")
        if type(duration) is not int or duration <= 0 or not token.get("refresh_token"):
            raise CredentialError(
                "Slack OAuth refresh lacks replacement expiry or refresh token"
            )
        scope = token.get("scope")
        return self.validate(
            {
                **credential,
                "access_token": token.get("access_token"),
                "refresh_token": token["refresh_token"],
                "expires_at": time.time() + duration,
                "scopes": scope.split(",") if isinstance(scope, str) else None,
            }
        )

    def token(self) -> str:
        cache = credential_path(self.cache_file)
        try:
            directory = os.open(
                cache.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
            try:
                self.check_file(os.fstat(directory), 0o700, directory=True)
                descriptor = os.open(
                    ".refresh.lock",
                    os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
                    0o600,
                    dir_fd=directory,
                )
                with os.fdopen(descriptor, "r+") as lock:
                    self.check_file(os.fstat(lock.fileno()), 0o600)
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        raise CredentialError(
                            "Slack OAuth refresh is already in progress; try again after it finishes"
                        ) from None
                    # Single-use refresh tokens must be re-read under the lock.
                    descriptor = os.open(
                        cache.name,
                        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                        dir_fd=directory,
                    )
                    with os.fdopen(descriptor) as source:
                        self.check_file(os.fstat(source.fileno()), 0o600)
                        credential = self.validate(json.load(source))
                    if (
                        credential.get("expires_at") is not None
                        and credential["expires_at"] <= time.time() + 60
                    ):
                        credential = self.refresh(credential, 60)
                        temporary = ".credential-" + uuid.uuid4().hex
                        try:
                            descriptor = os.open(
                                temporary,
                                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                0o600,
                                dir_fd=directory,
                            )
                            with os.fdopen(descriptor, "w") as target:
                                os.fchmod(target.fileno(), 0o600)
                                json.dump(credential, target)
                                target.write("\n")
                                target.flush()
                                os.fsync(target.fileno())
                            os.replace(
                                temporary,
                                cache.name,
                                src_dir_fd=directory,
                                dst_dir_fd=directory,
                            )
                            os.fsync(directory)
                        finally:
                            try:
                                os.unlink(temporary, dir_fd=directory)
                            except FileNotFoundError:
                                pass
                    return credential["access_token"]
            finally:
                os.close(directory)
        except (OSError, ValueError, UnicodeError, OverflowError):
            raise CredentialError(
                "Slack OAuth authorization unavailable; check cache access or local recovery, not developer login"
            ) from None

    @staticmethod
    def check_file(info: os.stat_result, mode: int, *, directory: bool = False) -> None:
        valid = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
        if (
            not valid
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != mode
        ):
            raise CredentialError(
                "Slack OAuth cache must be owned, directory 0700 and files 0600"
            )


@dataclass(frozen=True)
class Profile:
    environment: dict[str, str]
    secrets: tuple[Secret, ...]
    provider: str | None
    unset: tuple[str, ...]
    github_username: str | None
    slack_oauth: SlackOAuth | None

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
        for name in environment:
            environment_name(name)
        unset = data.get("unset", [])
        if not isinstance(unset, list):
            raise CredentialError("Credential unset must be a list of variable names")
        slack = SlackOAuth.parse(data["slack_oauth"]) if "slack_oauth" in data else None
        if slack and (environment or secrets or data.get("provider") != "slack"):
            raise CredentialError(
                "Slack OAuth authorization cannot mix credential sources"
            )
        return cls(
            environment,
            tuple(Secret.parse(secret) for secret in secrets),
            optional_string(data, "provider"),
            tuple(environment_name(name) for name in unset),
            optional_string(data, "github_username"),
            slack,
        )


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def switchboard_config() -> Path:
    # Standalone fetch helpers need no Switchboard installation/config. Only
    # home/XDG is trusted, never CWD or SWITCHBOARD_CONFIG discovery overrides.
    path = config_home() / "switchboard/config.toml"
    if not path.is_absolute():
        raise CredentialError("Switchboard config home must be an absolute path")
    return path


def namespaces(path: Path) -> dict[str, str]:
    try:
        path.lstat()
    except FileNotFoundError:
        return {}
    except OSError as error:
        raise CredentialError("Switchboard configuration is unavailable") from error
    try:
        response = subprocess.run(
            ["switchboard", "--config", str(path), "ns", "list", "--json"],
            env=child_environment(),
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise CredentialError(
            "Switchboard namespace discovery is unavailable"
        ) from error
    if response.returncode:
        raise CredentialError("Switchboard namespace discovery failed")
    try:
        payload = json.loads(response.stdout)
    except ValueError as error:
        raise CredentialError(
            "Invalid Switchboard namespace discovery response"
        ) from error
    if (
        not isinstance(payload, dict)
        or type(payload.get("schema_version")) is not int
        or payload["schema_version"] != 1
        or not isinstance(payload.get("namespaces"), list)
    ):
        raise CredentialError("Invalid Switchboard namespace discovery response")
    result: dict[str, str] = {}
    for namespace in payload["namespaces"]:
        if not isinstance(namespace, dict):
            raise CredentialError("Invalid Switchboard namespace discovery response")
        name, provider = namespace.get("id"), namespace.get("provider")
        if (
            not isinstance(name, str)
            or not name
            or not isinstance(provider, str)
            or not provider
            or name in result
        ):
            raise CredentialError("Invalid Switchboard namespace discovery response")
        result[name] = provider
    return result


def profiles() -> dict[str, Profile]:
    path = config_home() / "with-credentials/profiles.json"
    if not path.exists():
        return {}
    result = json.loads(path.read_text())
    if not isinstance(result, dict):
        raise CredentialError("Invalid credential profiles")
    return {name: Profile.parse(profile) for name, profile in result.items()}


@dataclass(frozen=True)
class AuthProfile:
    token_file: Path

    @classmethod
    def load(cls, name: str) -> "AuthProfile":
        path = config_home() / "with-credentials/auth-profiles.json"
        try:
            configured = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            raise CredentialError(
                "Scoped authentication configuration is unavailable"
            ) from error
        if not isinstance(configured, dict) or not isinstance(
            configured.get(name), dict
        ):
            raise CredentialError(f"Unknown authentication profile: {name}")
        token_file = optional_string(configured[name], "token_file")
        if not token_file:
            raise CredentialError(
                f"Authentication profile {name} requires a token file"
            )
        path = credential_path(token_file)
        if not path.is_absolute():
            raise CredentialError("Bootstrap token paths must be absolute")
        return cls(path)

    def token(self) -> str:
        """Read a private runtime file without following a symlink or entering a TTY."""
        try:
            directory_fd = os.open(
                self.token_file.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
            try:
                directory = os.fstat(directory_fd)
                if directory.st_uid != os.getuid() or directory.st_mode & 0o077:
                    raise CredentialError(
                        "Bootstrap token directory must be owned and private"
                    )
                descriptor = os.open(
                    self.token_file.name,
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=directory_fd,
                )
                with os.fdopen(descriptor, encoding="utf-8") as source:
                    metadata = os.fstat(source.fileno())
                    if (
                        not stat.S_ISREG(metadata.st_mode)
                        or metadata.st_uid != os.getuid()
                        or metadata.st_mode & 0o077
                    ):
                        raise CredentialError(
                            "Bootstrap token file must be owned, regular and private"
                        )
                    value = source.read(16385).rstrip("\r\n")
            finally:
                os.close(directory_fd)
        except (OSError, UnicodeError) as error:
            raise CredentialError(
                "Bootstrap token file is unavailable; desktop fallback is disabled"
            ) from error
        if (
            not value
            or len(value) > 16384
            or any(char.isspace() or char == "\0" for char in value)
        ):
            raise CredentialError("Bootstrap token file is empty or invalid")
        return value


def child_environment() -> dict[str, str]:
    # Vault authentication belongs to the lookup process, never its consumer.
    return {
        name: value for name, value in os.environ.items() if not name.startswith("OP_")
    }


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
    profile: str,
    provider: str,
    command: list[str],
    draft: bool,
    apply: bool,
    config: Path,
) -> list[str]:
    binaries = {"google": "gws", "github": "gh"}
    expected = binaries.get(provider, provider)
    if Path(command[0]).name != expected:
        raise CredentialError(
            f"{profile} requires the {expected} CLI; arbitrary commands cannot bypass Switchboard"
        )
    args = [
        "switchboard",
        "--config",
        str(config),
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


def selected_field_values(output: str, selectors: list[str]) -> dict[str, str]:
    try:
        fields = json.loads(output)
    except ValueError as error:
        raise CredentialError("Invalid 1Password selected-field response") from error
    if not isinstance(fields, list) or any(
        not isinstance(field, dict) for field in fields
    ):
        raise CredentialError("Invalid 1Password selected-field response")
    values = {}
    for selector in selectors:
        label_only = selector.startswith("label=")
        name = selector.removeprefix("label=")
        matches = [
            field
            for field in fields
            if field.get("label") == name
            or (not label_only and field.get("id") == name)
        ]
        if len(matches) != 1 or not isinstance(matches[0].get("value"), str):
            raise CredentialError(
                "Expected one 1Password value for each selected field"
            )
        values[selector] = matches[0]["value"].rstrip("\n")
    return values


def resolve(
    profile: str, spec: Profile, directory: Path, *, shell: bool = False
) -> dict[str, str]:
    if spec.slack_oauth:
        if shell:
            raise CredentialError(
                "Slack OAuth authorization is child-only; use PROFILE -- COMMAND"
            )
        return {"SLACK_USER_TOKEN": spec.slack_oauth.token()}
    result = dict(spec.environment)
    deadline = time.monotonic() + 60
    resolved: list[tuple[Secret, str]] = []
    pending: dict[tuple[str | None, ...], list[int]] = {}
    auth_tokens: dict[str, str] = {}
    for index, secret in enumerate(spec.secrets):
        cached = secret.cache_file
        value = ""
        if cached:
            path = credential_path(cached)
            if path.exists():
                value = path.read_text()
        if "\0" in value:
            raise CredentialError(f"Credential for {profile} contains a NUL byte")
        if not value:
            if not secret.item:
                raise CredentialError(
                    f"Required credential file is unavailable for {profile}"
                )
            # Keep complex op selectors on their existing path. Only combine
            # individual field IDs/labels, never broaden a read to the full item.
            selection = secret.field
            if selection and re.fullmatch(r"(?:label=)?[\w -]+", selection):
                selection = None
            key = (
                secret.account,
                secret.auth_profile,
                secret.vault,
                secret.item,
                selection,
                secret.url_label,
            )
            pending.setdefault(key, []).append(index)
        resolved.append((secret, value))
    for indices in pending.values():
        secret = spec.secrets[indices[0]]
        fields = list(
            dict.fromkeys(
                spec.secrets[index].field
                for index in indices
                if spec.secrets[index].field is not None
            )
        )
        if secret.auth_profile:
            if secret.auth_profile not in auth_tokens:
                auth_tokens[secret.auth_profile] = AuthProfile.load(
                    secret.auth_profile
                ).token()
            lookup_env = child_environment()
            lookup_env["OP_SERVICE_ACCOUNT_TOKEN"] = auth_tokens[secret.auth_profile]
            lookup_env["OP_BIOMETRIC_UNLOCK_ENABLED"] = "false"
            args = ["op", "item", "get"]
        else:
            lookup_env = dict(os.environ)
            for name in (
                "OP_SERVICE_ACCOUNT_TOKEN",
                "OP_CONNECT_HOST",
                "OP_CONNECT_TOKEN",
            ):
                lookup_env.pop(name, None)
            args = ["op", "--account", secret.account, "item", "get"]
        if secret.vault:
            args.extend(["--vault", secret.vault])
        args.append(secret.item)
        if secret.url_label is not None:
            args.extend(["--format", "json"])
        elif len(fields) > 1:
            args.extend(["--fields", ",".join(fields), "--format", "json", "--reveal"])
        else:
            args.extend(["--fields", secret.field, "--reveal"])
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CredentialError(
                f"Credential recovery exceeded 60 seconds for {profile}"
            )
        try:
            # Closing stdin alone still lets op prompt through /dev/tty.
            response = subprocess.run(
                args,
                env=lookup_env,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                capture_output=True,
                text=True,
                timeout=remaining,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise CredentialError(
                f"Credential lookup unavailable or timed out for {profile}"
            ) from error
        if response.returncode:
            raise CredentialError(
                f"Credential lookup failed for {profile} (exit {response.returncode}); command was not started"
            )
        if len(fields) > 1:
            values = selected_field_values(response.stdout, fields)
        else:
            values = {secret.field: secret.response_value(response.stdout)}
        for index in indices:
            selected = spec.secrets[index]
            value = values[selected.field]
            if not value:
                raise CredentialError(
                    f"Empty credential for {profile}; command was not started"
                )
            if "\0" in value:
                raise CredentialError(f"Credential for {profile} contains a NUL byte")
            resolved[index] = (selected, value)
    for index, (secret, value) in enumerate(resolved):
        if secret.cache_file:
            path = credential_path(secret.cache_file)
            if not path.exists() or not path.stat().st_size:
                write_private(path, value)
        for name in secret.env:
            result[name] = value
        if secret.file_env:
            path = (
                credential_path(secret.shell_file)
                if shell and secret.shell_file
                else directory / f"credential-{index}"
            )
            if secret.strip_quotes:
                value = "\n".join(
                    line.removeprefix('"').removesuffix('"')
                    for line in value.splitlines()
                )
            write_private(path, value)
            result[secret.file_env] = str(path)
    return result


def github_token_files(username: str, token: str) -> None:
    """Preserve the legacy GitHub consumers without overwriting unrelated entries."""
    path = Path.home() / ".netrc"
    entries = netrc.netrc(str(path)) if path.exists() else None
    hosts = entries.hosts if entries else {}
    macros = entries.macros if entries else {}
    for host in ("github.com", "api.github.com"):
        hosts[host] = (username, None, token)
    # curl uses the first matching entry, including default.
    if "default" in hosts:
        hosts["default"] = hosts.pop("default")

    def quote(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    lines = []
    for host, (login, account, password) in hosts.items():
        lines.append("default" if host == "default" else f"machine {quote(host)}")
        for key, value in (
            ("login", login),
            ("account", account),
            ("password", password),
        ):
            if value:
                lines.append(f"  {key} {quote(value)}")
    for name, body in macros.items():
        lines.extend([f"macdef {name}", "".join(body).rstrip("\n"), ""])
    write_private(path, "\n".join(lines) + "\n")

    path = config_home() / "nix/nix.conf"
    lines = path.read_text().splitlines() if path.exists() else []
    found = False
    for index, line in enumerate(lines):
        setting, separator, value = line.partition("=")
        if separator and setting.strip() == "access-tokens":
            tokens, comment, suffix = value.partition("#")
            remaining = [
                entry for entry in tokens.split() if not entry.startswith("github.com=")
            ]
            lines[index] = "access-tokens = " + " ".join(
                [*remaining, f"github.com={token}"]
            )
            if comment:
                lines[index] += f" #{suffix}"
            found = True
    if not found:
        lines.append(f"access-tokens = github.com={token}")
    write_private(path, "\n".join(lines) + "\n")


def shell_exports(profile: str, spec: Profile) -> str:
    directory = config_home() / "with-credentials/files" / profile
    values = resolve(profile, spec, directory, shell=True)
    if spec.github_username:
        token = values.get("GITHUB_TOKEN", "")
        if not token or any(character.isspace() for character in token):
            raise CredentialError("Invalid GitHub token for legacy credential files")
        try:
            github_token_files(spec.github_username, token)
        except netrc.NetrcParseError as error:
            raise CredentialError("Cannot update malformed .netrc") from error
    assignments = [f"unset {name}" for name in spec.unset]
    assignments.extend(
        f"export {name}={shlex.quote(value)}" for name, value in values.items()
    )
    return "\n".join(assignments)


def run_child(command: list[str], env: dict[str, str]) -> int:
    def terminated(signum: int, _frame: object) -> None:
        raise SystemExit(128 + signum)

    # The credential-bearing child owns a session, including any helpers it
    # starts. Cancel the whole group and reap before deleting temporary files.
    previous = signal.signal(signal.SIGTERM, terminated)
    try:
        with subprocess.Popen(command, env=env, start_new_session=True) as child:
            try:
                return child.wait()
            except BaseException:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
                raise
    finally:
        signal.signal(signal.SIGTERM, previous)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--doctor",
        action="store_true",
        help="Report configuration and SSH socket health without reading credentials",
    )
    shell_mode = parser.add_mutually_exclusive_group()
    shell_mode.add_argument(
        "--shell",
        action="store_true",
        help="Emit quoted assignments for the fetch shell functions",
    )
    shell_mode.add_argument(
        "--accounts",
        action="store_true",
        help="List accounts needed by an uncached shell credential",
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
        config = switchboard_config()
        configured = namespaces(config)
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
        if args.shell or args.accounts:
            if not args.profile or args.command or args.draft or args.apply:
                parser.error(
                    "use --shell PROFILE or --accounts PROFILE without a command or write mode"
                )
            spec = available.get(args.profile)
            if spec is None:
                raise CredentialError(f"Unknown credential profile: {args.profile}")
            if spec.slack_oauth:
                raise CredentialError(
                    "Slack OAuth authorization is child-only; use PROFILE -- COMMAND"
                )
            if args.accounts:
                accounts = {
                    secret.account
                    for secret in spec.secrets
                    if secret.account
                    and not secret.auth_profile
                    and not (
                        secret.cache_file
                        and credential_path(secret.cache_file).is_file()
                        and credential_path(secret.cache_file).stat().st_size
                    )
                }
                print("\n".join(sorted(accounts)))
            else:
                print(shell_exports(args.profile, spec))
            return 0
        if not args.profile or not args.command:
            parser.error(
                "use PROFILE -- COMMAND [ARG ...]; for bare fetch helpers, source ~/.config/with-credentials/shell.sh"
            )
        command = args.command[1:] if args.command[0] == "--" else args.command
        if not command:
            parser.error("a command is required after --")
        env = child_environment()
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
                    args.profile, provider, command, args.draft, args.apply, config
                )
                return run_provider(command, env, args.draft, args.apply)
            elif args.draft or args.apply:
                raise CredentialError(
                    "Write mode requires a configured Switchboard namespace"
                )
            return run_child(command, env)
        spec = available.get(args.profile)
        if "." in args.profile and (spec is None or spec.slack_oauth is None):
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
        # that child only. Shell exports require the explicit shell-helper mode.
        with tempfile.TemporaryDirectory(prefix="with-credentials-") as temporary:
            for name in spec.unset:
                env.pop(name, None)
            if spec.slack_oauth:
                env = {
                    name: value
                    for name, value in env.items()
                    if not name.startswith("SLACK_")
                }
            env.update(resolve(args.profile, spec, Path(temporary)))
            return run_child(command, env)
    except (CredentialError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"with-credentials: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    status = main()
    sys.exit(128 - status if status < 0 else status)
