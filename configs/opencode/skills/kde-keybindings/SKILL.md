---
name: kde-keybindings
description: Use when reading, changing, adding, removing, or debugging KDE Plasma global keyboard shortcuts/keybindings (hotkeys) from the CLI. Triggers on "kde keybind", "kde shortcut", "global shortcut", "custom shortcut", "command shortcut", "script shortcut", "bind a script to a key", "rebind", "keybinding", "Super", "Meta", "krunner", "kwin", "kglobalshortcutsrc", "always on top", "keep above", "khotkeys", "D-Bus shortcut", or mapping a Super/Alt/Ctrl combo to a KDE action on Wayland. Covers the live org.kde.kglobalaccel D-Bus API, custom command/script shortcuts via .desktop files, and the kglobalshortcutsrc file format (Plasma 5 and 6).
---

# KDE keybindings (global shortcuts)

KDE global shortcuts are stored in `~/.config/kglobalshortcutsrc` and served
at runtime by `kglobalacceld` over D-Bus (service `org.kde.kglobalaccel`). On
Plasma 6 the name is typically owned by `kwin_wayland`; there may be no
separate `kglobalacceld` process, so **do not** look for one to restart. Changes
apply live — no logout, no compositor restart.

## Workflow

1. **Find** what is bound to the combo (grep the rc + query D-Bus).
2. **Resolve** the target action's `actionId` (component + action names).
3. **Apply live** with `setForeignShortcutKeys`.
4. **Verify** both the live state and that the rc file was persisted.

## 1. Read the current state

```bash
# human-readable rc (tabs separate multiple keys in one binding)
grep -nE 'Meta\+Space|Window Above|_launch' ~/.config/kglobalshortcutsrc

# live: list every component
busctl --user tree org.kde.kglobalaccel | grep /component

# live: all actions + keys for one component (--literal; tuple type a(ssssssaiai))
qdbus6 --literal org.kde.kglobalaccel /component/kwin \
  org.kde.kglobalaccel.Component.allShortcutInfos
```

`allShortcutInfos` tuple field order is:
`(actionUnique, actionFriendly, componentUnique, componentFriendly, contextUnique, contextFriendly, keys, defaultKeys)`.

The read-side component object path is the componentUnique with dots replaced by
underscores, e.g. `org.kde.krunner.desktop` -> `/component/org_kde_krunner_desktop`.
The setter, however, lives at a single path: `/kglobalaccel`.

## 2. The setter API (Plasma 6)

Interface `org.kde.KGlobalAccel` at object path `/kglobalaccel`:

```
setForeignShortcutKeys(actionId: as, keys: a(ai)) -> a(ai)
```

Use `setForeignShortcutKeys` — it is exactly what System Settings (`kcm_keys`)
calls, sets the shortcut on behalf of another component, and **persists to
`kglobalshortcutsrc` automatically**. Avoid the flags-based
`setShortcut`/`setShortcutKeys` (flags enum: `SetPresent=1`,
`NoAutoloading=2`, `IsDefault=4`) unless you specifically need them.

### actionId format (CRITICAL)

A 4-element string list, ordered by `KGlobalAccel::actionIdFields`:

```
[ componentUnique, actionUnique, componentFriendly, actionFriendly ]
```

Note the **unusual** order: unique names first, then friendly names. This is
the order `buildActionId()` in the KCM produces. (The enum is
`ComponentUnique=0, ActionUnique=1, ComponentFriendly=2, ActionFriendly=3`.)

Example:
- KWin: `['kwin','Window Above Other Windows','KWin','Keep Window Above Others']`
- KRunner: `['org.kde.krunner.desktop','_launch','KRunner','KRunner']`

### keys format (CRITICAL)

Type `a(ai)`: an array of QKeySequences, where each QKeySequence is itself an
int array **wrapped in a struct**. A single-chord shortcut is `([code],)`:

```
[([268435488],)]                      # one shortcut: Meta+Space
[([16777362],), ([150994993],)]       # two shortcuts: Search, Alt+F2
[]                                    # unbind (empty array)
```

When an action supports multi-key chords, list each chord's ints in the inner
array: `([ctrl,alt],)` etc.

### Applying

```bash
# Bind Super+Space to KWin "Keep Window Above Others"
gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
  --method org.kde.KGlobalAccel.setForeignShortcutKeys \
  "['kwin','Window Above Other Windows','KWin','Keep Window Above Others']" \
  "[([268435488],)]"

# Remove Super+Space from KRunner, keeping its other keys
gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
  --method org.kde.KGlobalAccel.setForeignShortcutKeys \
  "['org.kde.krunner.desktop','_launch','KRunner','KRunner']" \
  "[([16777362],), ([150994993],)]"
```

A successful call prints `()`. A parse error like
`can not parse as value of type 'a(ai)'` almost always means a missing inner
array — remember the `([code],)` shape, not `(code,)`.

