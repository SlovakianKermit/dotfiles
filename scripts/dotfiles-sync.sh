#!/usr/bin/env bash

# dotfiles-sync.sh
# Push your dotfiles, configs, scripts, and package lists to GitHub.
# Pull them back and restore everything to the correct locations.
#
# Usage:
#   ./dotfiles-sync.sh push [message]            [--dry-run]
#   ./dotfiles-sync.sh pull                       [--dry-run] [--skip-cachyos]
#   ./dotfiles-sync.sh setup

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

declare -A RSYNC_EXCLUDES=(
  ["dotfiles/qBittorrent"]="BT_backup/ logs/ rss/ search/ GeoIP/ qBittorrent.conf qBittorrent-data.conf"
)

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
  "${HOME}/.local/share/man:configs/man"
)

ELECTRON_COPIES=(
  "${HOME}/.config/discord:configs/discord"
  "${HOME}/.config/legcord:configs/legcord"
  "${HOME}/.config/vesktop:configs/vesktop"
  "${HOME}/.config/BraveSoftware:configs/brave"
)

# ============================================================
# HARDWARE-SPECIFIC PACKAGES (skipped on pull)
# Install equivalents manually on the target system.
# ============================================================

declare -a HARDWARE_EXCLUDES=(
  # AMD GPU
  "vulkan-radeon" "lib32-vulkan-radeon" "amdvlk" "lib32-amdvlk"
  "xv86-video-amdgpu" "radeontop" "rocm-opencl-runtime" "rocm-hip-runtime"
  "libva-mesa-driver" "lib32-libva-mesa-driver" "mesa-vdpau" "lib32-mesa-vdpau"
  "rocm-core" "rocm-smi-lib" "hip-runtime-amd" "composable-kernel"
  # AMD CPU / misc
  "amd-ucode"
  # NVIDIA
  "nvidia-dkms" "nvidia-utils" "lib32-nvidia-utils" "nvidia-settings"
  "libva-nvidia-driver" "nvidia-prime" "nvtop"
  # Intel GPU
  "vulkan-intel" "intel-media-driver" "libva-intel-driver" "intel-ucode"
  # CachyOS vendor kernels
  "linux-cachyos" "linux-cachyos-headers" "linux-cachyos-nvidia"
)

# ============================================================
# HELPERS
# ============================================================

