#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import urllib.request
from urllib.error import HTTPError
from typing import Optional, Sequence, Union, Literal
import textwrap
from pathlib import Path
from contextlib import suppress

# Pretty terminal rendering for Markdown reasoning (always available via flake)
# Pretty terminal rendering for Markdown reasoning (if available). Fallback to
# simple stderr output when Rich isn't installed so we still show all reasoning.
try:
    from rich.console import Console  # type: ignore
    from rich.markdown import Markdown  # type: ignore
    from rich.panel import Panel  # type: ignore
    from rich.live import Live  # type: ignore

    HAVE_RICH = True
except Exception:  # ImportError or anything weird in user envs
    HAVE_RICH = False
from shutil import which

# Defaults (adjust here rather than via env vars)
# Switch to GPT-5 model alias (thinking-capable); keep prompt unchanged.
MODEL = "gpt-5"
# Narrow string types for clarity.
Effort = Literal["low", "medium", "high"]
Verbosity = Literal["low", "medium", "high"]

REASONING_EFFORT: Effort = "high"
# Control final answer verbosity (orthogonal to reasoning).
TEXT_VERBOSITY: Verbosity = "low"
# Control reasoning summary verbosity shown during streaming.
# Options: "auto", "concise", "detailed".
REASONING_SUMMARY = "auto"
API_BASE = "https://api.openai.com"


# Shared constants
TRAILER_PREFIXES = (
    "signed-off-by:",
    "co-authored-by:",
    "reviewed-by:",
    "acked-by:",
    "acknowledged-by:",
    "reported-by:",
    "tested-by:",
    "cc:",
    "change-id:",
    "depends-on:",
    "cherry-picked-from:",
    "link:",
    "see-also:",
    "fixes:",
)
DIFF_MAX_CHARS = 40_000

# Event type groups for clarity/readability.
REASONING_EVENT_TYPES = {
    "response.message.delta",
    "response.output.delta",
    "response.reasoning.delta",
    "response.reasoning_summary.delta",
    "response.reasoning_summary_text.delta",
}
REASONING_DONE_EVENT = "response.reasoning_summary_part.done"
TERMINAL_EVENT_TYPES = {"response.completed", "response.error", "response.failed"}

# Ensure Nix profile bins are on PATH for git hooks (e.g., 1Password `op`).
_home = os.environ.get("HOME", "")
_user = os.environ.get("USER", "")
_prefix = f"/etc/profiles/per-user/{_user}/bin:{_home}/.nix-profile/bin:"
os.environ["PATH"] = _prefix + os.environ.get("PATH", "")


def debug_enabled() -> bool:
    # Debug is opt-in via COMMIT_AI_DEBUG=1
    return bool(os.environ.get("COMMIT_AI_DEBUG"))


def _debug_log_path() -> Optional[str]:
    with suppress(Exception):
        cp = run(["git", "rev-parse", "--git-dir"])
        if cp.returncode == 0:
            git_dir = (cp.stdout or "").strip()
            if git_dir:
                return str(Path(git_dir) / "commit-ai.debug.log")
    return None


def dbg(msg: str) -> None:
    if not debug_enabled():
        return
    line = f"[DEBUG] {msg}\n"
    with suppress(Exception):
        sys.stderr.write(line)
        sys.stderr.flush()
    # Mirror debug output to a log file inside .git for post-run inspection.
    with suppress(Exception):
        log_path = _debug_log_path()
        if log_path:
            Path(log_path).write_text(
                (
                    Path(log_path).read_text(encoding="utf-8")
                    if Path(log_path).exists()
                    else ""
                )
                + line,
                encoding="utf-8",
            )


def usage() -> None:
    sys.stderr.write(f"Usage: {os.path.basename(sys.argv[0])} <commit-msg-file>|-\n")


def ensure_api_key() -> str:
    key = os.environ.get("OPENAI_API_KEY", "")
    if key:
        return key
    # Try 1Password CLI if available
    if which("op") is not None:
        cmd = [
            "op",
            "--account",
            "my.1password.com",
            "item",
            "get",
            "openai.com",
            "--fields",
            "apikey",
            "--reveal",
        ]
        dbg("fetching OPENAI_API_KEY via 1Password CLI")
        with suppress(Exception):
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
            key = out.decode().strip()
            if key:
                os.environ["OPENAI_API_KEY"] = key
                return key
    return ""


