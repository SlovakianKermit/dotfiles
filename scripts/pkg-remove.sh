#!/usr/bin/env bash

fzf_args=(
  --multi
  --preview 'pacman -Qii {1} 2>/dev/null || yay -Qii {1}'
  --preview-label='alt-p: toggle preview | alt-j/k: scroll preview | tab: multi-select'
  --preview-label-pos='bottom'
  --preview-window 'down:65%:wrap'
  --bind 'alt-p:toggle-preview'
  --bind 'alt-d:preview-half-page-down,alt-u:preview-half-page-up'
  --bind 'alt-k:preview-up,alt-j:preview-down'
  --color 'pointer:red,marker:red'
  --bind 'ctrl-j:down,ctrl-k:up'
)

pkg_names=$(pacman -Qq 2>/dev/null | fzf "${fzf_args[@]}")

if [ -n "$pkg_names" ]; then
  echo "$pkg_names" | tr '\n' ' ' | xargs paru -Rns --noconfirm
fi
