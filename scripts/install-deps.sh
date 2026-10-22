#!/usr/bin/env bash
# Kervan'ın dış araçlarını Homebrew ile kurar; --upgrade verilirse günceller.
# Kullanım: scripts/install-deps.sh [--upgrade]
set -euo pipefail

if ! command -v brew >/dev/null; then
  echo "Homebrew yok: https://brew.sh" >&2
  exit 1
fi

for formula in yt-dlp ffmpeg aria2 deno; do
  if brew list --formula "$formula" >/dev/null 2>&1; then
    if [[ "${1:-}" == "--upgrade" ]]; then
      brew upgrade "$formula" || true
    else
      echo "✓ $formula"
    fi
  else
    brew install "$formula"
  fi
done

echo "Kontrol: swift run kervan doctor"
