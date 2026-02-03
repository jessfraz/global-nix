#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from shutil import which
from typing import Iterable, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
FLAKE_PATH = REPO_ROOT / "flake.nix"
HOMEBRIDGE_PATH = REPO_ROOT / "pkgs" / "homebridge.nix"
MOLE_PATH = REPO_ROOT / "pkgs" / "mole.nix"

FAKE_SRI = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="


class UpdateError(RuntimeError):
    pass


def run(cmd: Sequence[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=True,
    )


def replace_one(pattern: str, repl: str, text: str, label: str) -> str:
    updated, count = re.subn(pattern, repl, text, flags=re.M)
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


def prefetch_sri(url: str) -> str:
    if which("nix"):
        result = subprocess.run(
            ["nix", "store", "prefetch-file", "--json", "--unpack", url],
            text=True,
            capture_output=True,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return data["hash"]
    if which("nix-prefetch-url"):
        hash_result = run(["nix-prefetch-url", "--unpack", url])
        base32_hash = hash_result.stdout.strip()
        sri_result = run(["nix", "hash", "to-sri", "--type", "sha256", base32_hash])
        return sri_result.stdout.strip()
    raise UpdateError("nix or nix-prefetch-url is required to compute source hashes.")


def update_codex() -> None:
    tags = get_tags("https://github.com/openai/codex.git")
    latest_tag = select_latest_tag(tags, preferred_prefixes=("rust-v",))

    flake_text = FLAKE_PATH.read_text(encoding="utf-8")
    if f"ref=refs/tags/{latest_tag}" in flake_text:
        print(f"codex already at {latest_tag}")
        return

    pattern = (
        r"(git\+https://github\.com/openai/codex\?ref=refs/tags/)([^&\"]+)([^\"]*)"
    )
    updated = replace_one(
        pattern,
        rf"\1{latest_tag}\3",
        flake_text,
        "codex tag",
    )

    FLAKE_PATH.write_text(updated, encoding="utf-8")
    print(f"codex -> {latest_tag}")

    if which("nix"):
        subprocess.run(
            ["nix", "flake", "lock", "--update-input", "codex"],
            check=True,
        )
    else:
        print("nix not found, skipping flake.lock update")


def compute_homebridge_npm_hash() -> str:
    if not which("nix"):
        raise UpdateError("nix is required to compute npmDepsHash.")

    expr = "\n".join(
        [
            "let",
            "  flake = builtins.getFlake (toString ./.);",
            "  overlaySkipNodeChecks = final: prev: {",
            "    nodejs_20 = prev.nodejs_20.overrideAttrs (_: { doCheck = false; });",
            "    nodejs_22 = prev.nodejs_22.overrideAttrs (_: { doCheck = false; });",
            "  };",
            "  pkgs = import flake.inputs.nixpkgs {",
            "    system = builtins.currentSystem;",
            "    overlays = [overlaySkipNodeChecks];",
            "  };",
            "in pkgs.callPackage ./pkgs/homebridge.nix {}",
        ]
    )
    build = subprocess.run(
        ["nix", "build", "--impure", "--expr", expr, "--no-link"],
        text=True,
        capture_output=True,
        cwd=REPO_ROOT,
    )
    output = f"{build.stdout}\n{build.stderr}"
    if build.returncode == 0:
        raise UpdateError("nix build succeeded, expected npmDepsHash mismatch.")

    matches = re.findall(r"sha256-[A-Za-z0-9+/=]+", output)
    if not matches:
        raise UpdateError("Failed to locate npmDepsHash in nix build output.")
    return matches[-1]


def update_homebridge() -> None:
    tags = get_tags("https://github.com/homebridge/homebridge.git")
    latest_tag = select_latest_tag(tags, preferred_prefixes=("v",))
    if not latest_tag.startswith("v"):
        raise UpdateError(f"Unexpected homebridge tag format: {latest_tag}")

    latest_version = latest_tag[1:]
    original_text = HOMEBRIDGE_PATH.read_text(encoding="utf-8")

    version_match = re.search(r'^\s*version = "([^"]+)";', original_text, re.M)
    if not version_match:
        raise UpdateError("Could not find homebridge version in pkgs/homebridge.nix")

    current_version = version_match.group(1)
    if current_version == latest_version:
        print(f"homebridge already at {latest_version}")
        return

    src_url = (
        "https://github.com/homebridge/homebridge/archive/refs/tags/"
        f"{latest_tag}.tar.gz"
    )
    src_hash = prefetch_sri(src_url)

    updated = replace_one(
        r'^(\s*version = ")[^"]+(";)',
        rf"\1{latest_version}\2",
        original_text,
        "homebridge version",
    )
    updated = replace_one(
        r'^(\s*gihubSha256 = ")[^"]+(";)',
        rf"\1{src_hash}\2",
        updated,
        "homebridge gihubSha256",
    )

    with_fake = replace_one(
        r"^(\s*npmDepsHash = ).*?;",
        rf'\1"{FAKE_SRI}";',
        updated,
        "homebridge npmDepsHash",
    )

    HOMEBRIDGE_PATH.write_text(with_fake, encoding="utf-8")

    try:
        npm_hash = compute_homebridge_npm_hash()
    except Exception:
        HOMEBRIDGE_PATH.write_text(original_text, encoding="utf-8")
        raise

    final_text = replace_one(
        r"^(\s*npmDepsHash = ).*?;",
        rf'\1"{npm_hash}";',
        updated,
        "homebridge npmDepsHash",
    )

    HOMEBRIDGE_PATH.write_text(final_text, encoding="utf-8")
    print(f"homebridge -> {latest_version}")


def update_mole() -> None:
    tags = get_tags("https://github.com/tw93/Mole.git")
    latest_tag = select_latest_tag(tags, preferred_prefixes=("V", "v"))
    if not latest_tag:
        raise UpdateError("No Mole tags found.")

    version = latest_tag.lstrip("vV")
    original_text = MOLE_PATH.read_text(encoding="utf-8")

    version_match = re.search(r'^\s*version = "([^"]+)";', original_text, re.M)
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
        rf"\1{version}\2",
        original_text,
        "mole version",
    )
    updated = replace_one(
        r'^(\s*srcHash = ")[^"]+(";)',
        rf"\1{src_hash}\2",
        updated,
        "mole srcHash",
    )
    updated = replace_one(
        r'^(\s*binariesHashArm64 = ")[^"]+(";)',
        rf"\1{binaries_hash_arm}\2",
        updated,
        "mole binariesHashArm64",
    )
    updated = replace_one(
        r'^(\s*binariesHashAmd64 = ")[^"]+(";)',
        rf"\1{binaries_hash_amd}\2",
        updated,
        "mole binariesHashAmd64",
    )

    MOLE_PATH.write_text(updated, encoding="utf-8")
    print(f"mole -> {version}")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update pinned tags and hashes.")
    parser.add_argument(
        "targets",
        nargs="+",
        choices=["codex", "homebridge", "mole", "all"],
        help="Targets to update.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    targets = set(args.targets)
    if "all" in targets:
        targets = {"codex", "homebridge", "mole"}

    try:
        if "codex" in targets:
            update_codex()
        if "homebridge" in targets:
            update_homebridge()
        if "mole" in targets:
            update_mole()
    except UpdateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
