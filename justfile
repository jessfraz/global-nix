set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Default target: run formatting check and lint.
default: ci

# Format Nix and Python files in the repo.
fmt:
    alejandra .
    ruff format .

# Check formatting without changing files (CI-friendly).
fmt-check:
    alejandra --check .
    ruff format --check .

# Lint Python files.
lint:
    ruff check --output-format=concise .

# Lint and apply automatic fixes (use with care).
lint-fix:
    ruff check --fix --unsafe-fixes --output-format=concise .

# CI helper: ensure formatting is correct, then lint.
ci:
    just fmt-check
    just lint

# Apply root Nix daemon build limits before macmini rebuilds.
apply-macmini-nix-limits:
    #!/usr/bin/env bash
    set -euo pipefail

    tmp="$(mktemp)"
    trap 'rm -f "${tmp}"' EXIT
    {
        cat hosts/darwin/nix.custom.conf
        printf '%s\n' \
            'max-jobs = 1' \
            'cores = 2'
    } > "${tmp}"

    sudo install -m 0644 "${tmp}" /etc/nix/nix.custom.conf

    sudo launchctl kickstart -k system/systems.determinate.nix-daemon
    nix config show | rg '^(max-jobs|cores|substituters|trusted-public-keys) ='

# Update pinned external versions and hashes.
update-codex:
    python3 scripts/update-pins.py codex

update-mole:
    python3 scripts/update-pins.py mole

update-ramp:
    python3 scripts/update-pins.py ramp

update-zoo:
    python3 scripts/update-pins.py zoo

update-pins:
    python3 scripts/update-pins.py all

# Update sibling flakes, push lockfile bumps to main, then update this repo.
update-flakes-all:
    #!/usr/bin/env bash
    set -euo pipefail

    update_and_push_main() {
        local repo="$1"

        if [[ ! -d "${repo}" ]]; then
            echo "Missing repo: ${repo}" >&2
            return 1
        fi

        (
            cd "${repo}"

            if [[ -n "$(git status --porcelain)" ]]; then
                echo "${repo}: working tree is dirty, refusing auto-commit" >&2
                exit 1
            fi

            nix flake update

            if git diff --quiet -- flake.lock; then
                echo "${repo}: flake.lock unchanged, skipping commit/push"
                exit 0
            fi

            git add flake.lock
            git commit -m "chore: nix flake update"
            git push origin HEAD:main
        )
    }

    update_and_push_main ../dotfiles
    update_and_push_main ../vim
    nix flake update
