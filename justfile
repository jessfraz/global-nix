set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Default target: run formatting check and lint.
default: ci

# Format Python files in the repo.
fmt:
    ruff format .

# Check formatting without changing files (CI-friendly).
fmt-check:
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

