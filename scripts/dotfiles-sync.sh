#!/usr/bin/env bash

# dotfiles-sync.sh
# Push your dotfiles, configs, scripts, and package lists to GitHub.
# Pull them back and restore everything to the correct locations.
#
# Usage:
#   ./dotfiles-sync.sh push [message]
#   ./dotfiles-sync.sh pull

set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

REPO_DIR="${HOME}/dotfiles"
GITHUB_REPO="https://github.com/SlovakianKermit/dotfiles.git"

# ============================================================
# SYMLINK MAP
# Format: "source_path:repo_relative_path"
# These will be symlinked on pull (you actively edit these)
# ============================================================

SYMLINKS=(
  "${HOME}/.config/alacritty:dotfiles/alacritty"
  "${HOME}/.config/fastfetch:dotfiles/fastfetch"
  "${HOME}/.config/ghostty:dotfiles/ghostty"
  "${HOME}/.config/haruna:dotfiles/haruna"
  "${HOME}/.config/btop:dotfiles/btop"
  "${HOME}/.config/nvim:dotfiles/nvim"
  "${HOME}/.config/MangoHud:dotfiles/MangoHud"
  "${HOME}/.config/mpv:dotfiles/mpv"
  "${HOME}/.config/qBittorrent:dotfiles/qBittorrent"
  "${HOME}/.config/yt-dlp:dotfiles/yt-dlp"
  "${HOME}/.config/fish:dotfiles/fish"
  "${HOME}/.config/xnviewmp:dotfiles/xnviewmp"
  "${HOME}/.config/QOwnNotes:dotfiles/QOwnNotes"
  "${HOME}/.config/ripgrep:dotfiles/ripgrep"
)

# ============================================================
# COPY MAP
# Format: "source_path:repo_relative_path"
# These will be copied on push/pull (apps rewrite these)
# ============================================================

COPIES=(
  "${HOME}/.config/easyeffects:configs/easyeffects"
  "${HOME}/.config/dolphinrc:configs/dolphinrc"
  "${HOME}/.config/katerc:configs/katerc"
  "${HOME}/.local/share/konsole:configs/konsole"
  "${HOME}/.config/obsidian:configs/obsidian"
  "${HOME}/.config/kdeconnect:configs/kdeconnect"
  "${HOME}/.config/sunshine:configs/sunshine"
  "${HOME}/.config/copyparty:configs/copyparty"
  "${HOME}/.config/kdeglobals:configs/kde/kdeglobals"
  "${HOME}/.config/kglobalshortcutsrc:configs/kde/kglobalshortcutsrc"
)

# Discord/Electron apps - copy only
ELECTRON_COPIES=(
  "${HOME}/.config/discord:configs/discord"
  "${HOME}/.config/legcord:configs/legcord"
  "${HOME}/.config/vesktop:configs/vesktop"
  "${HOME}/.config/BraveSoftware:configs/brave"
)

# ============================================================
# HELPERS
# ============================================================

log() { echo -e "\033[1;34m[sync]\033[0m $*"; }
ok() { echo -e "\033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die() {
  echo -e "\033[1;31m[error]\033[0m $*" >&2
  exit 1
}

require() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ============================================================
# PUSH
# ============================================================

cmd_push() {
  local msg="${1:-"chore: sync dotfiles $(date '+%Y-%m-%d %H:%M')"}"

  require git
  require paru

  [[ -d "${REPO_DIR}/.git" ]] || die "Repo not found at ${REPO_DIR}. Run setup first."

  log "Generating package lists..."
  mkdir -p "${REPO_DIR}/packages"
  pacman -Qqen >"${REPO_DIR}/packages/pkglist-official.txt"
  pacman -Qqem >"${REPO_DIR}/packages/pkglist-aur.txt"
  ok "Package lists written."

  log "Copying scripts..."
  mkdir -p "${REPO_DIR}/scripts"
  if [[ -d "${HOME}/.local/bin" ]]; then
    cp -r "${HOME}/.local/bin/." "${REPO_DIR}/scripts/" 2>/dev/null || true
    ok "Scripts copied."
  else
    warn "~/.local/bin not found, skipping."
  fi

  log "Syncing symlink targets into repo..."
  for entry in "${SYMLINKS[@]}"; do
    local src="${entry%%:*}"
    local dest="${REPO_DIR}/${entry##*:}"
    if [[ -e "${src}" ]]; then
      mkdir -p "$(dirname "${dest}")"
      # If src is itself a symlink pointing into the repo, skip to avoid loops
      if [[ "$(readlink -f "${src}" 2>/dev/null)" == "${dest}"* ]]; then
        ok "Already linked: ${src}"
        continue
      fi
      rsync -a --delete "${src%/}/" "${dest}/" 2>/dev/null ||
        cp -r "${src}" "${dest}"
      ok "Synced: ${src}"
    else
      warn "Not found, skipping: ${src}"
    fi
  done

  log "Copying copy-only configs..."
  local all_copies=("${COPIES[@]}" "${ELECTRON_COPIES[@]}")
  for entry in "${all_copies[@]}"; do
    local src="${entry%%:*}"
    local dest="${REPO_DIR}/${entry##*:}"
    if [[ -e "${src}" ]]; then
      mkdir -p "$(dirname "${dest}")"
      if [[ -d "${src}" ]]; then
        rsync -a --delete "${src%/}/" "${dest}/" 2>/dev/null ||
          cp -r "${src}" "${dest}"
      else
        cp "${src}" "${dest}"
      fi
      ok "Copied: ${src}"
    else
      warn "Not found, skipping: ${src}"
    fi
  done

  log "Committing and pushing to GitHub..."
  cd "${REPO_DIR}"
  git add -A
  if git diff --cached --quiet; then
    ok "Nothing to commit, already up to date."
  else
    git commit -m "${msg}"
    git push
    ok "Pushed to GitHub."
  fi
}

