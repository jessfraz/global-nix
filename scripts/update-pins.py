#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterable, Sequence
from pathlib import Path
from shutil import which

REPO_ROOT = Path(__file__).resolve().parents[1]
FLAKE_PATH = REPO_ROOT / "flake.nix"
FLAKE_LOCK_PATH = REPO_ROOT / "flake.lock"
KICAD_BIN_PATH = REPO_ROOT / "pkgs" / "kicad-bin.nix"
MOLE_PATH = REPO_ROOT / "pkgs" / "mole.nix"
ORCA_SLICER_BIN_PATH = REPO_ROOT / "pkgs" / "orca-slicer-bin.nix"
RAMP_CLI_PATH = REPO_ROOT / "pkgs" / "ramp-cli.nix"
CODEX_PATH = REPO_ROOT / "pkgs" / "codex.nix"


class UpdateError(RuntimeError):
    pass


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
    command = ["gh", "api", f"repos/{repository}/releases/latest"]
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        command = ["with-credentials", "github.personal", "--", *command]
    try:
        result = subprocess.run(
            command,
            check=True,
            text=True,
            capture_output=True,
            timeout=30,
        )
        payload = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
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

    latest_tag = get_latest_github_release("openai/codex")
    if not re.fullmatch(r"rust-v\d+\.\d+\.\d+", latest_tag):
        raise UpdateError(f"Unexpected Codex release tag: {latest_tag}")
    original_flake = FLAKE_PATH.read_text(encoding="utf-8")
    original_lock = FLAKE_LOCK_PATH.read_text(encoding="utf-8")
    original_package = CODEX_PATH.read_text(encoding="utf-8")
    if f'github:openai/codex/{latest_tag}"' in original_flake:
        print(f"codex already at {latest_tag}")
        return

    succeeded = False
    try:
        updated_package = original_package
        for system, target in (
            ("aarch64-darwin", "aarch64-apple-darwin"),
            ("x86_64-linux", "x86_64-unknown-linux-musl"),
        ):
            url = (
                f"https://github.com/openai/codex/releases/download/{latest_tag}/"
                f"codex-package-{target}.tar.gz"
            )
            archive_hash = prefetch_sri(url, unpack=False)
            updated_package = replace_one(
                rf'({re.escape(system)} = \{{\n\s+target = "{re.escape(target)}";\n\s+hash = ")[^"]+(";)',
                rf"\g<1>{archive_hash}\g<2>",
                updated_package,
                f"Codex {system} archive hash",
            )
        updated_flake = replace_one(
            r'(url = "github:openai/codex/)[^"]+(";)',
            rf"\g<1>{latest_tag}\g<2>",
            original_flake,
            "Codex tag",
        )
        CODEX_PATH.write_text(updated_package, encoding="utf-8")
        FLAKE_PATH.write_text(updated_flake, encoding="utf-8")
        run(
            ["nix", "flake", "update", "codex", "--option", "warn-dirty", "false"],
            cwd=REPO_ROOT,
        )
        succeeded = True
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "unknown Nix command failure").strip()
        raise UpdateError(f"Failed to update Codex: {detail}") from exc
    finally:
        if not succeeded:
            FLAKE_PATH.write_text(original_flake, encoding="utf-8")
            FLAKE_LOCK_PATH.write_text(original_lock, encoding="utf-8")
            CODEX_PATH.write_text(original_package, encoding="utf-8")
    print(f"codex -> {latest_tag}")


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
                    "rust-overlay",
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


def update_orcaslicer() -> None:
    latest_tag = get_latest_github_release("OrcaSlicer/OrcaSlicer")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", latest_tag):
        raise UpdateError(f"Unexpected OrcaSlicer release tag: {latest_tag}")

    version = latest_tag[1:]
    original_text = ORCA_SLICER_BIN_PATH.read_text(encoding="utf-8")
    version_match = re.search(r'^\s*version = "([^"]+)";', original_text, re.MULTILINE)
    if not version_match:
        raise UpdateError(
            "Could not find OrcaSlicer version in pkgs/orca-slicer-bin.nix"
        )

    if version_match.group(1) == version:
        print(f"orcaslicer already at {version}")
        return

    src_url = (
        "https://github.com/OrcaSlicer/OrcaSlicer/releases/download/"
        f"{latest_tag}/OrcaSlicer_Mac_universal_V{version}.dmg"
    )
    src_hash = prefetch_sri(src_url, unpack=False)
    updated = replace_one(
        r'^(\s*version = ")[^"]+(";)',
        rf"\g<1>{version}\g<2>",
        original_text,
        "OrcaSlicer version",
    )
    updated = replace_one(
        r'^(\s*hash = ")[^"]+(";)',
        rf"\g<1>{src_hash}\g<2>",
        updated,
        "OrcaSlicer hash",
    )
    ORCA_SLICER_BIN_PATH.write_text(updated, encoding="utf-8")
    print(f"orcaslicer -> {version}")


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
            "orcaslicer",
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
            "orcaslicer",
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
        if "orcaslicer" in targets:
            update_orcaslicer()
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
