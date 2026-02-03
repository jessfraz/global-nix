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

# Update pinned external versions and hashes.
update-codex:
    python3 scripts/update-pins.py codex

update-homebridge:
    python3 scripts/update-pins.py homebridge

update-mole:
    python3 scripts/update-pins.py mole

update-pins:
    python3 scripts/update-pins.py all
