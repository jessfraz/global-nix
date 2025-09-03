#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import urllib.request
from urllib.error import HTTPError


def debug_enabled() -> bool:
    return bool(os.environ.get("COMMIT_AI_DEBUG"))


def dbg(msg: str) -> None:
    if debug_enabled():
        sys.stderr.write(f"[DEBUG] {msg}\n")
        sys.stderr.flush()


def usage() -> None:
    sys.stderr.write(f"Usage: {os.path.basename(sys.argv[0])} <commit-msg-file>|-\n")


def ensure_api_key() -> str:
    key = os.environ.get("OPENAI_API_KEY", "")
    if key:
        return key
    # Try 1Password CLI if available
    if shutil_which("op"):
        try:
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
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
            key = out.decode().strip()
            if key:
                os.environ["OPENAI_API_KEY"] = key
                return key
        except Exception:
            pass
    return ""


def shutil_which(cmd: str) -> bool:
    from shutil import which

    return which(cmd) is not None


def run(cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )


def staged_diff() -> str:
    # If no changes staged, return empty string
    quiet = run("git diff --staged --quiet")
    if quiet.returncode == 0:
        return ""
    diff = run("git -c core.safecrlf=false diff --staged --no-color")
    return diff.stdout


def first_non_comment_line(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#"):
                    return s
    except FileNotFoundError:
        return ""
    return ""


def build_prompt(diff_text: str) -> str:
    header = (
        "Generate a clear Conventional Commit message for the staged changes.\n\n"
        "Requirements:\n"
        "- Title: one line, <= 72 chars, no trailing period. Use type(scope): summary when apt.\n"
        "- Body: short bullets if useful; wrap ~72 chars; no code fences.\n"
        "- Focus on what changed and why; avoid file-by-file noise.\n\n"
        "Diff:\n"
    )
    return header + diff_text


def http_request(url: str, payload: dict, headers: dict, stream: bool = False):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    return urllib.request.urlopen(req, timeout=60)


def call_responses_stream(
    base: str, model: str, prompt: str, api_key: str, effort: str = "medium"
):
    url = base.rstrip("/") + "/v1/responses"
    payload_primary = {
        "model": model,
        "reasoning": {"effort": effort},
        "input": prompt,
        "stream": True,
    }
    payload_alt = {
        "model": model,
        "reasoning": {"effort": effort},
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

    out_text_parts = []

    def do_stream(payload: dict) -> str:
        parts: list[str] = []
        with http_request(url, payload, headers, stream=True) as resp:
            sys.stderr.write(f"🧠 Reasoning ({model})\n")
            sys.stderr.flush()
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
                        parts.append(delta)
                if etype in (
                    "response.message.delta",
                    "response.output.delta",
                    "response.reasoning.delta",
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
                            reason = delta.get("reasoning", "")
                    if not reason and obj.get("error"):
                        reason = obj["error"].get("message", "")
                    if reason:
                        sys.stderr.write(reason)
                        sys.stderr.flush()
                if etype == "response.completed" and not parts:
                    response_obj = obj.get("response", {})
                    final_text = (
                        response_obj.get("output_text") or obj.get("output_text") or ""
                    )
                    if final_text:
                        parts.append(final_text)
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
        "reasoning": {"effort": effort},
        "input": prompt,
    }
    payload_alt = {
        "model": model,
        "reasoning": {"effort": effort},
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


def call_chat(base: str, model: str, prompt: str, api_key: str) -> str:
    url = base.rstrip("/") + "/v1/chat/completions"
    payload = {
        "model": model,
        "temperature": 0.2,
        "messages": [{"role": "user", "content": prompt}],
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    if debug_enabled():
        dbg(f"endpoint={url}")
        dbg(
            "payload="
            + json.dumps(payload)[:300]
            + (" …" if len(json.dumps(payload)) > 300 else "")
        )
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
    choice0 = (obj.get("choices") or [{}])[0]
    msg = (choice0.get("message") or {}).get("content") or ""
    return (msg or "").strip()


def main() -> int:
    if len(sys.argv) < 2:
        usage()
        return 0
    target = sys.argv[1]
    write_to_file = target != "-"

    # Ensure inside a git repo
    if run("git rev-parse --is-inside-work-tree").returncode != 0:
        dbg("not a git repo; exiting")
        return 0

    api_key = ensure_api_key()
    if not api_key:
        dbg("no OPENAI_API_KEY; exiting")
        return 0

    # Skip if commit message already has content (non-comment)
    if write_to_file and first_non_comment_line(target):
        return 0

    diff = staged_diff()
    if not diff:
        return 0
    diff_trunc = diff[:40000]
    dbg(f"diff_chars={len(diff_trunc)}")
    prompt = build_prompt(diff_trunc)

    model = os.environ.get("COMMIT_AI_MODEL", "o3")
    base = os.environ.get("OPENAI_API_BASE", "https://api.openai.com")
    dbg(f"model={model} base={base}")

    output = ""
    effort = os.environ.get("COMMIT_AI_REASONING_EFFORT", "medium").lower()
    if effort not in ("low", "medium", "high"):
        effort = "medium"

    if model.startswith("o"):
        output = call_responses_stream(base, model, prompt, api_key, effort)
        dbg(f"stream_bytes={len(output)}")
        if not output:
            output = call_responses_nostream(base, model, prompt, api_key, effort)
            dbg(f"fallback_bytes={len(output)}")
    else:
        output = call_chat(base, model, prompt, api_key)
        dbg(f"chat_bytes={len(output)}")

    if output:
        if write_to_file:
            with open(target, "w", encoding="utf-8") as f:
                f.write(output.strip() + "\n")
        else:
            sys.stdout.write(output.strip() + "\n")
            sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
