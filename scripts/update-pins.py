#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from shutil import which
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import tomllib

REPO_ROOT = Path(__file__).resolve().parents[1]
FLAKE_PATH = REPO_ROOT / "flake.nix"
FLAKE_LOCK_PATH = REPO_ROOT / "flake.lock"
KICAD_BIN_PATH = REPO_ROOT / "pkgs" / "kicad-bin.nix"
MOLE_PATH = REPO_ROOT / "pkgs" / "mole.nix"
RAMP_CLI_PATH = REPO_ROOT / "pkgs" / "ramp-cli.nix"


class UpdateError(RuntimeError):
    pass


@dataclass(frozen=True)
class CargoGitDependency:
    package_key: str
    url: str
    revision: str


def run(
    cmd: Sequence[str],
    check: bool = True,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=True,
        cwd=cwd,
    )


def replace_one(pattern: str, repl: str, text: str, label: str) -> str:
    updated, count = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if count != 1:
        raise UpdateError(f"Expected 1 match for {label}, found {count}.")
    return updated


def get_tags(repo_url: str) -> list[str]:
    result = run(["git", "ls-remote", "--tags", "--refs", repo_url])
    tags: list[str] = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        ref = parts[1]
        if ref.startswith("refs/tags/"):
            tags.append(ref[len("refs/tags/") :])
    if not tags:
        raise UpdateError(f"No tags found for {repo_url}.")
    return tags


def get_latest_github_release(repository: str) -> str:
    request = Request(
        f"https://api.github.com/repos/{repository}/releases/latest",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "global-nix-update-pins",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise UpdateError(
            f"Could not read the latest GitHub release for {repository}: {exc}"
        ) from exc

    if not isinstance(payload, dict):
        raise UpdateError(f"Invalid GitHub release response for {repository}.")
    tag_name = payload.get("tag_name")
    if not isinstance(tag_name, str) or not tag_name:
        raise UpdateError(f"GitHub returned no latest release tag for {repository}.")
    return tag_name


def version_key(tag: str) -> tuple[int, int, int, str]:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", tag)
    if not match:
        return (-1, -1, -1, tag)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)), tag)


def select_latest_tag(tags: Iterable[str], preferred_prefixes: Sequence[str]) -> str:
    tags_list = list(tags)
    if preferred_prefixes:
        preferred = [
            tag
            for tag in tags_list
            if any(tag.startswith(prefix) for prefix in preferred_prefixes)
        ]
        if preferred:
            tags_list = preferred
    stable = [tag for tag in tags_list if re.search(r"\d+\.\d+\.\d+$", tag)]
    if stable:
        tags_list = stable
    tags_list.sort(key=version_key)
    return tags_list[-1]


def prefetch_sri(url: str, *, unpack: bool = True) -> str:
    if which("nix"):
        command = ["nix", "store", "prefetch-file", "--json"]
        if unpack:
            command.append("--unpack")
        command.append(url)
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return data["hash"]
    if which("nix-prefetch-url"):
        command = ["nix-prefetch-url"]
        if unpack:
            command.append("--unpack")
        command.append(url)
        hash_result = run(command)
        base32_hash = hash_result.stdout.strip()
        sri_result = run(["nix", "hash", "to-sri", "--type", "sha256", base32_hash])
        return sri_result.stdout.strip()
    raise UpdateError("nix or nix-prefetch-url is required to compute source hashes.")


def codex_git_dependencies(lock_text: str) -> list[CargoGitDependency]:
    lock = tomllib.loads(lock_text)
    packages = lock.get("package")
    if not isinstance(packages, list):
        raise UpdateError("Codex Cargo.lock has no package list.")

    dependencies_by_revision: dict[str, CargoGitDependency] = {}
    for package in packages:
        if not isinstance(package, dict):
            raise UpdateError("Codex Cargo.lock contains an invalid package entry.")

        source = package.get("source")
        if not isinstance(source, str) or not source.startswith("git+"):
            continue

        location, separator, revision = source[4:].rpartition("#")
        if not separator or not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise UpdateError(f"Unsupported Codex Cargo git source: {source}")

        url = location.partition("?")[0]
        name = package.get("name")
        version = package.get("version")
        if not url or not isinstance(name, str) or not isinstance(version, str):
            raise UpdateError(f"Invalid Codex Cargo git package: {package}")

        dependency = CargoGitDependency(
            package_key=f"{name}-{version}",
            url=url,
            revision=revision,
        )
        existing = dependencies_by_revision.get(revision)
        if existing is not None and existing.url != dependency.url:
            raise UpdateError(
                f"Codex Cargo.lock uses revision {revision} from multiple repositories."
            )
        if existing is None or dependency.package_key < existing.package_key:
            dependencies_by_revision[revision] = dependency

    return sorted(dependencies_by_revision.values(), key=lambda item: item.package_key)


