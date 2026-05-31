#!/usr/bin/env bash

set -euo pipefail

QUALITY=80
NOISE=3
SCALE=2

for input in *.webp; do
    if ! webpinfo -summary "$input" | grep -A5 "Chunk VP8X" | grep -q "Animation: 1"; then
        echo "Skipping $input (not animated)"
        continue
    fi

    echo "Processing $input..."

    tmpdir=$(mktemp -d)
    frames="$tmpdir/frames"
    enhanced="$tmpdir/enhanced"
    mkdir -p "$frames" "$enhanced"

    fps=$(ffprobe -v quiet -show_streams "$input" | grep avg_frame_rate | cut -d= -f2)
    echo "  Framerate: $fps"

    echo "  Extracting frames..."
    anim_dump -folder "$frames/" "$input"

    echo "  Running waifu2x..."
    waifu2x-ncnn-vulkan -i "$frames/" -o "$enhanced/" -n "$NOISE" -s "$SCALE"

    output="${input%.webp}_enhanced.webp"
    echo "  Reassembling -> $output"
    ffmpeg -framerate "$fps" -i "$enhanced/dump_%04d.png" -loop 0 -quality "$QUALITY" "$output" -y

    rm -rf "$tmpdir"
    echo "  Done: $output"
done

echo "All done."