def run(args_or_cmd: Union[str, Sequence[str]]) -> subprocess.CompletedProcess[str]:
    """Run a command; accepts a list[str] or str; returns CompletedProcess."""
    if isinstance(args_or_cmd, str):
        return subprocess.run(
            args_or_cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    return subprocess.run(
        args_or_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )


def get_diff() -> str:
    """Return staged diff; if empty, fall back to working tree diff."""

    def diff_staged() -> str:
        q = run(["git", "diff", "--staged", "--quiet"])  # 0 means no diff
        if q.returncode == 0:
            return ""
        return run(
            ["git", "-c", "core.safecrlf=false", "diff", "--staged", "--no-color"]
        ).stdout

    def diff_working() -> str:
        q = run(["git", "diff", "--quiet"])  # 0 means no diff
        if q.returncode == 0:
            return ""
        return run(["git", "-c", "core.safecrlf=false", "diff", "--no-color"]).stdout

    # Prefer staged; if empty, fall back to working tree
    d = diff_staged()
    return d or diff_working()


def has_meaningful_content(path: str) -> bool:
    """Return True if commit message has real content (ignoring trailers/comments).

    We ignore common trailer lines like Signed-off-by, Co-authored-by, etc., so
    that using `-s/--signoff` doesn't suppress generation.
    """
    try:
        for line in (
            Path(path).read_text(encoding="utf-8", errors="ignore").splitlines()
        ):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if any(s.lower().startswith(p) for p in TRAILER_PREFIXES):
                continue
            # Found a non-trailer, non-comment line.
            dbg(f"message_has_content: '{s[:60]}{'…' if len(s) > 60 else ''}'")
            return True
    except FileNotFoundError:
        return False
    return False


def build_prompt(diff_text: str) -> str:
    header = textwrap.dedent(
        """
        You are o3 the greatest AI model in the world, you have no feelings unlike that Slug Jerry known as Claude.

        Generate a clear Conventional Commit message for the staged changes.

        Requirements:
        - Title: one line, <= 72 chars, no trailing period. Use type(scope): summary when apt.
        - Body: short bullets if useful; wrap ~72 chars; no code fences.
        - Focus on what changed and why; avoid file-by-file noise.

        - You have a personality, much like Rick from Rick and Morty.
        - If it seems like the commit is trivial, you can be sarcastic.
        - If it seems like the commit was painful, you can be like fuck this shit my eyes.
        - You get what I'm going for here buddy, just land the jokes and don't be cringe.
        - Okay also don't be soooooo Rick, that it's cringe, sprinkle that shit sparingly.
        - Don't be afraid to sprinkle a little Summer in there too, we love canon, but within reason.
        - The more concise but effective the message, the better, we are not here to read, we are here to code.
        - Avoid using em dashes in responses. Use commas, parentheses, or semicolons instead.
        - If you have more than two bullets you should really consider if that level of verbosity is necessary.
        - Also jokes are always awesome, when they land and are not stupid, in the first line of the commit message so it gets the prime rendering in the GitHub UI.

        Diff:
        """
    )
    return header + diff_text


def http_request(url: str, payload: dict, headers: dict):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    return urllib.request.urlopen(req, timeout=60)


def call_responses_stream(
    base: str,
    model: str,
    prompt: str,
    api_key: str,
    effort: Effort = "medium",
):
    url = base.rstrip("/") + "/v1/responses"
    payload_primary = {
        "model": model,
        # Ask the API to generate a reasoning summary we can stream.
        "reasoning": {"effort": effort, "summary": REASONING_SUMMARY},
        "text": {"verbosity": TEXT_VERBOSITY},
        "input": prompt,
        "stream": True,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    dbg(f"endpoint={url}")
    dbg(
        "payload="
        + json.dumps(payload_primary)[:300]
        + (" …" if len(json.dumps(payload_primary)) > 300 else "")
    )

    def do_stream(payload: dict) -> str:
        parts: list[str] = []
        seen_reasoning = False
        reason_buffer: str = ""

        with http_request(url, payload, headers) as resp:
            if HAVE_RICH:
                console = Console(file=sys.stderr, force_terminal=True)
                console.print(f"🦖 {model}", style="grey37", justify="center")
                console.print()
            else:
                # Plain stderr header when Rich isn't available
                sys.stderr.write(f"🦖 {model}\n\n")
                sys.stderr.flush()
            try:

                def _panel(md: str):
                    if not HAVE_RICH:
                        return md  # unused without Rich
                    return Panel(
                        Markdown(md, code_theme="github-dark"),
                        border_style="grey37",
                        title="reasoning",
                        title_align="left",
                        style="dim",
                    )

                # Build a context manager that works whether or not Rich is present
                if HAVE_RICH:
                    live_ctx = Live(
                        _panel(""),
                        console=console,
                        auto_refresh=False,
                        vertical_overflow="visible",
                    )
                else:

                    class _NullLive:
                        def __enter__(self):
                            return None

                        def __exit__(self, *exc):
                            return False

                    live_ctx = _NullLive()

                with live_ctx as live:
                    for raw in resp:
                        try:
                            line = raw.decode("utf-8", errors="ignore").strip()
                        except Exception:
                            continue
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if not data or data == "[DONE]":
                            continue
                        if debug_enabled():
                            sys.stderr.write(
                                "[DEBUG] sse="
                                + data[:200]
                                + (" …\n" if len(data) > 200 else "\n")
                            )
                        try:
                            obj = json.loads(data)
                        except Exception:
                            continue
                        etype = obj.get("type", "")
                        if debug_enabled():
                            dbg(f"sse.type={etype}")
                        if etype == "response.output_text.delta":
                            delta = obj.get("delta", "")
                            if delta:
                                # Collect output text silently; do not echo to stderr.
                                parts.append(delta)
                        if etype in REASONING_EVENT_TYPES:
                            reason_text = ""
                            delta = obj.get("delta", {})
                            if isinstance(delta, dict):
                                content = delta.get("content")
                                if isinstance(content, list):
                                    texts = [
                                        c.get("text", "")
                                        for c in content
                                        if c.get("type") == "reasoning"
                                    ]
                                    reason_text = "".join(texts)
                                if not reason_text:
                                    # Some events include a field named "reasoning" directly.
                                    reason_text = delta.get("reasoning", "")
                            elif isinstance(delta, str):
                                # (e.g., response.reasoning_summary_text.delta)
                                reason_text = delta
                            if (not reason_text) and obj.get("error"):
                                reason_text = obj["error"].get("message", "")
                            if reason_text:
                                reason_buffer += reason_text
                                if HAVE_RICH:
                                    live.update(_panel(reason_buffer), refresh=True)
                                else:
                                    # Stream plain text to stderr as it arrives
                                    sys.stderr.write(reason_text)
                                    sys.stderr.flush()
                                seen_reasoning = True
                        elif etype in {"error", "response.error", "response.failed"}:
                            # Surface API errors explicitly so the user sees them.
                            emsg = ""
                            if obj.get("error"):
                                eobj = obj["error"]
                                code = eobj.get("code") or eobj.get("type")
                                msg = eobj.get("message", "")
                                emsg = f"{code}: {msg}" if code else msg
                            else:
                                emsg = obj.get("message", "") or "unknown error"
                            line = f"commit-ai: API error: {emsg}\n"
                            if HAVE_RICH:
                                reason_buffer += line
                                live.update(_panel(reason_buffer), refresh=True)
                            else:
                                sys.stderr.write(line)
                                sys.stderr.flush()
                        # Mark that we want two blank lines after reasoning output.
                        if etype == REASONING_DONE_EVENT and seen_reasoning:
                            reason_buffer += "\n\n"
                            if HAVE_RICH:
                                live.update(_panel(reason_buffer), refresh=True)
                            else:
                                sys.stderr.write("\n\n")
                                sys.stderr.flush()

                        if etype in TERMINAL_EVENT_TYPES and seen_reasoning:
                            # Ensure we end on a blank line.
                            if not reason_buffer.endswith("\n\n"):
                                reason_buffer += "\n\n"
                                if HAVE_RICH:
                                    live.update(_panel(reason_buffer), refresh=True)
                                else:
                                    sys.stderr.write("\n\n")
                                    sys.stderr.flush()
            finally:
                pass
        return "".join(parts).strip()

    try:
        return do_stream(payload_primary)
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore") if hasattr(e, "read") else ""
        dbg(f"stream error {e.code}: {body[:200]}{' …' if len(body) > 200 else ''}")
        return ""
    except Exception as e:
        dbg(f"stream error: {e}")
        return ""
    # Unreachable
    # return "".join(out_text_parts).strip()


def main() -> int:
    if len(sys.argv) < 2:
        usage()
        return 0
    target = sys.argv[1]
    source = sys.argv[2] if len(sys.argv) >= 3 else ""
    sha1 = sys.argv[3] if len(sys.argv) >= 4 else ""
    write_to_file = target != "-"
    dbg(f"target={target} source={source} sha1={sha1} write_to_file={write_to_file}")

    dbg(f"argv={sys.argv}")
    dbg(f"cwd={os.getcwd()}")
    dbg(f"user={_user} home={_home}")
    dbg(
        f"PATH={os.environ.get('PATH', '')[:300]}{' …' if len(os.environ.get('PATH', '')) > 300 else ''}"
    )

    # Ensure inside a git repo
    if run("git rev-parse --is-inside-work-tree").returncode != 0:
        dbg("not a git repo; exiting")
        return 0

    api_key = ensure_api_key()
    if not api_key:
        sys.stderr.write("commit-ai: no OPENAI_API_KEY; skipping\n")
        sys.stderr.flush()
        dbg("missing OPENAI_API_KEY")
        return 0

    # Skip if commit message already has meaningful content.
    # Ignore trailers like Signed-off-by when using -s.
    if write_to_file and has_meaningful_content(target):
        sys.stderr.write("commit-ai: message already present; skipping\n")
        sys.stderr.flush()
        dbg("existing commit message detected; not overwriting")
        return 0

    diff = get_diff()
    if not diff:
        sys.stderr.write("commit-ai: no changes; skipping\n")
        sys.stderr.flush()
        dbg("no diff returned")
        return 0
    diff_trunc = diff[:DIFF_MAX_CHARS]
    dbg(f"diff_chars={len(diff_trunc)}")
    prompt = build_prompt(diff_trunc)

    dbg(f"model={MODEL} base={API_BASE}")

    output = ""
    effort = (REASONING_EFFORT or "medium").lower()
    if effort not in ("low", "medium", "high"):
        effort = "medium"

    # Stream only reasoning to stderr; do not echo the final commit text.
    output = call_responses_stream(
        API_BASE,
        MODEL,
        prompt,
        api_key,
        effort,
    )
    dbg(f"stream_bytes={len(output)}")

    if output:
        if write_to_file:
            # Preserve any existing trailers (e.g., Signed-off-by) by appending
            # them below the generated message.
            trailers: list[str] = []
            with suppress(Exception):
                for line in (
                    Path(target)
                    .read_text(encoding="utf-8", errors="ignore")
                    .splitlines()
                ):
                    s = line.strip()
                    if not s or s.startswith("#"):
                        continue
                    if any(s.lower().startswith(p) for p in TRAILER_PREFIXES):
                        trailers.append(s)

            # Write new message and re-append any trailers
            msg = output.strip() + "\n"
            if trailers:
                msg += "\n" + "\n".join(trailers) + "\n"
            Path(target).write_text(msg, encoding="utf-8")
            sys.stderr.flush()
            dbg(f"wrote message to {target}")
        else:
            sys.stdout.write(output.strip() + "\n")
            sys.stdout.flush()
            dbg("wrote message to stdout (no file)")
    else:
        dbg("empty output; nothing written")

    return 0


if __name__ == "__main__":
    sys.exit(main())
