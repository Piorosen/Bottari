#!/bin/bash
# Makes Sparkle's EdDSA key pair once (or prints the public key if it exists).
# The private key goes into your login keychain; put the printed public key in
# Config/release.env as SPARKLE_PUBLIC_KEY. Back it up with:
#   generate_keys -x sparkle-private-key.txt
set -euo pipefail
cd "$(dirname "$0")/.."
tool=$(find .build -path '*artifacts/sparkle/Sparkle/bin/generate_keys' -type f 2>/dev/null | head -1)
if [[ -z "$tool" ]]; then
  echo "Sparkle 도구가 없어요. 먼저 make build 로 패키지를 받아 주세요." >&2
  exit 1
fi
"$tool" "$@"