## 3. Key-code encoding

A code is `modifiers | Qt::Key`. XOR-free OR.

| Modifier | Value      |
|----------|------------|
| Shift    | `0x02000000` |
| Ctrl     | `0x04000000` |
| Alt      | `0x08000000` |
| Meta/Super | `0x10000000` |

Qt key values (OR onto modifiers):

| Key | Value | Notes |
|-----|-------|-------|
| Space | `0x20` | |
| letters A-Z, digits 0-9 | ASCII (`A`=`0x41`, `0`=`0x30`) | always uppercase for letters |
| Return | `0x01000004` | |
| Escape | `0x01000000` | |
| F1..Fn | `0x01000030 + (n-1)` | F1=`0x01000030`, F2=`0x01000031` |
| Search/Finder | `0x01000092` (`16777362`) | keyboard Search key |
| Print | `0x01000009` | |

Worked values:
- `Meta+Space` = `0x10000000 | 0x20` = `268435488`
- `Alt+F2` = `0x08000000 | 0x01000031` = `150994993`
- `Ctrl+Shift+S` = `0x04000000 | 0x02000000 | 0x53` = `100664403`
- `Meta+Z` = `0x10000000 | 0x5A` = `268435546`

Never hand-guess when an action already has keys: read them back with
`shortcutKeys` (below) and reuse the ints verbatim.

## 4. Verify

```bash
# live state (empty @a(ai) [] means unbound)
gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
  --method org.kde.KGlobalAccel.shortcutKeys \
  "['kwin','Window Above Other Windows','KWin','Keep Window Above Others']"

# persistence
grep -nE 'Window Above Other Windows|Meta\+Space' ~/.config/kglobalshortcutsrc
```

The daemon normally rewrites `kglobalshortcutsrc` on success. If it did not
persist, write the same value with `kwriteconfig6` (see below).

## 5. Custom command / script shortcuts (Plasma 6)

To bind a global hotkey to a **script or command** (rather than a KWin/other
built-in action) you must first make KGlobalAccel aware of it through a
`.desktop` file. This is the modern replacement for the removed KHotKeys
"Custom Shortcuts". Such entries always use the service action unique
`_launch` and appear under `[services][<file>.desktop]` in the rc.

### Step 1 — the desktop file

Create `~/.local/share/applications/<name>.desktop`:

```ini
[Desktop Entry]
Name=Dictate
Exec=/home/user/.local/bin/dictate
Icon=audio-input-microphone
Type=Application
NoDisplay=true
StartupNotify=false
X-KDE-GlobalAccel-CommandShortcut=true
```

- **`X-KDE-GlobalAccel-CommandShortcut=true` is the magic key.** Without it the
  component never registers, even after `kbuildsycoca6` (verified: adding a
  plain `.desktop` produced no component; adding this key did).
- Use an **absolute** `Exec=` path — do not rely on `$HOME` expansion.
- `NoDisplay=true` is fine and does not block registration (as long as the
  command-shortcut key is present); existing `net.local.*` entries use exactly
  this combination.
- `Name=` becomes the componentFriendly used in the `actionId`.

```bash
kbuildsycoca6 --noincremental    # refresh the service database
```

### Step 2 — make the component live

`kglobalaccel` (owned by `kwin_wayland` on Plasma 6) does **not** reliably pick
up a brand new desktop file on its own — `kbuildsycoca6` alone left the
component unregistered. Register it immediately with `doRegister`:

```bash
gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
  --method org.kde.KGlobalAccel.doRegister \
  "['dictate.desktop','_launch','Dictate','Dictate']"
```

Returns `()` on success, and a component appears immediately:

```bash
busctl --user tree org.kde.kglobalaccel | grep -i dictate   # /component/dictate_desktop
```

`doRegister` works when called from a separate process (e.g. `gdbus`); it is not
restricted to the app itself. Otherwise the component is picked up at the next
login, when the desktop files are scanned.

### ⚠ Activation needs a new session — check `isActive`

Registering the component and setting the shortcut is **not enough**: the
component comes up with `isActive == false` and KWin never grabs the key, so the
combo falls through to the focused window (e.g. `Meta+Shift+D` just types `D`).
Command shortcuts present at login report `isActive == true`.

```bash
# false => registered but NOT grabbed (the shortcut will not fire)
gdbus call --session --dest org.kde.kglobalaccel \
  --object-path /component/dictate_desktop \
  --method org.kde.kglobalaccel.Component.isActive
```

There is **no D-Bus method to flip this live** (verified): `doRegister` only
creates the D-Bus object; `setForeignShortcutKeys` only writes config;
`setShortcutKeys` with flags `1` (SetPresent) or `4` (IsDefault) does not
activate it; and the main interface exposes no reload/scan method. In Plasma 6.7
there is no separate daemon to restart either — `/usr/lib/kglobalacceld` runs as
a `static` `plasma-kglobalaccel.service` that exits, and `kwin_wayland` owns
`org.kde.kglobalaccel`.

