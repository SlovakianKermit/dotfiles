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
  # XnView MP: only ini/layout files are config. Thumb.db is a multi-gigabyte
  # thumbnail cache and XnView.db is user data — both stay on this machine.
  ["configs/xnviewmp"]="Thumb.db *.db *.db-wal *.db-shm"
  # auth.json holds provider credentials; never commit it.
  ["configs/opencode"]="node_modules/ package.json package-lock.json bun.lock .gitignore auth.json"
  # Copyparty: TLS private key, password salts and session state.
  ["configs/copyparty"]="cert.pem *-salt.txt iphash sessions.db sessions.db.lock"
  # KDE Connect: device identity, must be regenerated per machine.
  ["configs/kdeconnect"]="certificate.pem privateKey.pem"
  # Custom launchers: wine registration noise and generated caches.
  ["configs/applications"]="wine/ wine-*.desktop discord-*.desktop mimeinfo.cache mimeapps.list"
  # micro ships 650K of upstream syntax files; only the user config matters.
  ["configs/micro"]="syntax/ buffers/"
  # mandb writes a binary index next to the pages; it is rebuilt on pull.
  ["configs/man"]="index.db"
  # Jellyfin mpv shim stores server credentials here.
  ["configs/jellyfin-mpv-shim"]="cred.json"
  # Electron apps: only settings/Prefs are worth keeping, not the caches.
  # NB: patterns are word-split on spaces, so multi-word dirs use a glob.
  ["configs/vesktop"]="sessionData/ Cache/ Code*Cache/ GPUCache/ DawnGraphiteCache/ DawnWebGPUCache/ Crashpad/ logs/ Service*Worker/ Local*Storage/ IndexedDB/ blob_storage/"
  ["configs/legcord"]="sessionData/ Cache/ Code*Cache/ GPUCache/ DawnGraphiteCache/ DawnWebGPUCache/ Crashpad/ logs/ Service*Worker/ Local*Storage/ IndexedDB/ blob_storage/"
  ["configs/discord"]="Cache/ Code*Cache/ GPUCache/ DawnGraphiteCache/ DawnWebGPUCache/ Crashpad/ logs/ Service*Worker/ Local*Storage/ IndexedDB/ blob_storage/"
  ["configs/brave"]="component_crx_cache/ Safe*/ OnDevice*/ ShaderCache/ GrShaderCache/ GraphiteDawnCache/ Default/Cache/ Default/Code*Cache/ Default/GPUCache/ Default/Service*Worker/ Default/Extensions/ Default/IndexedDB/ Default/Local*Storage/"
  # ~/.local/bin is the scripts source; large portable apps (e.g. VR CyberDeck,
  # run from this dir) must never be swept into the repo. NB: patterns cannot
  # contain spaces (the list is word-split), hence the glob.
  ["scripts"]="VR*CyberDeck* *.AppImage"
)

# Patterns excluded from every rsync: local backups and runtime caches that
# should never reach the repository.
GLOBAL_EXCLUDES=(
  "*.bak"
  "*.bak.*"
  "*.bak-*"
  "__pycache__/"
  "*.pyc"
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
  "${HOME}/.config/fish:dotfiles/fish"
  "${HOME}/.config/containers:dotfiles/containers"
)

# ============================================================
# COPY MAP
# Format: "source_path:repo_relative_path"
# These will be copied on push/pull (apps rewrite these)
# ============================================================