def prefetch_git_sri(dependency: CargoGitDependency) -> str:
    expression = (
        "builtins.fetchGit { "
        f"url = {json.dumps(dependency.url)}; "
        f"rev = {json.dumps(dependency.revision)}; "
        "allRefs = true; submodules = true; }"
    )
    store_path = run(
        ["nix", "eval", "--impure", "--raw", "--expr", expression]
    ).stdout.strip()
    if not store_path:
        raise UpdateError(f"Nix returned no source path for {dependency.package_key}.")
    return run(["nix", "hash", "path", store_path]).stdout.strip()


def replace_codex_output_hashes(
    flake_text: str, output_hashes: Mapping[str, str]
) -> str:
    entries = "".join(
        f'            "{package_key}" = "{output_hashes[package_key]}";\n'
        for package_key in sorted(output_hashes)
    )
    return replace_one(
        (
            r"(^ {10}outputHashes = \{\n)"
            r'(?:^ {12}"[^\"]+" = "[^\"]+";\n)*'
            r"(^ {10}\};)"
        ),
        rf"\g<1>{entries}\g<2>",
        flake_text,
        "Codex Cargo outputHashes",
    )


def validate_cargo_vendor(package_expr: str, package_name: str) -> None:
    build_command = [
        "nix",
        "build",
        "--impure",
        "--expr",
        f"({package_expr}).cargoDeps",
        "--no-link",
    ]

    for command, label in (
        (build_command, "build"),
        ([*build_command, "--rebuild"], "reproducibility validation"),
    ):
        print(f"{package_name} Cargo vendor {label}", flush=True)
        vendor = run(command, check=False, cwd=REPO_ROOT)
        if vendor.returncode != 0:
            detail = vendor.stderr.strip().splitlines()
            message = detail[-1] if detail else "unknown Nix build failure"
            raise UpdateError(f"{package_name} Cargo vendor {label} failed: {message}")


def update_codex() -> None:
    if not which("nix"):
        raise UpdateError("nix is required to update Codex.")

    tags = get_tags("https://github.com/openai/codex.git")
    latest_tag = select_latest_tag(tags, preferred_prefixes=("rust-v",))
    original_flake = FLAKE_PATH.read_text(encoding="utf-8")
    original_lock = FLAKE_LOCK_PATH.read_text(encoding="utf-8")
    tag_changed = f"ref=refs/tags/{latest_tag}" not in original_flake
    succeeded = False
    try:
        if tag_changed:
            updated = replace_one(
                (
                    r"(git\+https://github\.com/openai/codex\?"
                    r"ref=refs/tags/)([^&\"]+)([^\"]*)"
                ),
                rf"\g<1>{latest_tag}\g<3>",
                original_flake,
                "codex tag",
            )
            FLAKE_PATH.write_text(updated, encoding="utf-8")
            run(
                [
                    "nix",
                    "flake",
                    "update",
                    "codex",
                    "--option",
                    "warn-dirty",
                    "false",
                ],
                cwd=REPO_ROOT,
            )

        codex_path = run(
            [
                "nix",
                "eval",
                "--impure",
                "--raw",
                "--expr",
                (
                    "let flake = builtins.getFlake (toString ./.); "
                    "in flake.inputs.codex.outPath"
                ),
            ],
            cwd=REPO_ROOT,
        ).stdout.strip()
        cargo_lock_path = Path(codex_path) / "codex-rs" / "Cargo.lock"
        if not cargo_lock_path.is_file():
            raise UpdateError(f"Codex Cargo.lock not found at {cargo_lock_path}.")

        output_hashes: dict[str, str] = {}
        for dependency in codex_git_dependencies(
            cargo_lock_path.read_text(encoding="utf-8")
        ):
            print(f"codex Cargo git -> {dependency.package_key}", flush=True)
            output_hashes[dependency.package_key] = prefetch_git_sri(dependency)

        flake_text = FLAKE_PATH.read_text(encoding="utf-8")
        updated = replace_codex_output_hashes(flake_text, output_hashes)
        hashes_changed = updated != flake_text
        if hashes_changed:
            FLAKE_PATH.write_text(updated, encoding="utf-8")

        if tag_changed or hashes_changed:
            package_expr = (
                "let flake = builtins.getFlake (toString ./.); "
                "in flake.packages.${builtins.currentSystem}.codex"
            )
            validate_cargo_vendor(package_expr, "Codex")
        succeeded = True
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "unknown Nix command failure").strip()
        raise UpdateError(f"Failed to update Codex: {detail}") from exc
    finally:
        if not succeeded:
            FLAKE_PATH.write_text(original_flake, encoding="utf-8")
            FLAKE_LOCK_PATH.write_text(original_lock, encoding="utf-8")

    if tag_changed:
        print(f"codex -> {latest_tag}")
    else:
        print(f"codex already at {latest_tag}")


