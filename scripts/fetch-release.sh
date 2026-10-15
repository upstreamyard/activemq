#!/usr/bin/env bash
# Downloads the official Apache ActiveMQ (Classic) binary release, checks its SHA-512 and
# its GPG signature against the ActiveMQ KEYS file, and unpacks it into ./upstream.
# Usage: scripts/fetch-release.sh <version>   (e.g. 6.3.2)
set -euo pipefail

VERSION=${1:?usage: $0 <version>}
FILE="apache-activemq-${VERSION}-bin.tar.gz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# Supported releases live on downloads.apache.org, older ones only on archive.apache.org.
for base in https://downloads.apache.org/activemq https://archive.apache.org/dist/activemq; do
  if curl -fsSLO "$base/$VERSION/$FILE"; then
    curl -fsSLO "$base/$VERSION/$FILE.sha512"
    curl -fsSLO "$base/$VERSION/$FILE.asc"
    break
  fi
done
[ -f "$FILE" ] || { echo "Release $VERSION not found"; exit 1; }
curl -fsSL -o KEYS https://downloads.apache.org/activemq/KEYS

echo "$(awk '{print $1}' "$FILE.sha512")  $FILE" | sha512sum -c -
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import KEYS 2>/dev/null
gpg --batch --verify "$FILE.asc" "$FILE"

rm -rf "$ROOT/upstream"
mkdir -p "$ROOT/upstream"
tar xzf "$FILE" -C "$ROOT/upstream" --strip-components=1
echo "ActiveMQ $VERSION unpacked into upstream/"