COPIES=(
  # --- home dotfiles (single files) ---
  "${HOME}/.gitconfig:dotfiles/home/gitconfig"
  "${HOME}/.bashrc:dotfiles/home/bashrc"
  "${HOME}/.bash_profile:dotfiles/home/bash_profile"
  "${HOME}/.bash_logout:dotfiles/home/bash_logout"
  "${HOME}/.zshrc:dotfiles/home/zshrc"
  "${HOME}/.gtkrc-2.0:dotfiles/home/gtkrc-2.0"
  # --- KDE ---
  "${HOME}/.config/kdeglobals:configs/kde/kdeglobals"
  "${HOME}/.config/kglobalshortcutsrc:configs/kde/kglobalshortcutsrc"
  "${HOME}/.config/kwinrc:configs/kde/kwinrc"
  "${HOME}/.config/kwinrulesrc:configs/kde/kwinrulesrc"
  "${HOME}/.config/kcminputrc:configs/kde/kcminputrc"
  "${HOME}/.config/kscreenlockerrc:configs/kde/kscreenlockerrc"
  "${HOME}/.config/powerdevilrc:configs/kde/powerdevilrc"
  "${HOME}/.config/powermanagementprofilesrc:configs/kde/powermanagementprofilesrc"
  "${HOME}/.config/mimeapps.list:configs/kde/mimeapps.list"
  # --- session / autostart / user services ---
  "${HOME}/.config/autostart:configs/autostart"
  "${HOME}/.config/systemd:configs/systemd"
  "${HOME}/.local/share/applications:configs/applications"
  # --- theming and audio ---
  "${HOME}/.local/share/color-schemes:configs/color-schemes"
  "${HOME}/.config/gtk-3.0:configs/gtk-3.0"
  "${HOME}/.config/gtk-4.0:configs/gtk-4.0"
  "${HOME}/.config/pipewire:configs/pipewire"
  "${HOME}/.config/wireplumber:configs/wireplumber"
  # --- app configs ---
  "${HOME}/.config/easyeffects:configs/easyeffects"
  "${HOME}/.config/dolphinrc:configs/dolphinrc"
  "${HOME}/.config/katerc:configs/katerc"
  "${HOME}/.local/share/konsole:configs/konsole"
  "${HOME}/.config/xnviewmp:configs/xnviewmp"
  "${HOME}/.config/obsidian/obsidian.json:configs/obsidian/obsidian.json"
  "${HOME}/.config/kdeconnect:configs/kdeconnect"
  "${HOME}/.config/sunshine:configs/sunshine"
  "${HOME}/.config/copyparty:configs/copyparty"
  "${HOME}/.config/aria2:configs/aria2"
  "${HOME}/.config/jellyfin-mpv-shim:configs/jellyfin-mpv-shim"
  "${HOME}/.config/micro:configs/micro"
  "${HOME}/.local/share/man:configs/man"
  "${HOME}/.config/opencode:configs/opencode"
)