# ============================================================
# PULL
# ============================================================

cmd_pull() {
  require git
  require paru

  [[ -d "${REPO_DIR}/.git" ]] || die "Repo not found at ${REPO_DIR}. Run setup first."

  log "Pulling latest from GitHub..."
  cd "${REPO_DIR}"
  git pull
  ok "Repo up to date."

  log "Installing official packages..."
  if [[ -f "${REPO_DIR}/packages/pkglist-official.txt" ]]; then
    paru -S --needed --noconfirm - <"${REPO_DIR}/packages/pkglist-official.txt" || true
    ok "Official packages installed."
  else
    warn "pkglist-official.txt not found, skipping."
  fi

  log "Installing AUR packages..."
  if [[ -f "${REPO_DIR}/packages/pkglist-aur.txt" ]]; then
    paru -S --needed --noconfirm - <"${REPO_DIR}/packages/pkglist-aur.txt" || true
    ok "AUR packages installed."
  else
    warn "pkglist-aur.txt not found, skipping."
  fi

  log "Restoring scripts..."
  if [[ -d "${REPO_DIR}/scripts" ]]; then
    mkdir -p "${HOME}/.local/bin"
    cp -r "${REPO_DIR}/scripts/." "${HOME}/.local/bin/"
    chmod +x "${HOME}/.local/bin/"* 2>/dev/null || true
    ok "Scripts restored to ~/.local/bin/"
  else
    warn "scripts/ not found in repo, skipping."
  fi

  log "Creating symlinks for dotfiles..."
  for entry in "${SYMLINKS[@]}"; do
    local src="${entry%%:*}"
    local dest="${REPO_DIR}/${entry##*:}"

    if [[ ! -e "${dest}" ]]; then
      warn "Repo path not found, skipping symlink: ${dest}"
      continue
    fi

    # Backup existing non-symlink
    if [[ -e "${src}" && ! -L "${src}" ]]; then
      warn "Backing up existing: ${src} -> ${src}.bak"
      mv "${src}" "${src}.bak"
    fi

    mkdir -p "$(dirname "${src}")"
    ln -sfn "${dest}" "${src}"
    ok "Linked: ${src} -> ${dest}"
  done

  log "Restoring copy-only configs..."
  local all_copies=("${COPIES[@]}" "${ELECTRON_COPIES[@]}")
  for entry in "${all_copies[@]}"; do
    local src="${entry%%:*}"
    local dest="${REPO_DIR}/${entry##*:}"

    if [[ ! -e "${dest}" ]]; then
      warn "Repo path not found, skipping: ${dest}"
      continue
    fi

    # Backup existing
    if [[ -e "${src}" ]]; then
      warn "Backing up existing: ${src} -> ${src}.bak"
      mv "${src}" "${src}.bak"
    fi

    mkdir -p "$(dirname "${src}")"
    if [[ -d "${dest}" ]]; then
      cp -r "${dest}" "${src}"
    else
      cp "${dest}" "${src}"
    fi
    ok "Restored: ${src}"
  done

  ok "Pull complete. You may want to log out and back in for KDE changes to take effect."
}

# ============================================================
# SETUP
# ============================================================

cmd_setup() {
  require git

  if [[ -d "${REPO_DIR}/.git" ]]; then
    ok "Repo already exists at ${REPO_DIR}."
    return
  fi

  log "Cloning repo to ${REPO_DIR}..."
  git clone "${GITHUB_REPO}" "${REPO_DIR}"

  # Create folder structure if not already present
  mkdir -p \
    "${REPO_DIR}/dotfiles" \
    "${REPO_DIR}/configs/kde" \
    "${REPO_DIR}/scripts" \
    "${REPO_DIR}/packages"

  ok "Setup complete. Run: dotfiles-sync.sh push"
}

# ============================================================
# ENTRYPOINT
# ============================================================

case "${1:-}" in
push) cmd_push "${2:-}" ;;
pull) cmd_pull ;;
setup) cmd_setup ;;
*)
  echo "Usage: $(basename "$0") <push|pull|setup> [commit message]"
  echo ""
  echo "  setup          Clone the repo and prepare the directory structure"
  echo "  push [msg]     Sync everything to GitHub (optional commit message)"
  echo "  pull           Pull from GitHub, install packages, restore configs"
  exit 1
  ;;
esac
