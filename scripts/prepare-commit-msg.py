#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import urllib.request
from urllib.error import HTTPError
from typing import Optional, Sequence, Union
import textwrap
from pathlib import Path
from contextlib import suppress

# Defaults (adjust here rather than via env vars)
# Switch to GPT-5 model alias (thinking-capable); keep prompt unchanged.
MODEL = "gpt-5"
REASONING_EFFORT = "high"  # one of: low, medium, high
# Control final answer verbosity (orthogonal to reasoning).
TEXT_VERBOSITY = "low"  # one of: low, medium, high
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
    if shutil_which("op"):
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


def shutil_which(cmd: str) -> bool:
    from shutil import which

    return which(cmd) is not None


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
    effort: str = "medium",
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
    payload_alt = {
        "model": model,
        "reasoning": {"effort": effort, "summary": REASONING_SUMMARY},
        "text": {"verbosity": TEXT_VERBOSITY},
        "input": [
            {
                "role": "user",
                "content": [{"type": "input_text", "text": prompt}],
            }
        ],
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
        with http_request(url, payload, headers) as resp:
            # Banner: always show a simple banner when streaming text, even if not in debug.
            try:
                sys.stderr.write(f"🦖 ({model})\n\n")
                sys.stderr.flush()
            except Exception:
                pass
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
                if etype == "response.output_text.delta":
                    delta = obj.get("delta", "")
                    if delta:
                        # Always collect output text silently; do not echo to stderr.
                        parts.append(delta)
                if etype in (
                    "response.message.delta",
                    "response.output.delta",
                    "response.reasoning.delta",
                    "response.reasoning_summary.delta",
                    "response.reasoning_summary_text.delta",
                ):
                    reason = ""
                    delta = obj.get("delta", {})
                    if isinstance(delta, dict):
                        content = delta.get("content")
                        if isinstance(content, list):
                            texts = [
                                c.get("text", "")
                                for c in content
                                if c.get("type") == "reasoning"
                            ]
                            reason = "".join(texts)
                        if not reason:
                            # Some events include a field named "reasoning" directly.
                            reason = delta.get("reasoning", "")
                    elif isinstance(delta, str):
                        # Some events carry the text directly in the string delta
                        # (e.g., response.reasoning_summary_text.delta)
                        reason = delta
                    if not reason and obj.get("error"):
                        reason = obj["error"].get("message", "")
                    # Always echo reasoning to stderr to provide progress.
                    if reason:
                        try:
                            sys.stderr.write(reason)
                            sys.stderr.flush()
                        except Exception:
                            pass
                if etype == "response.completed" and not parts:
                    response_obj = obj.get("response", {})
                    final_text = (
                        response_obj.get("output_text") or obj.get("output_text") or ""
                    )
                    if final_text:
                        parts.append(final_text)
            try:
                # Ensure a clean break after streaming text finishes.
                sys.stderr.write("\n")
                sys.stderr.flush()
            except Exception:
                pass
        return "".join(parts).strip()

    try:
        return do_stream(payload_primary)
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore") if hasattr(e, "read") else ""
        dbg(f"stream error {e.code}: {body[:200]}{' …' if len(body) > 200 else ''}")
        # Try alternate payload shape
        try:
            dbg("retrying stream with alternate input shape")
            return do_stream(payload_alt)
        except Exception as e2:
            dbg(f"stream alt error: {e2}")
            return ""
    except Exception as e:
        dbg(f"stream error: {e}")
        return ""
    # Unreachable
    # return "".join(out_text_parts).strip()


def call_responses_nostream(
    base: str, model: str, prompt: str, api_key: str, effort: str = "medium"
) -> str:
    url = base.rstrip("/") + "/v1/responses"
    payload_primary = {
        "model": model,
        "reasoning": {"effort": effort, "summary": REASONING_SUMMARY},
        "text": {"verbosity": TEXT_VERBOSITY},
        "input": prompt,
    }
    payload_alt = {
        "model": model,
        "reasoning": {"effort": effort, "summary": REASONING_SUMMARY},
        "text": {"verbosity": TEXT_VERBOSITY},
        "input": [
            {
                "role": "user",
                "content": [{"type": "input_text", "text": prompt}],
            }
        ],
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    def do_call(payload: dict) -> str:
        resp = http_request(url, payload, headers)
        body = resp.read().decode("utf-8", errors="ignore")
        if debug_enabled():
            try:
                err = json.loads(body).get("error", {}).get("message")
                if err:
                    sys.stderr.write(f"OpenAI error: {err}\n")
            except Exception:
                pass
        try:
            obj = json.loads(body)
        except Exception:
            return ""
        return (
            obj.get("output_text")
            or (obj.get("output", [{}])[0].get("content", [{}])[0].get("text"))
            or ""
        ).strip()

    try:
        return do_call(payload_primary)
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore") if hasattr(e, "read") else ""
        dbg(f"nostream error {e.code}: {body[:200]}{' …' if len(body) > 200 else ''}")
        try:
            dbg("retrying nostream with alternate input shape")
            return do_call(payload_alt)
        except Exception as e2:
            dbg(f"nostream alt error: {e2}")
            return ""
    except Exception as e:
        dbg(f"nostream error: {e}")
        return ""


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
    if not output:
        output = call_responses_nostream(API_BASE, MODEL, prompt, api_key, effort)
        dbg(f"fallback_bytes={len(output)}")

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
            sys.stderr.write("commit-ai: wrote generated commit message\n")
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