ELECTRON_COPIES=(
  # Discord and Legcord are not installed on this machine; uncomment when they
  # are (nothing is pushed for a missing source anyway).
  # "${HOME}/.config/discord:configs/discord"
  # "${HOME}/.config/legcord:configs/legcord"
  # Vesktop settings only: sessionData/ and the caches are excluded, leaving
  # settings.json, state.json and themes/ (about 30K).
  "${HOME}/.config/vesktop:configs/vesktop"
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
  "linux-cachyos" "linux-cachyos-headers" "linux-cachyos-lts"
  "linux-cachyos-lts-headers" "linux-cachyos-nvidia"
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

# Build the rsync --exclude arguments for a repo-relative destination path:
# the global backups/caches list plus any path-specific patterns.
rsync_exclude_args() {
  local rel="$1" pat
  for pat in "${GLOBAL_EXCLUDES[@]}"; do
    printf ' --exclude=%s' "${pat}"
  done
  if [[ -n "${RSYNC_EXCLUDES[${rel}]:-}" ]]; then
    for pat in ${RSYNC_EXCLUDES[${rel}]}; do
      printf ' --exclude=%s' "${pat}"
    done
  fi
}

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
  require rsync

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

  log "Syncing scripts..."
  mkdir -p "${REPO_DIR}/scripts"
  if [[ -d "${HOME}/.local/bin" ]]; then
    local script_excludes
    script_excludes="$(rsync_exclude_args scripts)"
    if $DRY_RUN; then
      log "Would rsync: ~/.local/bin/ -> scripts/${script_excludes}"
    elif rsync -a --delete --delete-excluded ${script_excludes} "${HOME}/.local/bin/" "${REPO_DIR}/scripts/"; then
      ok "Scripts synced."
    else
      warn "rsync failed, falling back to cp: ~/.local/bin"
      cp -a "${HOME}/.local/bin/." "${REPO_DIR}/scripts/" 2>/dev/null || true
      ok "Scripts copied (fallback)."
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
      local rsync_excludes
      rsync_excludes="$(rsync_exclude_args "${entry##*:}")"
      if $DRY_RUN; then
        log "Would rsync: ${src} -> ${dest}${rsync_excludes}"
      elif rsync -a --delete --delete-excluded ${rsync_excludes} "${src%/}/" "${dest}/"; then
        ok "Synced: ${src}"
      else
        warn "rsync failed, falling back to cp: ${src}"
        cp -a "${src%/}/." "${dest}/"
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
      local rsync_excludes
      rsync_excludes="$(rsync_exclude_args "${entry##*:}")"
      if [[ -d "${src}" ]]; then
        rsync -a --delete --delete-excluded ${rsync_excludes} "${src%/}/" "${dest}/" ||
          cp -a "${src%/}/." "${dest}/"
      else
        cp -a "${src}" "${dest}"
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
  fi
  # Rebase onto anything pushed from another machine before pushing, so a
  # non-fast-forward can never leave the sync half-applied.
  if ! git pull --rebase --no-edit --quiet; then
    git rebase --abort 2>/dev/null || true
    die "Could not rebase onto origin; resolve the divergence in ${REPO_DIR} and re-run push."
  fi
  git push && ok "Pushed to GitHub."
}

# ============================================================
# PULL
# ============================================================

cmd_pull() {
  require git
  require rsync

  [[ -d "${REPO_DIR}/.git" ]] || die "Repo not found at ${REPO_DIR}. Run setup first."

  log "Pulling latest from GitHub..."
  cd "${REPO_DIR}"
  if $DRY_RUN; then
    log "Would run: git pull"
  else
    git pull
    ok "Repo up to date."
  fi

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
    local restore_excludes
    restore_excludes="$(rsync_exclude_args scripts)"
    if $DRY_RUN; then
      log "Would rsync: scripts/ -> ~/.local/bin/ (pruning removed scripts)${restore_excludes}"
    else
      # Plain --delete (not --delete-excluded): excluded paths such as the VR
      # CyberDeck portable app are protected from deletion on the live side.
      rsync -a --delete ${restore_excludes} "${REPO_DIR}/scripts/" "${HOME}/.local/bin/"
      find "${HOME}/.local/bin" -maxdepth 1 -type f -exec chmod +x {} +
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
      # Merge into the live dir in place: cp -a SRC/. DEST/ avoids the
      # "dest/name/" nesting that `cp -r SRC DEST` produces on re-runs.
      mkdir -p "${src}"
      cp -a "${dest%/}/." "${src}/"
    else
      cp -a "${dest}" "${src}"
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
# CHECK (resolve the install transaction without touching anything)
# ============================================================

# Runs `pacman -S --print` against a throwaway root whose local database is
# empty, so the transaction is resolved exactly as it would be on a fresh
# system. The host's sync databases are only read (symlinked), never written:
# no -y is ever passed, nothing is installed, and everything lives under a
# mktemp directory that is removed on exit.

CHECK_TMP=""

check_cleanup() {
  local d="${CHECK_TMP}"
  [[ -n "${d}" && -d "${d}" ]] || return 0
  # Only ever remove a directory this script created.
  if [[ "${d}" == */dotfiles-check.* ]]; then
    rm -rf -- "${d}" 2>/dev/null || true
  else
    warn "Refusing to remove unexpected path: ${d}"
  fi
}

cmd_check() {
  require pacman
  [[ -d "${REPO_DIR}/.git" ]] || die "Repo not found at ${REPO_DIR}. Run setup first."

  local arch_list="${REPO_DIR}/packages/pkglist-arch.txt"
  local cachy_list="${REPO_DIR}/packages/pkglist-cachyos.txt"
  local aur_list="${REPO_DIR}/packages/pkglist-aur.txt"

  [[ -s "${arch_list}" ]] || die "Missing or empty: ${arch_list}"

  local official=() p
  while read -r p; do
    [[ -n "${p}" ]] && official+=("${p}")
  done < <(cat "${arch_list}" "${cachy_list}" 2>/dev/null)
  [[ ${#official[@]} -gt 0 ]] || die "No official packages listed."

  CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-check.XXXXXX")" ||
    die "Could not create a temporary directory"
  trap check_cleanup EXIT

  local problems=0
  local hostdb_before
  hostdb_before="$(stat -c '%Y:%s' /var/lib/pacman/local 2>/dev/null || echo none)"

  # ----------------------------------------------------------
  # 1. Every listed name must exist in a configured repository
  # ----------------------------------------------------------
  log "Checking ${#official[@]} official package names..."
  pacman -Si "${official[@]}" >/dev/null 2>"${CHECK_TMP}/si.err" || true
  sed -n "s/.*package '\([^']*\)'.*/\1/p" "${CHECK_TMP}/si.err" | sort -u >"${CHECK_TMP}/missing.txt"
  if [[ -s "${CHECK_TMP}/missing.txt" ]]; then
    while read -r p; do
      warn "Not in any configured repo: ${p}"
      problems=$((problems + 1))
    done <"${CHECK_TMP}/missing.txt"
  else
    ok "All official package names resolve."
  fi

  # ----------------------------------------------------------
  # 2. AUR entries that a repo already provides (repo wins)
  # ----------------------------------------------------------
  if [[ -s "${aur_list}" ]]; then
    pacman -Slq 2>/dev/null | sort -u >"${CHECK_TMP}/repo-names.txt" || true
    local shadowed=0
    while read -r p; do
      [[ -n "${p}" ]] || continue
      if grep -qxF "${p}" "${CHECK_TMP}/repo-names.txt"; then
        warn "AUR entry '${p}' is also in a configured repo; the repo build wins and paru will skip it."
        shadowed=$((shadowed + 1))
      fi
    done <"${aur_list}"
    [[ ${shadowed} -eq 0 ]] && ok "No AUR entry shadows a repo package."
  fi

  # ----------------------------------------------------------
  # 3. Resolve the whole transaction against an empty local DB
  # ----------------------------------------------------------
  if [[ ! -r /var/lib/pacman/sync ]]; then
    warn "Cannot read /var/lib/pacman/sync; run 'sudo pacman -Sy' and retry for a full check."
    problems=$((problems + 1))
  else
    local root="${CHECK_TMP}/root"
    mkdir -p "${root}/var/lib/pacman/local"
    ln -s /var/lib/pacman/sync "${root}/var/lib/pacman/sync"

    log "Resolving a clean-system transaction (no downloads, no installs)..."
    if pacman -r "${root}" --dbpath "${root}/var/lib/pacman" \
      -S --print --print-format '%n' --needed "${official[@]}" \
      >"${CHECK_TMP}/resolved.txt" 2>"${CHECK_TMP}/resolve.err"; then
      local total
      total="$(wc -l <"${CHECK_TMP}/resolved.txt")"
      ok "Transaction resolves: ${#official[@]} requested, ${total} packages on a clean system."
    else
      warn "The transaction does not resolve:"
      sed 's/^/         /' "${CHECK_TMP}/resolve.err" | grep -v '^error: target not found' || true
      grep -q 'target not found' "${CHECK_TMP}/resolve.err" &&
        warn "  (unresolved names are listed above and in the name check)"
      problems=$((problems + 1))
    fi

    # --------------------------------------------------------
    # 4. Conflicts inside the resolved set (including deps)
    # --------------------------------------------------------
    if [[ -s "${CHECK_TMP}/resolved.txt" ]]; then
      log "Scanning the resolved set for package conflicts..."
      # shellcheck disable=SC2046 # names were validated above, one per line
      pacman -Si $(cat "${CHECK_TMP}/resolved.txt") 2>/dev/null >"${CHECK_TMP}/meta.raw" || true

      awk '
        {
          i = index($0, ":")
          if (i == 0) next
          label = substr($0, 1, i - 1); gsub(/[[:space:]]+$/, "", label)
          val   = substr($0, i + 1);    gsub(/^[[:space:]]+/, "", val)
          if (label == "Name") name = val
          else if (label == "Version") print "V\t" name "\t" val
          else if (label == "Provides" && val != "None") {
            n = split(val, a, " ")
            for (k = 1; k <= n; k++) print "P\t" name "\t" a[k]
          } else if (label == "Replaces" && val != "None") {
            n = split(val, a, " ")
            for (k = 1; k <= n; k++) print "R\t" name "\t" a[k]
          } else if (label == "Conflicts With" && val != "None") {
            n = split(val, a, " ")
            for (k = 1; k <= n; k++) print "C\t" name "\t" a[k]
          }
        }
      ' "${CHECK_TMP}/meta.raw" >"${CHECK_TMP}/meta.tsv"

      # in_set: every package in the transaction
      # prov_of/provver: what each package provides (e.g. zlib, X-ABI-...)
      # repl_of: which package replaces which (pacman swaps these silently)
      declare -A in_set=() pkgver=() prov_of=() provver=() repl_of=() seen=()
      local kind pkg tok name op cver other otherver key cmp
      while IFS=$'\t' read -r p; do
        [[ -n "${p}" ]] && in_set["${p}"]=1
      done <"${CHECK_TMP}/resolved.txt"

      while IFS=$'\t' read -r kind pkg tok; do
        case "${kind}" in
          V) pkgver["${pkg}"]="${tok}" ;;
          P)
            name="${tok%%[<>=]*}"
            if [[ -z "${prov_of[${name}]:-}" ]]; then
              prov_of["${name}"]="${pkg}"
              [[ "${tok}" == *=* ]] && provver["${name}"]="${tok#*=}"
            fi
            ;;
          R) repl_of["${tok%%[<>=]*}"]="${pkg}" ;;
        esac
      done <"${CHECK_TMP}/meta.tsv"

      # A conflict only counts when its version constraint is actually met by
      # the package in the transaction, and when it is not a Replaces swap.
      local conflicts=0
      while IFS=$'\t' read -r kind pkg tok; do
        [[ "${kind}" == "C" ]] || continue

        name="${tok}"; op=""; cver=""
        if [[ "${tok}" == *"<"* || "${tok}" == *">"* || "${tok}" == *"="* ]]; then
          name="${tok%%[<>=]*}"
          op="${tok#"${name}"}"; op="${op%%[0-9]*}"
          cver="${tok#"${name}${op}"}"
        fi

        other=""; otherver=""
        if [[ -n "${in_set[${name}]:-}" ]]; then
          other="${name}"; otherver="${pkgver[${name}]:-}"
        elif [[ -n "${prov_of[${name}]:-}" ]]; then
          other="${prov_of[${name}]}"
          otherver="${provver[${name}]:-${pkgver[${other}]:-}}"
        fi
        [[ -n "${other}" ]] || continue
        [[ "${other}" == "${pkg}" ]] && continue

        if [[ -n "${op}" && -n "${otherver}" && -n "${cver}" ]]; then
          cmp="$(vercmp "${otherver}" "${cver}" 2>/dev/null || echo 0)"
          local hit=false
          case "${op}" in
            "<")  if (( cmp < 0 ));  then hit=true; fi ;;
            "<=") if (( cmp <= 0 )); then hit=true; fi ;;
            ">")  if (( cmp > 0 ));  then hit=true; fi ;;
            ">=") if (( cmp >= 0 )); then hit=true; fi ;;
            "=")  if (( cmp == 0 )); then hit=true; fi ;;
          esac
          $hit || continue
        fi

        if [[ "${repl_of[${pkg}]:-}" == "${other}" || "${repl_of[${other}]:-}" == "${pkg}" ]]; then
          continue
        fi

        key="$(printf '%s\n%s\n' "${pkg}" "${other}" | sort | paste -sd'|')"
        [[ -n "${seen[${key}]:-}" ]] && continue
        seen["${key}"]=1
        warn "Conflict: ${pkg} <-> ${other}"
        conflicts=$((conflicts + 1))
      done <"${CHECK_TMP}/meta.tsv"

      if [[ ${conflicts} -eq 0 ]]; then
        ok "No conflicting packages in the resolved set."
      else
        problems=$((problems + conflicts))
      fi
    fi
  fi

  # ----------------------------------------------------------
  # 5. AUR: existence + declared conflicts (metadata only)
  # ----------------------------------------------------------
  if [[ -s "${aur_list}" && "${CHECK_NO_AUR}" == false ]]; then
    if ! command -v curl &>/dev/null; then
      warn "--no-aur implied: curl not found, AUR metadata not checked."
    elif ! command -v python3 &>/dev/null; then
      warn "python3 not found; skipping AUR metadata check."
    else
      log "Querying AUR metadata for $(wc -l <"${aur_list}") packages..."
      local args
      args="$(sed 's/^/arg[]=/' "${aur_list}" | paste -sd'&')"
      if curl -fsS -m 25 "https://aur.archlinux.org/rpc/v5/info?${args}" \
        -o "${CHECK_TMP}/aur.json" 2>/dev/null; then
        python3 - "${CHECK_TMP}/aur.json" "${CHECK_TMP}/resolved.txt" "${aur_list}" \
          >"${CHECK_TMP}/aur.issues" 2>/dev/null <<'PY'