**Fix: log out and back in** (a session restart, *not* a service restart). At
the next session start the desktop-file scan registers the component as active
and grabs the key from the `[services][<file>.desktop]` rc entry. This is the
same reason a freshly added command shortcut does not work until you re-login —
and it is why `doRegister` is only a convenience for *inspecting/verifying* the
component, not a way to make it live. Do **not** restart
`kwin_wayland`/`plasmashell` to force it.

### Step 3 — bind it

Same setter as any action, with the service `actionId`:

```bash
gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
  --method org.kde.KGlobalAccel.setForeignShortcutKeys \
  "['dictate.desktop','_launch','Dictate','Dictate']" \
  "[([268435546],)]"        # Meta+Z
```

### Step 4 — verify

```bash
# the action, its live keys and defaults
gdbus call --session --dest org.kde.kglobalaccel \
  --object-path /component/dictate_desktop \
  --method org.kde.kglobalaccel.Component.allShortcutInfos
# -> ([('_launch','Dictate','dictate.desktop','Dictate','default',
#       'Default Context',[268435546],@ai [])],)

# persisted rc entry (stored in sorted order among the other [services] groups)
grep -nA1 'services\]\[dictate.desktop\]' ~/.config/kglobalshortcutsrc
```

### Persistence is asynchronous — do NOT double-write

`setForeignShortcutKeys` **does** persist, but the daemon writes
`kglobalshortcutsrc` lazily and in sorted order. An immediate `grep` can show
nothing while the write is still queued, which is easy to mistake for failure.

> Do not "fix" an apparently-missing entry by also hand-editing the file. The
> daemon later adds its own sorted `[services][<name>.desktop]` block and your
> manual block becomes a **duplicate group**. Wait a moment, re-grep, and only
> edit by hand if the daemon genuinely never writes — then remove the extra copy
> (the daemon's is the alphabetically-placed one).

### Finding a free combo / checking conflicts

```bash
# every Meta combo currently in use
grep -oE 'Meta\+[A-Za-z0-9+]+' ~/.config/kglobalshortcutsrc | sort -u

# authoritative: every action holding a given key code
gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
  --method org.kde.KGlobalAccel.getGlobalShortcutsByKey 268435546
# one entry that is ours => the combo is free for us
```

Gotchas discovered the hard way:

- `getGlobalShortcutsByKey` takes a **single int**, not an array: passing
  `[268435546]` fails with `can not parse as value of type 'i'`.
- `isGlobalShortcutAvailable(int, str)` returns `false` when the combo is
  already assigned **even to your own component**, so it is not a clean
  "is this free?" test — use `getGlobalShortcutsByKey` instead.
- A new `.desktop` is only auto-scanned at session start; without `doRegister`
  the shortcut will not work until you log out and back in.
- Worked example: **`Meta+Z` = `0x10000000 | 0x5A` = `268435546`**.

## kglobalshortcutsrc format

Two formats coexist:

- **Normal components** (`[kwin]`, `[plasmashell]`, `[org_kde_powerdevil]`, ...):
  `Action=<current>,<default>,<description>` where `<current>`/`<default>` may be
  tab-separated key lists. Example:
  `Window Above Other Windows=Meta+Space,none,Keep Window Above Others`
- **Service shortcuts** (`[services][<desktop-file>.desktop]`, e.g. KRunner):
  `_launch=<tab-separated keys>` with no default/description. Example:
  `_launch=Search	Alt+F2	Meta+Space` (literal tabs).

Manual edits (only if D-Bus persistence failed):

```bash
kwriteconfig6 --file kglobalshortcutsrc --group kwin \
  --key "Window Above Other Windows" "Meta+Space,none,Keep Window Above Others"

# NOTE: kreadconfig6/kwriteconfig6 mis-handle group names containing "][".
# For [services][...] groups, prefer the D-Bus setter, or edit the file
# directly and preserve literal tab characters between keys.
```

`kreadconfig6 --group 'services][org.kde.krunner.desktop'` returns empty; use
`grep` on the file instead.

## Notes and gotchas

- A bare `Meta` binding (application launcher) is stored as `Meta`; `Meta+Space`
  is distinct and does not conflict with it.
- KWin actions like `Window Above Other Windows` (Keep Above) and
  `Window Below Other Windows` **toggle** the state per focused window.
- Never map the same combo to two actions: unbind it from the old component
  first (a leftover duplicate causes nondeterministic behaviour).
- Always back up before editing: `cp ~/.config/kglobalshortcutsrc{,.bak}`.
- `allShortcutInfos` friendly names are the source for building a correct
  `actionId`; copy them verbatim.
- `qdbus6` can't print `a(ssssssaiai)` — use `--literal`, or use `gdbus`.