def update_zoo() -> None:
    if not which("nix"):
        raise UpdateError("nix is required to update the Zoo flake input.")

    original_lock = FLAKE_LOCK_PATH.read_text(encoding="utf-8")
    succeeded = False
    try:
        try:
            run(
                [
                    "nix",
                    "flake",
                    "update",
                    "zoo-cli",
                    "--option",
                    "warn-dirty",
                    "false",
                ],
                cwd=REPO_ROOT,
            )

            package_expr = (
                "let flake = builtins.getFlake (toString ./.); "
                "in flake.inputs.zoo-cli.packages.${builtins.currentSystem}.zoo"
            )
            lock_changed = FLAKE_LOCK_PATH.read_text(encoding="utf-8") != original_lock
            if lock_changed:
                validate_cargo_vendor(package_expr, "Zoo")

            version = run(
                [
                    "nix",
                    "eval",
                    "--impure",
                    "--raw",
                    "--expr",
                    f"({package_expr}).version",
                ],
                cwd=REPO_ROOT,
            ).stdout.strip()
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "unknown Nix command failure").strip()
            raise UpdateError(
                f"Failed to update the Zoo flake input: {detail}"
            ) from exc
        succeeded = True
    finally:
        if not succeeded:
            FLAKE_LOCK_PATH.write_text(original_lock, encoding="utf-8")

    if lock_changed:
        print(f"zoo -> {version}")
    else:
        print(f"zoo already at {version}")


def update_kicad() -> None:
    latest_tag = get_latest_github_release("KiCad/kicad-source-mirror")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", latest_tag):
        raise UpdateError(f"Unexpected KiCad release tag: {latest_tag}")

    original_text = KICAD_BIN_PATH.read_text(encoding="utf-8")
    version_match = re.search(r'^\s*version = "([^"]+)";', original_text, re.MULTILINE)
    if not version_match:
        raise UpdateError("Could not find KiCad version in pkgs/kicad-bin.nix")

    current_version = version_match.group(1)
    if current_version == latest_tag:
        print(f"kicad already at {latest_tag}")
        return

    src_url = (
        "https://github.com/KiCad/kicad-source-mirror/releases/download/"
        f"{latest_tag}/kicad-unified-universal-{latest_tag}.dmg"
    )
    src_hash = prefetch_sri(src_url, unpack=False)

    updated = replace_one(
        r'^(\s*version = ")[^"]+(";)',
        rf"\g<1>{latest_tag}\g<2>",
        original_text,
        "KiCad version",
    )
    updated = replace_one(
        r'^(\s*hash = ")[^"]+(";)',
        rf"\g<1>{src_hash}\g<2>",
        updated,
        "KiCad hash",
    )

    KICAD_BIN_PATH.write_text(updated, encoding="utf-8")
    print(f"kicad -> {latest_tag}")


