"""Exercise the PR selector used by the automerge script with real jq."""

import json
import shutil
import subprocess
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
        executable = shutil.which("bash")
        self.assertIsNotNone(executable)
        result = subprocess.run(
            [
                executable,
                "-c",
                'source "$1"; "$2"',
                "test",
                str(SCRIPT),
                selector,
            ],
            input=json.dumps([asdict(pr) for pr in prs]),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line)["number"] for line in result.stdout.splitlines()]


if __name__ == "__main__":
    unittest.main()
