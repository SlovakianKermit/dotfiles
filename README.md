# dotfiles

Personal system configuration, scripts, and package lists for my CachyOS + KDE Plasma setup.

**Hardware:** Ryzen 5 3600XT, RTX 3060 Ti, 16GB RAM

---

## Structure

```
dotfiles/       Symlinked configs (fish, nvim, btop, mpv, etc.)
configs/        Copied configs (KDE, EasyEffects, Dolphin, etc.)
  kde/          Plasma-specific configs
scripts/        Custom scripts from ~/.local/bin/
packages/       Package lists for full system restore
README.md       This file
```

---

## First time setup on a fresh system

### 1. Create the GitHub repo

Go to [github.com/new](https://github.com/new) and create a new repo called `dotfiles`. Set it to private if you prefer. Do not initialise it with a README.

### 2. Install git and paru

```bash
sudo pacman -S git
```

paru should already be available on CachyOS, but if not:

```bash
sudo pacman -S --needed base-devel
git clone https://aur.archlinux.org/paru.git
cd paru && makepkg -si
```

### 3. Clone this repo

```bash
git clone https://github.com/YOUR_USERNAME/dotfiles.git ~/dotfiles
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
- Install all packages from the saved lists via paru
- Symlink actively-edited configs to their correct locations
- Copy KDE and other app configs back into place
- Restore all scripts to `~/.local/bin/`

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

### Pull on a new/refreshed system

```bash
dotfiles-sync pull
```

---

## What is synced

### Symlinked (live, edits go straight to repo)

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
| `~/.config/yt-dlp/` | yt-dlp config |
| `~/.config/xnviewmp/` | XnView MP image browser |
| `~/.config/QOwnNotes/` | QOwnNotes |
| `~/.config/ripgrep/` | ripgrep config |
| `~/.config/haruna/` | Haruna media player |

### Copied (app rewrites these, synced on each push)

| Path | Description |
|------|-------------|
| `~/.config/easyeffects/` | EasyEffects EQ profiles |
| `~/.config/dolphinrc` | Dolphin file manager |
| `~/.config/katerc` | Kate editor |
| `~/.local/share/konsole/` | Konsole profiles |
| `~/.config/obsidian/` | Obsidian |
| `~/.config/kdeconnect/` | KDE Connect |
| `~/.config/sunshine/` | Sunshine game streaming |
| `~/.config/copyparty/` | Copyparty file server |
| `~/.config/kdeglobals` | KDE global settings (theme, fonts, colour scheme) |
| `~/.config/kglobalshortcutsrc` | Global keyboard shortcuts |
| `~/.config/discord/` | Discord |
| `~/.config/legcord/` | Legcord |
| `~/.config/vesktop/` | Vesktop |
| `~/.config/BraveSoftware/` | Brave browser |

### Scripts

Everything in `~/.local/bin/` is copied into `scripts/` and restored on pull.

### Packages

| File | Contents |
|------|----------|
| `packages/pkglist-official.txt` | Official repo packages |
| `packages/pkglist-aur.txt` | AUR packages |

---

## Notes

- Only `kdeglobals` and `kglobalshortcutsrc` are saved from KDE. Panel layout, kwin, and Plasma shell configs are intentionally excluded as they are risky to restore across KDE versions and easy to set up fresh.
- Electron apps (Brave, Discord, Legcord, Vesktop) are also copies for the same reason.
- The script backs up any existing config to `<path>.bak` before overwriting on pull, so nothing is silently destroyed.
- Package install on pull uses `--needed` so already-installed packages are skipped.
