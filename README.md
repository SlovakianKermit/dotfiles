# dotfiles

Personal system configuration, scripts, and package lists for my CachyOS + KDE Plasma setup.

**Hardware**

| Part   | Model                                                        |
| ------ | ------------------------------------------------------------ |
| CPU    | AMD Ryzen 5 3600XT (6C/12T, 3.8–4.6 GHz)                     |
| GPU    | AMD Radeon RX 9070 XT 16 GB (RDNA4 / Navi 48, `amdgpu`+Mesa) |
| RAM    | 16 GB (2×8 GB Corsair Vengeance LPX DDR4-3200)               |
| Board  | MSI B450M Mortar Max (MS-7B89)                               |
| Disk   | Crucial P3 1 TB NVMe (`CT1000P3PSSD8`)                       |
| OS     | CachyOS (rolling), `linux-cachyos`, KDE Plasma 6              |

---

## Structure

```
dotfiles/       Symlinked configs (fish, nvim, btop, mpv, etc.)
  home/         Single-file home dotfiles (.gitconfig, .bashrc, ...)
configs/        Copied configs (KDE, EasyEffects, Dolphin, etc.)
  kde/          Individual Plasma/KWin config files
  autostart/    Session autostart entries
  systemd/      systemd --user units, timers and .wants links
  applications/ Hand-written .desktop launchers
scripts/        Custom scripts from ~/.local/bin/
packages/       Package lists for full system restore
README.md       This file
```

---

## First time setup on a fresh system

### 1. Create the GitHub repo

