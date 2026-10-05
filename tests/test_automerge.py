"""Exercise automerge scans and PR selectors with real Bash and jq."""

import json
import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from dataclasses import asdict, dataclass, replace
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/kittycad-pr-automerge"


@dataclass(frozen=True)
class Author:
    login: str


@dataclass(frozen=True)
class PullRequest:
    number: int
    title: str
    headRefName: str
    author: Author
    isDraft: bool = False


class AutomergeTests(unittest.TestCase):
    def test_scan_handles_large_json_and_preserves_processing_counters(self) -> None:
        spec = PullRequest(
            1,
            "Update api spec",
            "update-spec",
            Author("app/zoo-github-actions-auth"),
        )
        prs = [
            spec,
            replace(spec, number=2, author=Author("someone-else")),
            replace(spec, number=3, isDraft=True),
            replace(spec, number=4, headRefName="unrelated"),
            *[
                replace(spec, number=number, title="Unrelated change " + "x" * 200)
                for number in range(5, 101)
            ],
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            listing = root / "prs.json"
            listing.write_text(json.dumps([asdict(pr) for pr in prs]))
            state = root / "state.json"
            state.write_text(
                json.dumps(
                    {
                        "data": {
                            "viewer": {"login": "reviewer"},
                            "repository": {
                                "pullRequest": {
                                    "autoMergeRequest": None,
                                    "latestOpinionatedReviews": {"nodes": []},
                                }
                            },
                        }
                    }
                )
            )
            calls = root / "calls"
            result = self.run_script(
                """source "$1"
listing="$2"
state="$3"
calls="$4"
gh() {
  printf '%s %s\n' "$1" "$2" >> "$calls"
  case "$1 $2" in
    'pr list') cat "$listing" ;;
    'api graphql') cat "$state" ;;
    *) return 90 ;;
  esac
}
DRY_RUN=1
TARGET_REPOS=(cli)
process_update_spec_repo_prs
printf 'processed=%s skipped=%s errors=%s\n' "$processed" "$skipped" "$errors"
""",
                str(listing),
                str(state),
                str(calls),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    "[kittycad-pr-automerge] scanning spec and SDK docs sync PRs in target repos...",
                    "[kittycad-pr-automerge] repo spec/docs sync -> KittyCAD/cli#1 (Update api spec)",
                    "[kittycad-pr-automerge] [dry-run] approve -> KittyCAD/cli#1",
                    "[kittycad-pr-automerge] [dry-run] auto-merge -> KittyCAD/cli#1",
                    "processed=1 skipped=0 errors=0",
                ],
            )
            self.assertEqual(calls.read_text().splitlines(), ["pr list", "api graphql"])

    def test_documentation_sync_requires_matching_bot_title_and_branch(self) -> None:
        cli = PullRequest(
            1056,
            "Update CLI docs for 0.2.198",
            "update-docs-0.2.198",
            Author("app/zoo-github-actions-auth"),
        )
        kcl = PullRequest(
            2,
            "Update KCL docs",
            "update-kcl-docs",
            Author("app/modeling-app-github-app"),
        )
        prs = [
            cli,
            kcl,
            replace(cli, number=3, author=Author("zoo-github-actions-auth[bot]")),
            replace(kcl, number=4, author=Author("modeling-app-github-app[bot]")),
            replace(cli, number=5, author=Author("someone-else")),
            replace(cli, number=6, author=kcl.author),
            replace(kcl, number=7, author=cli.author),
            replace(cli, number=8, isDraft=True),
            replace(kcl, number=9, isDraft=True),
            replace(cli, number=10, headRefName="update-docs-0.2.197"),
            replace(cli, number=11, title="Update other docs for 0.2.198"),
            replace(
                cli, number=12, title="Update CLI docs for ", headRefName="update-docs-"
            ),
            replace(kcl, number=13, headRefName="unrelated"),
        ]
        self.assertEqual(
            self.select_prs("select_documentation_sync_prs", prs), [1056, 2, 3, 4]
        )

    def test_homebrew_formula_sync_requires_matching_bot_title_and_branch(self) -> None:
        formula = PullRequest(
            113,
            "Update tap formula",
            "update-tap-formula",
            Author("app/zoo-github-actions-auth"),
        )
        prs = [
            formula,
            replace(formula, number=2, author=Author("zoo-github-actions-auth[bot]")),
            replace(formula, number=3, author=Author("someone-else")),
            replace(formula, number=4, author=Author("app/modeling-app-github-app")),
            replace(formula, number=5, isDraft=True),
            replace(formula, number=6, title="Update tap formula for 0.2.198"),
            replace(formula, number=7, headRefName="update-tap-formula-0.2.198"),
            replace(
                formula, number=8, title="Update api spec", headRefName="update-spec"
            ),
        ]
        self.assertEqual(self.select_prs("select_homebrew_formula_prs", prs), [113, 2])

    def select_prs(self, selector: str, prs: list[PullRequest]) -> list[int]:
        result = self.run_script(
            'source "$1"; "$2"',
            selector,
            input=json.dumps([asdict(pr) for pr in prs]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line)["number"] for line in result.stdout.splitlines()]

    def run_script(
        self, command: str, *args: str, input: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        executable = shutil.which("bash")
        self.assertIsNotNone(executable)
        command_args = [executable, "-c", command, "test", str(SCRIPT), *args]
        process = subprocess.Popen(
            command_args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(input=input, timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            self.fail(
                f"automerge did not complete within 5 seconds:\n{stdout}\n{stderr}"
            )
        return subprocess.CompletedProcess(
            command_args, process.returncode, stdout, stderr
        )


if __name__ == "__main__":
    unittest.main()
