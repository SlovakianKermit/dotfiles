# ctbrec server-side patch material

Reproducible copies of the customisations applied to the ctbrec server
(Proxmox LXC 109). Nothing here runs automatically; these are the sources used
to rebuild the deployed artefacts.

## `servlet-patch/`

`ImageServlet.java` is a decompiled ctbrec 26.10.13 `ImageServlet` with one
behaviour change: before falling back to the site's search results, the
portrait fetch endpoint asks the model for a dedicated portrait URL through
`ctbrec.PortraitUrlProvider`. Stripchat implements that by returning
`previewUrlThumbBig` from its cam API, which is the latest live-stream snapshot
even while the model is offline. The unmodified code used `avatarUrl` from
search, i.e. the default profile picture.

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
