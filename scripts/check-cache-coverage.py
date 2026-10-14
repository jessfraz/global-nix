#!/usr/bin/env python3
"""Check actual host runtime closures without publishing host configurations."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

# These host tools, scripts, files and manuals are generated for the host,
# but do not consistently declare preferLocalBuild. Keep exceptions exact and
# do not exempt their dependencies: a new package in a script must be covered.
HOST_GENERATORS = frozenset(
    {
        "darwin-uninstaller",
        "darwin-version",
        "darwin-rebuild",
        "darwin-option",
        "darwin-manpages",
        "darwin-manual-html",
        "home-configuration-reference-manpage",
        "home-manager-agents",
        "home-manager-agent-domains",
        "hm-modules-messages",
        "ca-certificates.crt",
        "git-cleanup-scripts",
        "kittycad-pr-automerge",
        "cleanup-build-caches",
        "unifi-mcp",
    }
)
PRIVATE_NAMES = HOST_GENERATORS | {
    "Corefile",
    "nix.custom.conf",
    "home-manager-generation",
    "home-manager-files",
    "etc",
    "launchd",
    "activation-script",
}
PRIVATE_PREFIXES = (
    "hm_",
    "etc-",
    "darwin-system-",
    "org.nixos.",
    "org.nix-community.",
    "com.apple.",
)


def normalize_derivations(document, store_dir="/nix/store"):
    """Accept legacy JSON and Nix's versioned graph with relative store paths."""
    graph = document.get("derivations", document)
    result = {}
    for drv, value in graph.items():
        if not isinstance(value, dict) or "outputs" not in value:
            raise ValueError(f"Unrecognized derivation JSON for {drv}")
        sources = value.get("inputs", {}).get("srcs", value.get("inputSrcs", []))
        outputs = {
            name: (
                {**output, "path": str(Path(store_dir) / output["path"])}
                if output.get("path")
                else output
            )
            for name, output in value["outputs"].items()
        }
        result[str(Path(store_dir) / drv)] = {
            **value,
            "inputSrcs": [str(Path(store_dir) / path) for path in sources],
            "outputs": outputs,
        }
    return result


def attributes(derivation):
    env = derivation.get("env", {})
    return {
        **env,
        **json.loads(env.get("__json", "{}")),
        **derivation.get("structuredAttrs", {}),
    }


def enabled(value):
    return value is True or value == "1"


def inspect_coverage(cache_paths, host_paths, derivations):
    owners = {}
    sources = set()
    private = set()
    for drv, derivation in derivations.items():
        attrs = attributes(derivation)
        name = derivation.get("name", attrs.get("name", ""))
        sources.update(derivation.get("inputSrcs", []))
        for output in derivation["outputs"].values():
            path = output.get("path")
            if path:
                owners[path] = (drv, name, attrs)
                if name in PRIVATE_NAMES or name.startswith(PRIVATE_PREFIXES):
                    private.add(path)

    missing = []
    local = []
    for path in sorted(host_paths - cache_paths):
        owner = owners.get(path)
        if owner is None:
            # Source files referenced by generated configurations have no
            # derivation. Unknown paths are errors, never implicit exceptions.
            (local if path in sources else missing).append(path)
            continue
        _, name, attrs = owner
        if enabled(attrs.get("preferLocalBuild")) or (
            name in HOST_GENERATORS and not attrs.get("pname")
        ):
            local.append(path)
        else:
            missing.append(path)
    return missing, sorted(cache_paths & private), local


def nix(*args):
    return subprocess.check_output(["nix", *args], text=True)


def closure(paths):
    return set(nix("path-info", "--recursive", *paths).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--host", action="append", required=True)
    parser.add_argument(
        "--publication-only",
        action="store_true",
        help="Check privacy before publishing",
    )
    args = parser.parse_args()
    cache = str(Path(args.cache).resolve(strict=True))
    roots = [
        nix("eval", "--raw", "--no-update-lock-file", f"{host}.outPath")
        for host in args.host
    ]
    cache_paths = closure([cache])
    if cache_paths.intersection(roots):
        parser.error("a generated host root is in the public cache closure")
    derivations = json.loads(
        nix("derivation", "show", "--recursive", "--no-update-lock-file", *args.host)
    )
    derivations = normalize_derivations(derivations, str(Path(cache).parent))
    host_paths = set() if args.publication_only else closure(roots)
    missing, private, local = inspect_coverage(cache_paths, host_paths, derivations)
    for path in private:
        print(f"Private/generated output in public cache: {path}", file=sys.stderr)
    for path in missing:
        print(f"Package missing from ci-cache: {path}", file=sys.stderr)
    if private or missing:
        print(
            "Select unconfigured packages in ci-cache; keep host configuration local.",
            file=sys.stderr,
        )
        return 1
    if args.publication_only:
        print("Public cache excludes generated host configuration outputs.")
        return 0
    print(
        f"Cache covers host packages ({len(cache_paths)} public paths); "
        f"{len(local)} generated/source paths remain local."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
