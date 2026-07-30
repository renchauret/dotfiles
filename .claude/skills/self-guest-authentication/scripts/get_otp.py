#!/usr/bin/env python3
"""Read a Toast OTP that Google Voice forwarded into ren's Toast mailbox.

Chain: Toast SMS -> Google Voice (+1 765 205 5923) -> ren's personal Gmail
-> filter auto-forwards -> renaud.chauret@toasttab.com -> read here via `gws`.

Measured latency is under 9s end-to-end, so the default timeout is generous.

Usage:
  get_otp.py [--since-epoch N] [--timeout 90] [--poll 5]

Exit codes: 0 = code printed on stdout, 1 = timed out, 2 = gws/plumbing failure.
"""
import argparse
import base64
import json
import re
import subprocess
import sys
import time

# Google Voice forwards arrive from <ours>.<sender>.<tag>@txt.voice.google.com.
SENDER_QUERY = "from:txt.voice.google.com"

# Strip phone-number-shaped noise before looking for the code, so the sender's
# number can never be mistaken for the OTP.
NOISE = re.compile(r"\+?\d[\d\-().\s]{9,}")


def gws(params):
    """Call gws gmail and return parsed JSON, or exit 2 on failure."""
    proc = subprocess.run(["gws", "gmail", *params, "--format", "json"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"gws failed: {(proc.stderr or proc.stdout).strip()}", file=sys.stderr)
        sys.exit(2)
    # gws prints a keyring banner before the JSON payload; slice to the body.
    out = proc.stdout
    body = out[out.find("{"):out.rfind("}") + 1]
    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        print(f"could not parse gws output: {exc}", file=sys.stderr)
        sys.exit(2)


def list_ids(newer_than_secs):
    """Message ids of recent Voice forwards, newest first."""
    # Gmail's newer_than: has only minute granularity, so over-fetch by a minute
    # and filter precisely on internalDate below.
    minutes = max(1, newer_than_secs // 60 + 1)
    params = ["users", "messages", "list", "--params", json.dumps(
        {"userId": "me", "q": f"{SENDER_QUERY} newer_than:{minutes}m", "maxResults": 10})]
    return [m["id"] for m in gws(params).get("messages", [])]


def fetch(msg_id):
    """Return (text, internal_epoch) for one message."""
    raw = gws(["users", "messages", "get", "--params",
               json.dumps({"userId": "me", "id": msg_id, "format": "full"})])
    internal = int(raw.get("internalDate", "0")) // 1000
    text = collect_text(raw.get("payload", {}))
    # The snippet is a reliable fallback if MIME decoding comes up empty.
    return (text or raw.get("snippet", "")), internal


def collect_text(payload):
    """Walk a MIME tree and concatenate decoded text/plain parts."""
    out = []
    if payload.get("mimeType", "").startswith("text/plain"):
        data = payload.get("body", {}).get("data")
        if data:
            pad = "=" * (-len(data) % 4)
            try:
                out.append(base64.urlsafe_b64decode(data + pad).decode("utf-8", "replace"))
            except Exception:
                pass
    for part in payload.get("parts", []) or []:
        out.append(collect_text(part))
    return "\n".join(filter(None, out))


def extract_code(text, min_digits, max_digits):
    """Pull the OTP out of a forwarded Voice message."""
    cleaned = NOISE.sub(" ", text or "")
    labelled = re.search(
        r"(?:code|otp|passcode|verification|verify|pin)\D{0,20}?(\d{%d,%d})"
        % (min_digits, max_digits), cleaned, re.IGNORECASE)
    if labelled:
        return labelled.group(1)
    runs = re.findall(r"(?<!\d)(\d{%d,%d})(?!\d)" % (min_digits, max_digits), cleaned)
    return runs[0] if runs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since-epoch", type=int, default=None,
                    help="ignore mail older than this epoch second "
                         "(capture `date +%s` before triggering; ALWAYS pass this)")
    ap.add_argument("--timeout", type=int, default=90)
    ap.add_argument("--poll", type=int, default=5)
    ap.add_argument("--min-digits", type=int, default=4)
    ap.add_argument("--max-digits", type=int, default=8)
    ap.add_argument("--text", help="parse this string instead of Gmail (for testing)")
    args = ap.parse_args()

    if args.text is not None:
        code = extract_code(args.text, args.min_digits, args.max_digits)
        if not code:
            print("no code found in supplied text", file=sys.stderr)
            return 1
        print(code)
        return 0

    # Gmail's internalDate is whole seconds; back off 2s so a code arriving in
    # the same second as the trigger isn't discarded.
    cutoff = (args.since_epoch if args.since_epoch is not None else int(time.time())) - 2
    deadline = time.time() + args.timeout
    seen = set()

    while time.time() < deadline:
        for msg_id in list_ids(int(time.time()) - cutoff + 60):
            if msg_id in seen:
                continue
            seen.add(msg_id)
            text, internal = fetch(msg_id)
            if internal < cutoff:
                continue  # predates this attempt; a stale code would 403
            code = extract_code(text, args.min_digits, args.max_digits)
            if code:
                print(code)
                return 0
        time.sleep(args.poll)

    print(f"no forwarded OTP within {args.timeout}s. Check that the Gmail filter on "
          f"ren's personal account still forwards from:txt.voice.google.com.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
