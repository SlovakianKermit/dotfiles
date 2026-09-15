---
name: man-pages
description: >-
  Use when creating, editing, or updating any script in ~/.local/bin/ (or the
  ~/dotfiles/scripts/ mirror), or when writing or fixing a man page. Ensures
  every script has a matching .1 man page updated in the same session. Triggers:
  new script, update script, edit script, man page, .1, roff, mandb, man <cmd>.
---

# Man pages for Killian's scripts

Every executable script in `~/.local/bin/` gets a matching man page, and any
change to a script is mirrored into its man page **in the same session**.

## When to use

- You create a new script in `~/.local/bin/`.
- You edit, rename, or change the CLI surface of an existing script there.
- You are asked to write, fix, or reformat a man page.

Do **not** use this for:
- Throwaway one-liners or scripts outside `~/.local/bin/`.
- Editing the `~/dotfiles/scripts/` copies directly — those are a GitHub mirror
  managed by `dotfiles-sync.sh push`, never edited by hand.

## Hard rules

1. **1:1 pairing.** No script in `~/.local/bin/` is considered done without a
   man page.
2. **Same session.** If the script already has a page, update the page whenever
   you change the script's behaviour, options, defaults, or examples.
3. **Live dir only.** Author the page in `~/.local/share/man/man1/`. The
   `~/dotfiles/configs/man/` tree is a mirror populated by
   `dotfiles-sync.sh push`; never write there directly.
4. **Keep the date current.** The `.TH` date is `YYYY-MM-DD` and reflects the
   last real change.

## Placement and naming

| Thing                    | Value                                                        |
| ------------------------ | ------------------------------------------------------------ |
| Commands                 | `~/.local/share/man/man1/<name>.1`                           |
| Config files             | `~/.local/share/man/man5/<name>.5`                           |
| `<name>`                 | script basename, `.sh` / `.py` stripped, hyphens kept         |
| Compression              | none — write plain, uncompressed `.1` files                   |
| Example                  | `pkg-remove.sh` → `~/.local/share/man/man1/pkg-remove.1`      |

`~/.local/share/man` is already on `manpath`, so a page there is found by
`man <name>` with no extra config.

## Required structure

Start from `template.1` (same folder). A page has these sections in order:

1. `.SH NAME` — `name \- one-line summary` (the summary is lowercase, no
   trailing period).
2. `.SH SYNOPSIS` — invocation forms.
3. `.SH DESCRIPTION` — what it does, defaults, requirements.
4. `.SH OPTIONS` — one `.TP` per flag (omit if the script takes none; say so
   under DESCRIPTION instead).
5. `.SH EXAMPLES` — realistic copy-paste invocations in `.EX`/`.EE`.
6. `.SH SEE ALSO` — comma-separated `.BR name (1)` cross-references.

Add only when they apply: `.SH FILES`, `.SH EXIT STATUS`, `.SH BEHAVIOUR`,
`.SH BUGS`, `.SH AUTHOR`. Use `.SS` for subsections inside a `.SH`.

## Formatting

See `roff-cheatsheet.md` in this folder for the macro table. Non-negotiable
escape rules:

- Literal hyphens/flags are `\-`, never a bare `-` (a bare `-` renders as a
  typographic dash and breaks copy-paste).
- Bold with `\fB…\fR`, italic with `\fI…\fR`. Prefer the `.B` / `.I` / `.BR` /
  `.BI` / `.IR` macros where they read cleanly.
- Paragraph break: `.P`. Bullet list: `.IP \(bu 2`. Indented block: `.RS` …
  `.RE`. Subsection: `.SS`.
- A lone line starting with `.` or `'` is a request — escape it as `\&.` if it
  is meant literally.

## Deploy and verify

After writing or editing a page:

```bash
mandb -u ~/.local/share/man
GROFF_NO_SGR=1 groff -man -Tutf8 ~/.local/share/man/man1/<name>.1 | col -b
```

`GROFF_NO_SGR=1` keeps the output free of ANSI colour codes; `groff` + `col`
renders the page without a pager so formatting and roff errors are visible in
the terminal. Never invoke bare `man <name>` as a check — it opens an
interactive pager and hangs a non-interactive shell.

To sync the page into the GitHub mirror, run `dotfiles-sync.sh push` (it rsyncs
`~/.local/share/man/` → `~/dotfiles/configs/man/`). Do not copy by hand.

## Checklist

- [ ] Page exists at `~/.local/share/man/man1/<name>.1`
- [ ] `.TH` date is today's date
- [ ] `NAME` summary matches the script's purpose
- [ ] Every option in the script appears under `OPTIONS`
- [ ] Examples use the real script name and flags
- [ ] `SEE ALSO` references related pages
- [ ] `mandb -u ~/.local/share/man` run
- [ ] `GROFF_NO_SGR=1 groff -man -Tutf8 … | col -b` renders cleanly
