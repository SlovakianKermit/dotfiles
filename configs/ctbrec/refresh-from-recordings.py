#!/usr/bin/env python3
"""Regenerate Stripchat model portraits from a frame of the newest recording.

Stripchat's preview URL is often a static cover image, so it does not look
like the stream.  This maintenance script extracts a 256x256 JPEG frame from
the newest recording of every mapped Stripchat model and uploads it through the
ctbrec portrait API.  It is safe to run while recordings are active: it only
reads the growing file and seeks near the end.

Run it as the ctbrec user inside the container.  The normal hourly backfill
uses the same idea through the patched ImageServlet after the next restart.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import hmac
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SCALE_FILTER = "scale=256:256:force_original_aspect_ratio=increase,crop=256:256"


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


def find_config_dir(explicit: str | None) -> str:
    if explicit:
        return explicit
    base = os.path.expanduser("~/.config/ctbrec")
    candidates = [
        entry
        for entry in glob.glob(os.path.join(base, "*"))
        if os.path.isdir(entry)
        and "_backup_" not in os.path.basename(entry)
        and os.path.isfile(os.path.join(entry, "models.json"))
    ]
    if not candidates:
        sys.exit("no ctbrec config directory found; pass --config-dir")
    return max(candidates, key=lambda p: os.path.getmtime(os.path.join(p, "models.json")))


def newest_recording_files(config_dir: str) -> dict[str, tuple[int, str, str]]:
    newest: dict[str, tuple[int, str, str]] = {}
    for path in glob.glob(os.path.join(config_dir, "recordings", "*.json")):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                recording = json.load(handle)
        except (OSError, json.JSONDecodeError):
            continue
        model = recording.get("model") or {}
        url = model.get("url")
        if not url:
            continue
        file = recording.get("postProcessedFile")
        if not file or not os.path.isfile(file):
            file = recording.get("absoluteFile")
        if not file or not os.path.isfile(file):
            continue
        start = recording.get("startDate") or 0
        try:
            start = int(start)
        except (TypeError, ValueError):
            start = 0
        name = model.get("displayName") or model.get("name") or url
        if url not in newest or start > newest[url][0]:
            newest[url] = (start, file, name)
    return newest


def probe_duration(file: str) -> float:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", file],
            capture_output=True, timeout=15, check=False,
        )
        return float(result.stdout.decode().strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        return -1.0


def grab_frame(file: str, position: float) -> bytes | None:
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error",
             "-ss", str(max(0, int(position))), "-i", file,
             "-frames:v", "1", "-vf", SCALE_FILTER,
             "-f", "image2", "-vcodec", "mjpeg", "-q:v", "3", "pipe:1"],
            capture_output=True, timeout=90, check=False,
        )
    except subprocess.SubprocessError:
        return None
    if result.returncode != 0 or not result.stdout:
        return None
    return result.stdout


def frame_for(file: str) -> bytes | None:
    active = time.time() - os.path.getmtime(file) < 300
    duration = probe_duration(file)
    if active:
        position = max(3.0, duration - 20.0) if duration > 0 else 30.0
    else:
        position = max(5.0, duration * 0.5) if duration > 0 else 30.0
    frame = grab_frame(file, position)
    if frame is None and position > 5:
        frame = grab_frame(file, 5)
    return frame


def post_portrait(server: str, model_url: str, frame: bytes, key: str, context) -> int:
    endpoint = server.rstrip("/") + "/image/portrait/url/" + urllib.parse.quote(model_url, safe="")
    request = urllib.request.Request(endpoint, data=frame, method="POST")
    request.add_header("Content-Type", "image/jpeg")
    if key:
        digest = hmac.new(key.encode("utf-8"), frame, hashlib.sha256).hexdigest()
        request.add_header("CTBREC-HMAC", digest)
    with urllib.request.urlopen(request, timeout=90, context=context) as response:
        response.read()
        return response.status


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config-dir", metavar="PATH")
    parser.add_argument("--server", default="https://127.0.0.1:8443", metavar="URL")
    parser.add_argument("--delay", type=float, default=0.3, metavar="SECONDS")
    parser.add_argument("--limit", type=int, default=0, metavar="N")
    parser.add_argument("--include-vr", action="store_true", help="also process StripchatVRModel")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    config_dir = find_config_dir(args.config_dir)
    models_doc = load_json(os.path.join(config_dir, "models.json"), {}) or {}
    server_doc = load_json(os.path.join(config_dir, "server.json"), {}) or {}
    key = server_doc.get("key") or ""
    mapped = set((models_doc.get("modelPortraits") or {}).keys())
    by_url = {m.get("url"): m for m in models_doc.get("models") or [] if m.get("url")}
    newest = newest_recording_files(config_dir)

    wanted = []
    for url in mapped:
        model = by_url.get(url)
        if not model:
            continue
        kind = model.get("type") or ""
        if kind.endswith(".StripchatModel") or (args.include_vr and kind.endswith(".StripchatVRModel")):
            if url in newest:
                wanted.append((url, model, newest[url]))
    wanted.sort(key=lambda item: item[2][0], reverse=True)
    if args.limit and args.limit > 0:
        wanted = wanted[: args.limit]

    print(f"config: {config_dir}")
    print(f"mapped Stripchat models with a recording: {len(wanted)}")
    if args.dry_run:
        for url, model, (start, file, name) in wanted:
            print(f"  {name} <- {file}")
        return 0

    context = ssl._create_unverified_context()
    ok = failed = 0
    for index, (url, model, (start, file, name)) in enumerate(wanted, start=1):
        frame = frame_for(file)
        if frame is None:
            failed += 1
            print(f"[{index}/{len(wanted)}] {name} ... frame extraction failed")
            continue
        try:
            status = post_portrait(args.server, url, frame, key, context)
        except Exception as error:  # noqa: BLE001
            failed += 1
            print(f"[{index}/{len(wanted)}] {name} ... upload failed: {error}")
            continue
        ok += 1
        print(f"[{index}/{len(wanted)}] {name} ... ok ({len(frame)} bytes)")
        if args.delay:
            time.sleep(args.delay)

    print(f"done: {ok} updated, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
