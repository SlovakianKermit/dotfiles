#!/bin/bash

DIR="/home/kilian/Pictures/img/[Sondu] Femboys Collection (Various) [AI Generated] [230p 2025-09-07]"
cd "$DIR" || exit

for file in *.webp; do
  # Match first number and last text segment before .webp
  if [[ $file =~ ^0*([0-9]{1,3}).*[_]([A-Za-z]+)[^/]*\.webp$ ]]; then
    number=$((10#${BASH_REMATCH[1]})) # remove leading zeros
    text="${BASH_REMATCH[2]}"         # last text part
    newname="${number}_${text}.webp"
    if [[ "$file" != "$newname" ]]; then
      echo "Renaming '$file' -> '$newname'"
      mv "$file" "$newname"
    fi
  fi
done
