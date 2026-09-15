# Roff (man) macro cheatsheet

Macros used across Killian's existing pages. Each request goes at the start of a
line; text after it is the argument.

## Structure

| Macro | Purpose |
| ----- | ------- |
| `.TH NAME 1 "YYYY-MM-DD" "scriptname" "User Commands"` | Title header. First macro in the file. `1` = section. |
| `.SH TITLE` | Major section (NAME, SYNOPSIS, DESCRIPTION, OPTIONS, EXAMPLES, SEE ALSO, …). |
| `.SS Title` | Subsection inside a `.SH`. |
| `.P` | Paragraph break (blank line + indent). |
| `.PP` | Same as `.P`. |

## Lists, options, indentation

| Macro | Purpose |
| ----- | ------- |
| `.TP` | Tagged paragraph: the next line is the tag, following lines are the indented body. Used for every option. |
| `.IP \(bu 2` | Bullet item (`\(bu` = bullet), with 2-unit indent. Body follows. |
| `.IP "label" 4` | Tagged item with a literal label. |
| `.RS` / `.RE` | Start / end an indented block (nest option explanations, lists). |

## Fonts

| Macro | Rendered |
| ----- | -------- |
| `.B text` | **bold** |
| `.I text` | *italic* |
| `.BR a (1)` | alternating bold/roman: **a** (1) — the cross-reference form |
| `.BI \-f " FILE"` | alternating bold/italic: **-f** *FILE* |
| `.IR file .ext` | alternating italic/roman |
| `\fBbold\fR` | inline bold |
| `\fIitalic\fR` | inline italic |

## Literal / example blocks

```
.EX
command --with --args
.EE
```

`.EX` / `.EE` bracket a preformatted block (no fill, no hyphenation).

## Escaping

| Want | Write | Why |
| ---- | ----- | --- |
| `-` (flag/hyphen) | `\-` | bare `-` becomes a typographic dash |
| `~` | `\~` | prevents line-break at tilde |
| space that won't collapse | `\ ` | e.g. `~/.local/bin` |
| a literal line starting with `.` | `\&.` | otherwise it's parsed as a request |
| `(1)` after a command | `.BR name (1)` | standard cross-reference |
| literal backslash | `\\` | escape the escape |

## Common gotchas

- Put a space between a macro and its argument: `.B ffmpeg`, not `.Bffmpeg`.
- `.TP` needs the tag on the **next** line; a blank line there produces an empty
  tag.
- A blank line alone does **not** start a new paragraph — use `.P` / `.PP`.
- The `NAME` section must be exactly ``name \- summary``; tools and the man
  index parse it.
- Section `1` = user commands, `5` = file formats/config files.
- Render-check with `groff -man -Tutf8 file.1 | col -b`; never bare `man` in a
  non-interactive shell.