def update_mole() -> None:
    tags = get_tags("https://github.com/tw93/Mole.git")
    latest_tag = select_latest_tag(tags, preferred_prefixes=("V", "v"))
    if not latest_tag:
        raise UpdateError("No Mole tags found.")

    version = latest_tag.lstrip("vV")
    original_text = MOLE_PATH.read_text(encoding="utf-8")

    version_match = re.search(r'^\s*version = "([^"]+)";', original_text, re.MULTILINE)
    if not version_match:
        raise UpdateError("Could not find Mole version in pkgs/mole.nix")

    current_version = version_match.group(1)
    if current_version == version:
        print(f"mole already at {version}")
        return

    src_url = f"https://github.com/tw93/Mole/archive/refs/tags/{latest_tag}.tar.gz"
    binaries_arm_url = (
        "https://github.com/tw93/Mole/releases/download/"
        f"{latest_tag}/binaries-darwin-arm64.tar.gz"
    )
    binaries_amd_url = (
        "https://github.com/tw93/Mole/releases/download/"
        f"{latest_tag}/binaries-darwin-amd64.tar.gz"
    )

    src_hash = prefetch_sri(src_url)
    binaries_hash_arm = prefetch_sri(binaries_arm_url)
    binaries_hash_amd = prefetch_sri(binaries_amd_url)

    updated = replace_one(
        r'^(\s*version = ")[^"]+(";)',
        rf"\g<1>{version}\g<2>",
        original_text,
        "mole version",
    )
    updated = replace_one(
        r'^(\s*srcHash = ")[^"]+(";)',
        rf"\g<1>{src_hash}\g<2>",
        updated,
        "mole srcHash",
    )
    updated = replace_one(
        r'^(\s*binariesHashArm64 = ")[^"]+(";)',
        rf"\g<1>{binaries_hash_arm}\g<2>",
        updated,
        "mole binariesHashArm64",
    )
    updated = replace_one(
        r'^(\s*binariesHashAmd64 = ")[^"]+(";)',
        rf"\g<1>{binaries_hash_amd}\g<2>",
        updated,
        "mole binariesHashAmd64",
    )

    MOLE_PATH.write_text(updated, encoding="utf-8")
    print(f"mole -> {version}")


def update_ramp() -> None:
    tags = get_tags("https://github.com/ramp-public/ramp-cli.git")
    latest_tag = select_latest_tag(tags, preferred_prefixes=("v",))
    if not latest_tag.startswith("v"):
        raise UpdateError(f"Unexpected Ramp tag format: {latest_tag}")

    version = latest_tag[1:]
    original_text = RAMP_CLI_PATH.read_text(encoding="utf-8")

    version_match = re.search(r'^\s*version = "([^"]+)";', original_text, re.MULTILINE)
    if not version_match:
        raise UpdateError("Could not find Ramp CLI version in pkgs/ramp-cli.nix")

    current_version = version_match.group(1)
    if current_version == version:
        print(f"ramp already at {version}")
        return

    src_url = (
        f"https://github.com/ramp-public/ramp-cli/archive/refs/tags/{latest_tag}.tar.gz"
    )
    src_hash = prefetch_sri(src_url)

    updated = replace_one(
        r'^(\s*version = ")[^"]+(";)',
        rf"\g<1>{version}\g<2>",
        original_text,
        "ramp version",
    )
    updated = replace_one(
        r'^(\s*hash = ")[^"]+(";)',
        rf"\g<1>{src_hash}\g<2>",
        updated,
        "ramp hash",
    )

    RAMP_CLI_PATH.write_text(updated, encoding="utf-8")
    print(f"ramp -> {version}")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update pinned tags and hashes.")
    parser.add_argument(
        "targets",
        nargs="+",
        choices=[
            "codex",
            "kicad",
            "mole",
            "ramp",
            "zoo",
            "all",
        ],
        help="Targets to update.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    targets = set(args.targets)
    if "all" in targets:
        targets = {
            "codex",
            "kicad",
            "mole",
            "ramp",
            "zoo",
        }

    try:
        if "codex" in targets:
            update_codex()
        if "kicad" in targets:
            update_kicad()
        if "mole" in targets:
            update_mole()
        if "ramp" in targets:
            update_ramp()
        if "zoo" in targets:
            update_zoo()
    except UpdateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
