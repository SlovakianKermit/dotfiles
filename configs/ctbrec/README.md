# ctbrec server-side patch material

Reproducible copies of the customisations applied to the ctbrec server
(Proxmox LXC 109). Nothing here runs automatically; these are the sources used
to rebuild the deployed artefacts.

## `servlet-patch/`

`ImageServlet.java` is a decompiled ctbrec 26.10.13 `ImageServlet` with three
behaviour changes:

1. For models that implement `ctbrec.PortraitUrlProvider` (Stripchat and
   Stripchat VR), the portrait fetch endpoint generates a 256x256 JPEG from the
   newest recording using ffmpeg. This is necessary because Stripchat's
   `previewUrlThumbBig` / `previewUrl` are static cover images for many models:
   the bytes stay identical over time even though `snapshotTimestamp` advances,
   so they do not resemble the live stream. Extraction reads a 16 MB byte
   slice (near the end for an active recording, mid-file for a finished one)
   and decodes the first keyframe with `-skip_frame nokey`; plain `-ss`
   seeking returns a grey placeholder on these VR `.ts` files. VR recordings
   are stereoscopic side-by-side, so only the left eye is kept. Blank/transition frames are rejected by size; if
   no usable frame exists the endpoint keeps an already stored portrait, or
   falls back to the provider snapshot, but never to the profile avatar. If
   neither exists it returns 404 "No stream snapshot available".
2. Stripchat serves webp. Java's ImageIO has no webp decoder, so the stock
   endpoint stored raw webp bytes in a `.jpg` file, which the desktop client
   could not render (it fell back to the default picture). The patch pipes webp
   bytes through ffmpeg and stores a real 256x256 JPEG.

Portrait responses also send `Cache-Control: no-store` so browsers cannot show
a stale picture after a refresh.

`deploy.sh` copies the installed jar from the container, compiles the class
against it with the local JDK 21, pushes the class files into
`/opt/ctbrec/patch/ctbrec/recorder/server/` and restarts ctbrec. The classpath
puts `/opt/ctbrec/patch` before the jar, so the patched class wins.

    ./deploy.sh              # compile, deploy, restart
    ./deploy.sh --no-restart # compile and deploy only

A restart interrupts active recordings briefly (ctbrec finalises them as
WAITING). Check for active recordings first if that matters.

The `compiled/` directory is the last known-good build for reference.

## `systemd/`

Copies of the units installed in the container:

- `ctbrec-auto-portraits.service` runs
  `/usr/local/bin/ctbrec-auto-portraits --quiet --limit 100 --delay 1.5`
  as the `ctbrec` user. Its `ExecStartPre` normalises stray webp portraits.
- `ctbrec-auto-portraits.timer` triggers it hourly, five minutes after boot or
  after the timer starts.

Install with `systemctl daemon-reload` and enable the timer. The executable is
mirrored from `~/.local/bin/ctbrec-auto-portraits`.

## Related local tooling

- `~/.local/bin/ctbrec-auto-portraits` - backfill missing portraits.
- `~/.local/bin/ctbrec-auto-portraits-remote` - run the above in the container.
- `~/.local/bin/ctbrec-webui-patch` - install/remove the WebUI "Fetch from
  stream" button by overriding static files in `/opt/ctbrec/patch/html/static`.
  Re-run `ctbrec-webui-patch apply` after a ctbrec upgrade.
- `refresh-from-recordings.py` (this directory) - one-off migration that
  regenerates already-stored Stripchat portraits from recording frames without
  restarting the server. Run as the ctbrec user inside the container; supports
  `--dry-run`, `--limit`, `--include-vr`.
