#!/bin/bash
# Build helper: download a release artifact and verify it before it enters the image.
#   fetch-verified.sh <url> <output> <sha256|skip> [<public-key-file> <primary-key-fingerprint>]
# - SHA-256 pins the exact file ("skip" disables the pin and prints a warning).
# - With a key file, <url>.sig must be a valid signature made by that key.
set -euo pipefail

url=$1 out=$2 sha=${3:-skip} keyfile=${4:-} fpr=${5:-}

echo "Downloading $url"
wget -q "$url" -O "$out"

if [ "$sha" = skip ] || [ -z "$sha" ]; then
  echo "WARNING: no SHA-256 pinned for $(basename "$out")" >&2
else
  echo "$sha  $out" | sha256sum -c - || {
    echo "ERROR: SHA-256 mismatch for $url" >&2
    echo "       Set the matching checksum (shown on the release page) or 'skip'." >&2
    exit 1
  }
fi

if [ -n "$keyfile" ]; then
  wget -q "$url.sig" -O "$out.sig"
  GNUPGHOME=$(mktemp -d); export GNUPGHOME
  gpg --batch --quiet --import "$keyfile"
  status=$(gpg --batch --status-fd 1 --verify "$out.sig" "$out" 2> /dev/null) || {
    echo "ERROR: GPG signature check failed for $url" >&2
    echo "$status" >&2
    exit 1
  }
  # Last field of VALIDSIG is the primary key fingerprint.
  echo "$status" | grep -qE "^\[GNUPG:\] VALIDSIG .* ${fpr}\$" || {
    echo "ERROR: $url is not signed by the expected key $fpr" >&2
    exit 1
  }
  echo "GPG signature OK ($fpr)"
  rm -rf "$GNUPGHOME" "$out.sig"
fi
