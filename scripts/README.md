# Scripts

All scripts live in `~/.local/bin/`. They are automatically restored there when running `dotfiles-sync pull`.

---

## Image & Media

### `compress.sh`
Converts images to WebP format using `cwebp`.
- Takes an optional path relative to `~/Pictures/img` and an optional quality value (default 85)
- Supports absolute paths directly
- Example: `compress.sh holiday/photos 90`

### `enhance-awebp`
AI upscales animated WebP files using `waifu2x-ncnn-vulkan`.
- Dumps individual frames using `anim_dump`, upscales each frame, then reassembles into an animated WebP
- Requires `waifu2x-ncnn-vulkan` to be installed

### `flatten.sh`
Moves files from nested subdirectories up to a flat structure in the current directory.
- Useful for cleaning up deep folder hierarchies from bulk downloads

### `rename.sh`
Batch renames image files in a directory.

### `resize.sh`
Batch resizes images in a directory.

### `fix_images.sh`
Fixes or filters problematic image files in a directory.

### `trim_corrupt.sh`
Trims or removes corrupt image files.

### `extract_archives.sh`
Extracts various archive formats (zip, tar, rar, etc.) in a directory.

### `extract_zips.sh`
Extracts zip files specifically.

---

## Claude / AI

### `claude-export-to-md.py`
Exports Claude conversation history from the local data store to readable markdown files.

### `claude-search`
Searches through exported Claude conversations by keyword.
- Depends on `claude-export-to-md.py` having been run first

---

## Package Management

### `pkg-install`
Interactive package install TUI wrapping `fzf` and `paru`.
- Lets you search and select official repo packages to install

### `pkg-install-aur`
Same as `pkg-install` but scoped to AUR packages.

### `pkg-remove.sh`
Interactive package removal TUI wrapping `fzf` and `paru`.
- Lets you search and select installed packages to remove

---

## Dotfiles

### `dotfiles-sync`
Pushes and pulls dotfiles, configs, scripts, and package lists to/from GitHub.
- `dotfiles-sync push "message"` - syncs everything to GitHub
- `dotfiles-sync pull` - restores everything on a fresh system
- `dotfiles-sync setup` - clones the repo and sets up the folder structure
- See the root `README.md` for full documentation

---

## Downloading

### `gallery-dl.py`
Wrapper around `gallery-dl` for downloading image galleries from Pixiv and similar sites.

---

## Changelog

| Date | Script | Change |
|------|--------|--------|
| 2025 | `compress.sh` | Changed default quality from 90 to 85, switched hardcoded path to `$HOME`, added absolute path support |
| 2025 | `dotfiles-sync` | Initial version |
| Jun 2025 | `compress.sh` | Replaced `identify`+`convert` resize pipeline with `ffprobe`+`cwebp` native resize, eliminating temp files and a redundant decode/encode cycle |
