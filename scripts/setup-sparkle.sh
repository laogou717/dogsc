#!/usr/bin/env bash
# Download the official Sparkle 2.9.4 xcframework into Sparkle-local/.
#
# The repository does not commit Sparkle.xcframework (too large). Run this once
# before the first build:
#
#   ./scripts/setup-sparkle.sh
#
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$project_root/Sparkle-local"
framework="$dest/Sparkle.xcframework"
version="2.9.4"
url="https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-for-Swift-Package-Manager.zip"
# SHA-256 published by the Sparkle project for this archive.
expected="cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"

if [[ -d "$framework" ]]; then
  echo "Sparkle.xcframework already present at $framework — nothing to do."
  exit 0
fi

mkdir -p "$dest"
tmp="$(mktemp -d "${TMPDIR:-/tmp/}sparkle.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $url"
if ! curl --http1.1 -fL --retry 3 -o "$tmp/sparkle.zip" "$url"; then
  echo "error: download failed. Check your network/proxy and retry." >&2
  exit 1
fi

actual="$(shasum -a 256 "$tmp/sparkle.zip" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "error: checksum mismatch" >&2
  echo "  expected $expected" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

unzip -q "$tmp/sparkle.zip" -d "$tmp/extract"
mv "$tmp/extract/Sparkle.xcframework" "$framework"
# The archive also carries sources/tests we do not need for a binary target.
echo "Sparkle.xcframework installed at $framework"