Go to [github.com/new](https://github.com/new) and create a new repo called `dotfiles`. Set it to private if you prefer. Do not initialise it with a README.

### 2. Install git, rsync and paru

```bash
sudo pacman -S git rsync
```

paru should already be available on CachyOS, but if not:

```bash
sudo pacman -S --needed base-devel
git clone https://aur.archlinux.org/paru.git
cd paru && makepkg -si
```

### 3. Clone this repo

```bash
git clone git@github.com:SlovakianKermit/dotfiles.git ~/dotfiles
```

### 4. Place the sync script

```bash
cp ~/dotfiles/scripts/dotfiles-sync.sh ~/.local/bin/dotfiles-sync
chmod +x ~/.local/bin/dotfiles-sync
```

### 5. Run pull

```bash
dotfiles-sync pull
```

This will:
- Install all packages from the saved lists (Arch, CachyOS, then AUR)
- Symlink actively-edited configs to their correct locations
- Copy KDE, systemd user, autostart and per-app configs back into place
- Restore all scripts to `~/.local/bin/`, pruning any that no longer exist
- Restore the home dotfiles (`.gitconfig`, `.bashrc`, `.zshrc`, …)
- Re-index the custom man pages

Log out and back in after pulling for KDE changes to take effect.

---

## Daily usage

### Push changes to GitHub

```bash
dotfiles-sync push
```

Or with a custom commit message:

```bash
dotfiles-sync push "add vkbasalt crt preset for Dusk"
```

`push` commits, rebases onto `origin`, and then pushes — so pulling this repo
on another machine and pushing back can't leave you with a non-fast-forward.

### Pull on a new/refreshed system

```bash
dotfiles-sync pull
```

---

## What is synced

### Symlinked (live, edits go straight to the repo)

| Path | Description |
|------|-------------|
| `~/.config/fish/` | Fish shell config |
| `~/.config/nvim/` | Neovim / LazyVim |
| `~/.config/alacritty/` | Alacritty terminal |
| `~/.config/ghostty/` | Ghostty terminal |
| `~/.config/btop/` | btop resource monitor |
| `~/.config/fastfetch/` | Fastfetch config |
| `~/.config/MangoHud/` | MangoHud overlay |
| `~/.config/mpv/` | mpv media player |
| `~/.config/qBittorrent/` | qBittorrent |
| `~/.config/haruna/` | Haruna media player |
| `~/.config/containers/` | Podman / Quadlet units |

### Home dotfiles (copied to `dotfiles/home/`)

`.gitconfig`, `.bashrc`, `.bash_profile`, `.bash_logout`, `.zshrc`, `.gtkrc-2.0`

### Copied (app rewrites these, synced on each push)

| Path | Description |
|------|-------------|
| `~/.config/kdeglobals` | KDE global settings (theme, fonts, colour scheme) |
| `~/.config/kglobalshortcutsrc` | Global keyboard shortcuts |
| `~/.config/kwinrc` | KWin: virtual desktops, tiling, HDR, effects |
| `~/.config/kwinrulesrc` | KWin window rules |
| `~/.config/kcminputrc` | Keyboard repeat, mouse/touchpad tuning |
| `~/.config/kscreenlockerrc` | Screen locker |
| `~/.config/powerdevilrc` | Power management |
| `~/.config/powermanagementprofilesrc` | Power profiles |
| `~/.config/mimeapps.list` | Default applications |
| `~/.config/autostart/` | Session autostart entries |
| `~/.config/systemd/` | `systemd --user` units, timers, `.wants` |
| `~/.local/share/applications/` | Custom desktop launchers |
| `~/.local/share/color-schemes/` | KDE colour schemes |
| `~/.config/gtk-3.0/`, `~/.config/gtk-4.0/` | GTK theme CSS |
| `~/.config/pipewire/`, `~/.config/wireplumber/` | Audio drop-ins (EQ, Bluetooth) |
| `~/.config/easyeffects/` | EasyEffects EQ profiles |
| `~/.config/dolphinrc` | Dolphin file manager |
| `~/.config/katerc` | Kate editor |
| `~/.config/xnviewmp/` | XnView MP settings, layouts and key map (thumbnail cache and image DB stay local) |
| `~/.local/share/konsole/` | Konsole profiles |
| `~/.config/obsidian/obsidian.json` | Obsidian vault list (nothing else) |
| `~/.config/kdeconnect/` | KDE Connect (device keys excluded) |
| `~/.config/sunshine/` | Sunshine game streaming (local only) |
| `~/.config/copyparty/` | Copyparty file server (key/salts excluded) |
| `~/.config/aria2/` | aria2 downloader |
| `~/.config/jellyfin-mpv-shim/` | Jellyfin mpv shim (credentials excluded) |
| `~/.config/micro/` | micro settings and keybindings |
| `~/.config/vesktop/` | Vesktop settings, themes and custom CSS (session/caches excluded) |

### Not synced on purpose

`plasma-org.kde.plasma.desktop-appletsrc` (panel layout — faster to redo than to
debug), `kwinoutputconfig.json` (monitor EDID/layout), Klipper clipboard history,
`~/.ssh/`, `~/.config/gallery-dl/` (contains a Pixiv session cookie), the Brave
and Discord profiles (browser/messenger state, not config), XnView's
`Thumb.db` (6 GB thumbnail cache) and `XnView.db` (image categories/ratings),
and every `.bak` of anything. `~/.config/sunshine/` is rsynced but gitignored,
so it stays local.

### Secrets are never committed
`rsync` excludes **and** `.gitignore` both block: the Copyparty TLS key, salts,
`iphash` and session DB; the KDE Connect certificate and private key; Jellyfin
`cred.json`; opencode `auth.json`. `~/.config/aur-review/key` is outside every
sync list. KDE Connect re-pairs on a new machine, so nothing is lost.

### Scripts

Everything in `~/.local/bin/` is mirrored into `scripts/` and restored on pull
with `rsync --delete`, so deleted scripts don't linger. The VR CyberDeck portable
app and any AppImage are excluded from the mirror.

### Packages

| File | Contents |
|------|----------|
| `packages/pkglist-arch.txt` | Official Arch repo packages |
| `packages/pkglist-cachyos.txt` | Packages from the CachyOS repo |
| `packages/pkglist-aur.txt` | AUR / foreign packages |

---

## Notes

- Every restore backs up an existing file or directory to `<path>.bak.YYYYMMDD-HHMMSS`
  before overwriting, so nothing is silently destroyed.
- Package install on pull uses `--needed` so already-installed packages are skipped,
  and hardware-specific drivers/microcode are filtered out (install the equivalent
  for the target machine).
- Man pages live in `~/.local/share/man` and are mirrored to `configs/man`.
  Every script in `~/.local/bin` should have one; currently missing:
  `me3`, `oc-search-delete`, `oc-search-header`, `supermemory-server`.
