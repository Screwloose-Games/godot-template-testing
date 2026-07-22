"""
Fetch messages from a Discord channel over a given timeframe and emit a transcript.

Usage:
    python tools/get-meeting-transcript.py CHANNEL_ID --date 2026-07-14
    python tools/get-meeting-transcript.py CHANNEL_ID --since 2026-07-14T09:00 --until 2026-07-14T17:00
    python tools/get-meeting-transcript.py CHANNEL_ID --hours 3 --stdout

By default the transcript is written to docs/meeting-transcripts/ as
discord-transcript-YYYY-MM-DD-HHMM.md, named after the first message's
timestamp (so multiple transcripts per day don't collide). Use --output
for an explicit path or --stdout to print instead.

The bot token is read from DISCORD_BOT_TOKEN (loaded from a .env file if present).

Requirements:
    pip install requests python-dotenv

The bot must be in the server and have the "Read Message History"
permission for the channel (and the Message Content intent enabled
in the Discord developer portal if you want message text).
"""

import argparse
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

import requests
from dotenv import load_dotenv

DISCORD_EPOCH = 1420070400000  # ms, 2015-01-01T00:00:00Z
API_BASE = "https://discord.com/api/v10"
DEFAULT_OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "docs",
    "meeting-transcripts",
)


def snowflake_from_datetime(dt: datetime) -> int:
    """Convert a datetime into a Discord snowflake for time-based filtering."""
    ms = int(dt.timestamp() * 1000)
    return (ms - DISCORD_EPOCH) << 22


def fetch_messages_between(
    channel_id: str, since: datetime, until: datetime, token: str
) -> list[dict]:
    """Page through channel messages in [since, until], oldest first."""
    headers = {"Authorization": f"Bot {token}"}
    url = f"{API_BASE}/channels/{channel_id}/messages"

    after = snowflake_from_datetime(since)
    before = snowflake_from_datetime(until)

    messages = []
    while True:
        resp = requests.get(
            url,
            headers=headers,
            params={"after": after, "limit": 100},
            timeout=30,
        )

        # Respect rate limits
        if resp.status_code == 429:
            retry_after = float(resp.json().get("retry_after", 1))
            time.sleep(retry_after)
            continue

        resp.raise_for_status()
        batch = resp.json()

        if not batch:
            break

        # With `after`, Discord returns newest-first within the batch;
        # sort ascending so pagination and output stay chronological.
        batch.sort(key=lambda m: int(m["id"]))
        after = int(batch[-1]["id"])

        messages.extend(m for m in batch if int(m["id"]) <= before)

        if len(batch) < 100 or after > before:
            break

    return messages


def clean_speaker(author: str) -> str:
    """Strip transcription-bot prefixes like '[Scriptly] ' from speaker names."""
    return re.sub(r"^\[[^\]]+\]\s*", "", author)


def clean_transcript(messages: list[dict]) -> list[str]:
    """Format messages as a typical transcript: consecutive messages from the
    same speaker are merged into one block under a single speaker/time header."""
    lines: list[str] = []
    current_speaker = None

    for msg in messages:
        content = (msg.get("content") or "").strip()
        attachments = msg.get("attachments", [])
        if not content and not attachments:
            continue  # skip embed-only bot noise

        ts = datetime.fromisoformat(msg["timestamp"]).astimezone()
        author = msg["author"].get("global_name") or msg["author"]["username"]
        speaker = clean_speaker(author)

        if speaker != current_speaker:
            lines.append("")
            lines.append(f"**{speaker}** [{ts.strftime('%H:%M')}]:")
            current_speaker = speaker

        if content:
            lines.append(content)
        for att in attachments:
            lines.append(f"[attachment: {att.get('filename', '?')} — {att.get('url', '')}]")

    return lines


def parse_local_datetime(value: str) -> datetime:
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.astimezone()  # interpret as local time
    return dt


def resolve_timeframe(args: argparse.Namespace) -> tuple[datetime, datetime]:
    if args.date:
        day = datetime.strptime(args.date, "%Y-%m-%d").astimezone()
        return day, day + timedelta(days=1)
    if args.since:
        since = parse_local_datetime(args.since)
        until = parse_local_datetime(args.until) if args.until else datetime.now(timezone.utc)
        return since, until
    hours = args.hours if args.hours is not None else 3
    now = datetime.now(timezone.utc)
    return now - timedelta(hours=hours), now


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch a Discord channel's message history for a timeframe."
    )
    parser.add_argument("channel_id", help="Discord channel ID")
    timeframe = parser.add_mutually_exclusive_group()
    timeframe.add_argument("--date", help="Full calendar day, local time (YYYY-MM-DD)")
    timeframe.add_argument("--since", help="Start datetime (ISO format, local time if no offset)")
    timeframe.add_argument("--hours", type=float, help="Last N hours (default: 3)")
    parser.add_argument("--until", help="End datetime for --since (ISO format; default: now)")
    parser.add_argument(
        "--output",
        help="Explicit output file path (default: auto-named file in --output-dir)",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory for auto-named transcripts (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--stdout", action="store_true", help="Print the transcript instead of writing a file"
    )
    args = parser.parse_args()

    if args.until and not args.since:
        parser.error("--until requires --since")

    load_dotenv()
    token = os.environ.get("DISCORD_BOT_TOKEN")
    if not token:
        sys.exit("DISCORD_BOT_TOKEN not set (add it to .env or the environment).")

    since, until = resolve_timeframe(args)
    messages = fetch_messages_between(args.channel_id, since, until, token)

    if not messages:
        print(f"No messages between {since.isoformat()} and {until.isoformat()}.")
        return

    header = [
        f"# Discord Transcript — channel {args.channel_id}",
        "",
        f"Timeframe: {since.isoformat()} to {until.isoformat()}",
        f"Messages: {len(messages)}",
    ]
    body = clean_transcript(messages)

    output = "\n".join(header + body) + "\n"

    if args.stdout:
        print(output)
        return

    if args.output:
        out_path = args.output
    else:
        first_ts = datetime.fromisoformat(messages[0]["timestamp"]).astimezone()
        filename = f"discord-transcript-{first_ts.strftime('%Y-%m-%d-%H%M')}.md"
        out_path = os.path.join(args.output_dir, filename)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(output)
    print(f"Wrote {len(messages)} messages to {out_path}")


if __name__ == "__main__":
    main()