import json, sys
data, resolved_file, list_file = sys.argv[1:4]
res = {line.strip() for line in open(resolved_file) if line.strip()}
want = [line.strip() for line in open(list_file) if line.strip()]
rpc = json.load(open(data))["results"]
have = {r["Name"] for r in rpc}
for name in want:
    if name not in have:
        print(f"MISSING\t{name}\t")
for r in rpc:
    for tok in r.get("Conflicts") or []:
        base = tok.split("<")[0].split(">")[0].split("=")[0]
        if base in res and base != r["Name"]:
            print(f"CONFLICT\t{r['Name']}\t{base}")
PY
        local aur_problems=0 ak ap at
        if [[ -s "${CHECK_TMP}/aur.issues" ]]; then
          while IFS=$'\t' read -r ak ap at; do
            case "${ak}" in
              MISSING)  warn "AUR package no longer exists: ${ap}" ;;
              CONFLICT) warn "AUR conflict: ${ap} <-> ${at}" ;;
            esac
            aur_problems=$((aur_problems + 1))
          done <"${CHECK_TMP}/aur.issues"
        fi
        if [[ ${aur_problems} -eq 0 ]]; then
          ok "AUR metadata clean: all entries exist, no declared conflicts."
        else
          problems=$((problems + aur_problems))
        fi
      else
        warn "Could not reach the AUR RPC; skipping AUR metadata check."
      fi
    fi
  fi

  # ----------------------------------------------------------
  # 6. Prove the host was not modified
  # ----------------------------------------------------------
  local hostdb_after
  hostdb_after="$(stat -c '%Y:%s' /var/lib/pacman/local 2>/dev/null || echo none)"
  if [[ "${hostdb_before}" != "${hostdb_after}" ]]; then
    warn "Host pacman database changed during the check -- investigate immediately."
    problems=$((problems + 1))
  else
    ok "Host pacman database untouched."
  fi

  local hw=0
  for p in "${HARDWARE_EXCLUDES[@]}"; do
    grep -qxF "${p}" "${CHECK_TMP}/resolved.txt" 2>/dev/null && hw=$((hw + 1))
  done
  [[ ${hw} -gt 0 ]] && log "Note: ${hw} hardware-specific package(s) in the transaction will be skipped on pull."

  echo
  if [[ ${problems} -gt 0 ]]; then
    warn "${problems} problem(s) found -- a clean install would fail or conflict. Nothing was installed."
    exit 2
  fi
  ok "Check passed: no missing packages, unresolvable dependencies, or conflicts."
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
CHECK_NO_AUR=false
subcommand=""
commit_msg=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=true ;;
    --skip-cachyos)  SKIP_CACHYOS=true ;;
    --no-aur)        CHECK_NO_AUR=true ;;
    *)
      if [[ -z "$subcommand" ]]; then
        subcommand="$arg"
      elif [[ -z "$commit_msg" ]]; then
        commit_msg="$arg"
      fi
      ;;
  esac
done

case "${subcommand}" in
  push) cmd_push "${commit_msg}" ;;
  pull) cmd_pull ;;
  check) cmd_check ;;
  setup) cmd_setup ;;
  *)
    echo "Usage: $(basename "$0") [--dry-run] [--skip-cachyos] [--no-aur] <push|pull|check|setup> [commit message]"
    echo ""
    echo "  setup           Clone the repo and prepare the directory structure"
    echo "  push [msg]      Sync everything to GitHub (optional commit message)"
    echo "  pull            Pull from GitHub, install packages, restore configs"
    echo "  check           Resolve the package install as if on a clean system;"
    echo "                  reports missing packages, unresolvable deps and conflicts."
    echo "                  Installs nothing and changes nothing outside a temp dir."
    echo ""
    echo "  --dry-run       Show what would happen, don't change anything"
    echo "  --skip-cachyos  Don't add CachyOS repos; skip its packages on pull"
    echo "  --no-aur        (check) Skip the AUR metadata lookup"
    exit 1
    ;;
esac