log()   { echo -e "\033[1;34m[sync]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ok]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[warn]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

require() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

is_dry_run()  { $DRY_RUN; }

# ============================================================
# CACHYOS REPOSITORY SETUP
# ============================================================

CACHYOS_KEYRING_URL="https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-latest.pkg.tar.zst"
CACHYOS_MIRRORLIST_URL="https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-latest.pkg.tar.zst"
CACHYOS_PACMAN_CONF_SECTION="

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist"

has_cachyos_repos() {
  grep -q '^\[cachyos\]' /etc/pacman.conf 2>/dev/null
}

add_cachyos_repos() {
  if has_cachyos_repos; then
    ok "CachyOS repositories already configured."
    return 0
  fi

  if $SKIP_CACHYOS; then
    warn "--skip-cachyos: not adding CachyOS repositories."
    return 0
  fi

  if ! grep -q '^ID=arch' /etc/os-release 2>/dev/null; then
    warn "Not running Arch Linux, skipping CachyOS repository setup."
    return 0
  fi

  log "Adding CachyOS repositories..."

  if $DRY_RUN; then
    log "Would download and install: cachyos-keyring, cachyos-mirrorlist"
    log "Would append [cachyos] to /etc/pacman.conf"
    return 0
  fi

  require sudo
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf ${tmpdir}" RETURN

  log "Downloading cachyos-keyring..."
  curl -fsSL "${CACHYOS_KEYRING_URL}" -o "${tmpdir}/cachyos-keyring.pkg.tar.zst" ||
    die "Failed to download cachyos-keyring"

  log "Downloading cachyos-mirrorlist..."
  curl -fsSL "${CACHYOS_MIRRORLIST_URL}" -o "${tmpdir}/cachyos-mirrorlist.pkg.tar.zst" ||
    die "Failed to download cachyos-mirrorlist"

  sudo pacman -U --noconfirm "${tmpdir}/cachyos-keyring.pkg.tar.zst" ||
    die "Failed to install cachyos-keyring"
  sudo pacman -U --noconfirm "${tmpdir}/cachyos-mirrorlist.pkg.tar.zst" ||
    die "Failed to install cachyos-mirrorlist"

  # Append repo section if not already present
  if ! has_cachyos_repos; then
    echo "${CACHYOS_PACMAN_CONF_SECTION}" | sudo tee -a /etc/pacman.conf >/dev/null
    sudo pacman -Sy
  fi

  ok "CachyOS repositories added."
}

# ============================================================
# PACKAGE INSTALL HELPER
# ============================================================

install_pkglist() {
  local mgr="$1" file="$2" label="$3"

  if [[ ! -f "${file}" ]]; then
    warn "${label} list not found, skipping."
    return 0
  fi

  if [[ ! -s "${file}" ]]; then
    ok "${label} list is empty, skipping."
    return 0
  fi

  # If cachyos list but repos not present (and not skipped), that's a problem
  if [[ "${label}" == "cachyos" ]] && ! has_cachyos_repos && $SKIP_CACHYOS; then
    warn "--skip-cachyos: skipping CachyOS packages."
    cat "${file}" >>"${REPO_DIR}/packages/skipped-cachyos.txt"
    return 0
  fi

  local failed=0 skipped=0 installed=0
  local total
  total="$(wc -l <"${file}")"

  log "Installing ${label} packages (${total} total)..."

  while read -r pkg; do
    [[ -z "$pkg" ]] && continue

    # Filter hardware-specific packages
    local hw_skip=false
    for excl in "${HARDWARE_EXCLUDES[@]}"; do
      [[ "$pkg" == "$excl" ]] && { hw_skip=true; break; }
    done
    if $hw_skip; then
      warn "Skipping (hardware-specific): ${pkg}"
      echo "${pkg}" >>"${REPO_DIR}/packages/skipped-hardware.txt"
      ((skipped++)) || true
      continue
    fi

    if $DRY_RUN; then
      log "Would install: ${pkg}"
      ((installed++)) || true
      continue
    fi

    log "Installing: ${pkg}"
    if ${mgr} -S --needed --noconfirm "${pkg}"; then
      ok "Installed: ${pkg}"
      ((installed++)) || true
    else
      warn "Failed: ${pkg}"
      echo "${pkg}" >>"${REPO_DIR}/packages/failed.txt"
      ((failed++)) || true
    fi
  done <"${file}"

  log "${label}: ${installed} installed, ${skipped} skipped, ${failed} failed"
}

# ============================================================
# BACKUP HELPER (avoids stale .bak overwrites)
# ============================================================

backup_if_real() {
  local src="$1"
  if [[ -e "${src}" && ! -L "${src}" ]]; then
    local bak="${src}.bak.$(date +%Y%m%d-%H%M%S)"
    if $DRY_RUN; then
      log "Would backup: ${src} -> ${bak}"
    else
      warn "Backing up existing: ${src} -> ${bak}"
      mv "${src}" "${bak}"
    fi
  fi
}

# ============================================================
# PUSH
# ============================================================

cmd_push() {
  local msg="${1:-"chore: sync dotfiles $(date '+%Y-%m-%d %H:%M')"}"

  require git
  require pacman

  [[ -d "${REPO_DIR}/.git" ]] || die "Repo not found at ${REPO_DIR}. Run setup first."

  log "Generating package lists..."
  mkdir -p "${REPO_DIR}/packages"

  # Split official packages: Arch repos vs CachyOS repos
  if pacman -Slq cachyos &>/dev/null; then
    pacman -Qqen | sort >"/tmp/pkglist-all.txt"
    pacman -Slq cachyos 2>/dev/null | sort >"/tmp/pkglist-cachyos-repo.txt"
    comm -23 "/tmp/pkglist-all.txt" "/tmp/pkglist-cachyos-repo.txt" >"${REPO_DIR}/packages/pkglist-arch.txt"
    comm -12 "/tmp/pkglist-all.txt" "/tmp/pkglist-cachyos-repo.txt" >"${REPO_DIR}/packages/pkglist-cachyos.txt"
    rm -f "/tmp/pkglist-all.txt" "/tmp/pkglist-cachyos-repo.txt"
  else
    warn "CachyOS repos not found, all official packages saved to pkglist-arch.txt."
    pacman -Qqen >"${REPO_DIR}/packages/pkglist-arch.txt"
    : >"${REPO_DIR}/packages/pkglist-cachyos.txt"
  fi
  pacman -Qqem >"${REPO_DIR}/packages/pkglist-aur.txt"
  ok "Package lists written."

  # Clear stale failure logs from previous pushes
  : >"${REPO_DIR}/packages/failed.txt"
  : >"${REPO_DIR}/packages/skipped-hardware.txt"
  : >"${REPO_DIR}/packages/skipped-cachyos.txt"

  log "Copying scripts..."
  mkdir -p "${REPO_DIR}/scripts"
  if [[ -d "${HOME}/.local/bin" ]]; then
    if $DRY_RUN; then
      log "Would copy scripts from ~/.local/bin/"
    else
      cp -r "${HOME}/.local/bin/." "${REPO_DIR}/scripts/" 2>/dev/null || true
      ok "Scripts copied."
    fi
  else
    warn "~/.local/bin not found, skipping."
  fi

  log "Syncing symlink targets into repo..."
  for entry in "${SYMLINKS[@]}"; do
    local src="${entry%%:*}"
    local dest="${REPO_DIR}/${entry##*:}"
    if [[ -e "${src}" ]]; then
      mkdir -p "$(dirname "${dest}")"
      if [[ "$(readlink -f "${src}" 2>/dev/null)" == "${dest}"* ]]; then
        ok "Already linked: ${src}"
        continue
      fi
      local rsync_excludes=""
      if [[ -n "${RSYNC_EXCLUDES[${entry##*:}]:-}" ]]; then
        for pat in ${RSYNC_EXCLUDES[${entry##*:}]}; do
          rsync_excludes+=" --exclude=${pat}"
        done
      fi
      if $DRY_RUN; then
        log "Would rsync: ${src} -> ${dest}${rsync_excludes}"
      elif rsync -a --delete ${rsync_excludes} "${src%/}/" "${dest}/" 2>/dev/null; then
        ok "Synced: ${src}"
      else
        warn "rsync failed, falling back to cp: ${src}"
        cp -r "${src}" "${dest}"
        ok "Copied: ${src} (fallback)"
      fi
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
      if $DRY_RUN; then
        log "Would copy: ${src} -> ${dest}"
        continue
      fi
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

  if $DRY_RUN; then
    log "Dry run: skipping git commit/push."
    ok "Dry run complete."
    return
  fi

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

  [[ -d "${REPO_DIR}/.git" ]] || die "Repo not found at ${REPO_DIR}. Run setup first."

  log "Pulling latest from GitHub..."
  cd "${REPO_DIR}"
  git pull
  ok "Repo up to date."

  # Clear stale failure logs
  : >"${REPO_DIR}/packages/failed.txt"
  : >"${REPO_DIR}/packages/skipped-hardware.txt"
  : >"${REPO_DIR}/packages/skipped-cachyos.txt"

  # Add CachyOS repos if needed
  add_cachyos_repos

  # Install package lists
  install_pkglist "sudo pacman" "${REPO_DIR}/packages/pkglist-arch.txt"    "arch"
  install_pkglist "sudo pacman" "${REPO_DIR}/packages/pkglist-cachyos.txt" "cachyos"

  if [[ -f "${REPO_DIR}/packages/pkglist-aur.txt" && -s "${REPO_DIR}/packages/pkglist-aur.txt" ]]; then
    require paru
    install_pkglist "paru" "${REPO_DIR}/packages/pkglist-aur.txt" "aur"
  else
    warn "AUR package list not found or empty, skipping."
  fi

  # Report failures
  if [[ -s "${REPO_DIR}/packages/failed.txt" ]]; then
    warn "Some packages failed to install. See ${REPO_DIR}/packages/failed.txt"
  fi
  if [[ -s "${REPO_DIR}/packages/skipped-hardware.txt" ]]; then
    warn "Hardware-specific packages skipped. See ${REPO_DIR}/packages/skipped-hardware.txt"
  fi
  if [[ -s "${REPO_DIR}/packages/skipped-cachyos.txt" ]]; then
    warn "CachyOS packages skipped. See ${REPO_DIR}/packages/skipped-cachyos.txt"
  fi

  log "Restoring scripts..."
  if [[ -d "${REPO_DIR}/scripts" ]]; then
    mkdir -p "${HOME}/.local/bin"
    if $DRY_RUN; then
      log "Would restore scripts to ~/.local/bin/"
    else
      cp -r "${REPO_DIR}/scripts/." "${HOME}/.local/bin/"
      chmod +x "${HOME}/.local/bin/"* 2>/dev/null || true
      ok "Scripts restored to ~/.local/bin/"
    fi
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

    backup_if_real "${src}"

    if $DRY_RUN; then
      log "Would link: ${src} -> ${dest}"
      continue
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

    backup_if_real "${src}"

    if $DRY_RUN; then
      log "Would restore: ${src}"
      continue
    fi

    mkdir -p "$(dirname "${src}")"
    if [[ -d "${dest}" ]]; then
      cp -r "${dest}" "${src}"
    else
      cp "${dest}" "${src}"
    fi
    ok "Restored: ${src}"
  done

  if command -v mandb &>/dev/null && [[ -d "${HOME}/.local/share/man" ]]; then
    if $DRY_RUN; then
      log "Would update man database"
    else
      mandb -u "${HOME}/.local/share/man" 2>/dev/null || true
      ok "Updated man database."
    fi
  fi

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

DRY_RUN=false
SKIP_CACHYOS=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true;       shift ;;
    --skip-cachyos)  SKIP_CACHYOS=true;  shift ;;
    *) break ;;
  esac
done

case "${1:-}" in
  push) cmd_push "${2:-}" ;;
  pull) cmd_pull ;;
  setup) cmd_setup ;;
  *)
    echo "Usage: $(basename "$0") [--dry-run] [--skip-cachyos] <push|pull|setup> [commit message]"
    echo ""
    echo "  setup           Clone the repo and prepare the directory structure"
    echo "  push [msg]      Sync everything to GitHub (optional commit message)"
    echo "  pull            Pull from GitHub, install packages, restore configs"
    echo ""
    echo "  --dry-run       Show what would happen, don't change anything"
    echo "  --skip-cachyos  Don't add CachyOS repos; skip its packages on pull"
    exit 1
    ;;
esac
