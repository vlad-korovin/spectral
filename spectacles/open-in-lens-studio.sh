#!/bin/zsh
set -eu
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
if [[ -d '/Applications/Lens Studio.app' ]]; then
  open -a '/Applications/Lens Studio.app' "$project_dir/OpticsLab/OpticsLab.esproj"
elif [[ -d "$HOME/Applications/Lens Studio.app" ]]; then
  open -a "$HOME/Applications/Lens Studio.app" "$project_dir/OpticsLab/OpticsLab.esproj"
else
  print 'Install the Spectacles-compatible Lens Studio from https://ar.snap.com/spectacles, then run this script again.'
  exit 1
fi
