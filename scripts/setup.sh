#!/bin/bash
# setup.sh - CachyOS KDE Plasma setup script
# Usage:
#   ./setup.sh backup   - back up configs from current machine into ./configs/
#   ./setup.sh install  - install all apps and restore configs from ./configs/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/configs"

# ── Package lists ────────────────────────────────────────────────────────────

PACMAN_PACKAGES=(
  # Productivity / Office
  libreoffice-fresh
  kate
  kcalc
  meld
  digikam
  gimp
  handbrake
  obsidian

  # Media
  vlc
  vlc-plugins-all
  haruna
  gwenview
  ffmpegthumbnailer
  ffmpegthumbs
  spotify-launcher

  # Gaming
  steam
  proton-cachyos
  protontricks
  protonup-qt
  gamescope
  discord
  legcord

  # Browser / Download
  firefox
  jdownloader2

  # Terminal / Dev tools
  ghostty
  alacritty
  neovim
  micro
  git
  go
  gopls
  ripgrep
  btop
  glances
  duf
  fastfetch
  pv

  # Utilities
  localsend
  scrcpy
  kdiskmark
  btrfs-assistant
  snapper
  spectacle
  kdeconnect
  qbittorrent
  pavucontrol
  ufw
  profile-sync-daemon
  easyeffects
  nvtop
  hwloc
)

AUR_PACKAGES=(
  zen-browser-bin
  balena-etcher
  bottles
  linux-wallpaperengine-git
  pkgbrowser
  fuzzy-pkg-finder
  xnviewmp
  losslesscut-bin
  r2modman-bin
  protonvpn-mod-next-gtk
  deadlock-modmanager-bin
)

# ── Config paths to back up / restore ───────────────────────────────────────

declare -A CONFIGS=(
  ["ghostty"]="$HOME/.config/ghostty"
  ["alacritty"]="$HOME/.config/alacritty"
  ["neovim-config"]="$HOME/.config/nvim"
  ["neovim-data"]="$HOME/.local/share/nvim"
  ["btop"]="$HOME/.config/btop"
  ["fastfetch"]="$HOME/.config/fastfetch"
  ["qbittorrent"]="$HOME/.config/qBittorrent"
  ["ripgrep"]="$HOME/.config/ripgrep"
  ["handbrake"]="$HOME/.config/ghb"
  ["xnviewmp"]="$HOME/.config/xnviewmp"
  ["kde-plasma-desktop"]="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  ["kde-plasmarc"]="$HOME/.config/plasmarc"
  ["kde-kwinrc"]="$HOME/.config/kwinrc"
  ["kde-kdeglobals"]="$HOME/.config/kdeglobals"
  ["kde-kglobalshortcutsrc"]="$HOME/.config/kglobalshortcutsrc"
  ["kde-khotkeysrc"]="$HOME/.config/khotkeysrc"
  ["kde-panel"]="$HOME/.config/plasmashellrc"
  ["kde-colors"]="$HOME/.config/Trolltech.conf"
  ["kde-gtk-config"]="$HOME/.config/gtk-3.0"
)

# ── Backup ───────────────────────────────────────────────────────────────────

do_backup() {
  echo ""
  echo "Backing up configs to $CONFIGS_DIR..."
  mkdir -p "$CONFIGS_DIR"

  for key in "${!CONFIGS[@]}"; do
    src="${CONFIGS[$key]}"
    dest="$CONFIGS_DIR/$key"
    if [ -e "$src" ]; then
      rm -rf "$dest"
      cp -r "$src" "$dest"
      echo "  [ok] $key"
    else
      echo "  [skip] $key (not found at $src)"
    fi
  done

  echo ""
  echo "Backup complete. Commit and push the configs/ folder to your GitHub repo."
}

# ── Install ──────────────────────────────────────────────────────────────────

do_install() {
  echo ""
  echo "Installing Paru..."
  sudo pacman -S --needed paru
  echo ""
  echo "Installing pacman packages..."
  sudo pacman -S --needed --noconfirm "${PACMAN_PACKAGES[@]}"

  echo ""
  echo "Installing AUR packages..."
  if command -v yay &>/dev/null; then
    yay -S --needed --noconfirm "${AUR_PACKAGES[@]}"
  elif command -v paru &>/dev/null; then
    paru -S --needed --noconfirm "${AUR_PACKAGES[@]}"
  else
    echo "  [error] No AUR helper found. Install yay or paru first."
    exit 1
  fi

  echo ""
  echo "Restoring configs..."

  if [ ! -d "$CONFIGS_DIR" ]; then
    echo "  [skip] No configs/ directory found. Skipping config restore."
  else
    for key in "${!CONFIGS[@]}"; do
      src="$CONFIGS_DIR/$key"
      dest="${CONFIGS[$key]}"
      if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dest")"
        rm -rf "$dest"
        cp -r "$src" "$dest"
        echo "  [ok] $key"
      else
        echo "  [skip] $key (not in configs/)"
      fi
    done
  fi

  echo ""
  echo "Done. You may want to log out and back in for KDE settings to apply."
}

# ── Entry point ──────────────────────────────────────────────────────────────

case "$1" in
backup)
  do_backup
  ;;
install)
  do_install
  ;;
*)
  echo "Usage: $0 [backup|install]"
  echo ""
  echo "  backup   - Save configs from this machine into ./configs/"
  echo "  install  - Install all packages and restore configs from ./configs/"
  exit 1
  ;;
esac
