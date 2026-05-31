#!/usr/bin/env python3
"""
Convert Claude conversations.json export to individual Markdown files.
Usage: python claude-export-to-md.py <path-to-conversations.json> <output-dir>
"""

import json
import sys
import os
import re
from datetime import datetime


def sanitize_filename(name: str) -> str:
    name = re.sub(r'[<>:"/\\|?*]', '', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name[:100] if name else "untitled"


def format_timestamp(ts: str) -> str:
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        return dt.strftime('%Y-%m-%d %H:%M')
    except Exception:
        return ts


def extract_text_from_content(content: list) -> str:
    """Extract only human-readable text from the content array, skipping tool calls."""
    parts = []
    for block in content:
        if block.get('type') == 'text':
            text = block.get('text', '').strip()
            if text:
                parts.append(text)
    return '\n\n'.join(parts)


def conversation_to_markdown(conv: dict) -> str:
    name = conv.get('name') or 'Untitled'
    created = format_timestamp(conv.get('created_at', ''))
    messages = conv.get('chat_messages', [])

    lines = []
    lines.append(f"# {name}\n")
    lines.append(f"*{created}*\n")
    lines.append("---\n")

    for msg in messages:
        sender = msg.get('sender', 'unknown')
        msg_time = format_timestamp(msg.get('created_at', ''))
        content = msg.get('content', [])

        text = extract_text_from_content(content)
        if not text:
            # Fall back to the top-level text field
            text = msg.get('text', '').strip()

        if not text:
            continue

        if sender == 'human':
            lines.append(f"## Human ({msg_time})\n")
        else:
            lines.append(f"## Claude ({msg_time})\n")

        lines.append(f"{text}\n")
        lines.append("---\n")

    return '\n'.join(lines)


def main():
    if len(sys.argv) != 3:
        print("Usage: python claude-export-to-md.py <conversations.json> <output-dir>")
        sys.exit(1)

    input_file = sys.argv[1]
    output_dir = sys.argv[2]

    if not os.path.exists(input_file):
        print(f"Error: {input_file} not found")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    print(f"Loading {input_file}...")
    with open(input_file, 'r', encoding='utf-8') as f:
        conversations = json.load(f)

    print(f"Found {len(conversations)} conversations")

    skipped = 0
    written = 0

    for conv in conversations:
        messages = conv.get('chat_messages', [])
        if not messages:
            skipped += 1
            continue

        name = conv.get('name') or 'Untitled'
        created = conv.get('created_at', '')[:10]  # YYYY-MM-DD
        safe_name = sanitize_filename(name)
        filename = f"{created} {safe_name}.md"
        filepath = os.path.join(output_dir, filename)

        # Handle duplicate filenames
        counter = 1
        while os.path.exists(filepath):
            filename = f"{created} {safe_name} ({counter}).md"
            filepath = os.path.join(output_dir, filename)
            counter += 1

        md = conversation_to_markdown(conv)
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(md)

        written += 1

    print(f"Done. Written: {written}, Skipped (empty): {skipped}")
    print(f"Output directory: {output_dir}")


if __name__ == '__main__':
    main()
