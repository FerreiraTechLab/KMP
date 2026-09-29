#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
architecture=${1:-aarch64}
version=1.37.0

case "$architecture" in
  aarch64)
    archive=aria2-aarch64-linux-musl_static.zip
    expected=0c681a89a40e0f82d1f5137608e86257eb0af201459c002941ea098f2b8c26b6
    binary_expected=99a057bd383a28f1d5fab6e8cc5f6f3ed4172f5e65c59548242e965454d654c1
    ;;
  *)
    printf 'Arquitetura ainda não empacotada: %s\n' "$architecture" >&2
    exit 2
    ;;
esac

destination="$repo_dir/KMP/libs.$architecture"
if [ -x "$destination/aria2c" ] &&
   [ "$(sha256sum "$destination/aria2c" | awk '{print $1}')" = "$binary_expected" ]; then
  printf 'Dependência já verificada em %s\n' "$destination/aria2c"
  exit 0
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/kmp-runtime.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
url="https://github.com/abcfy2/aria2-static-build/releases/download/$version/$archive"

curl -L --fail --silent --show-error "$url" -o "$temporary/$archive"
actual=$(sha256sum "$temporary/$archive" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
  printf 'SHA-256 inesperado para %s\nEsperado: %s\nRecebido: %s\n' \
    "$archive" "$expected" "$actual" >&2
  exit 1
fi

mkdir -p "$destination"
unzip -p "$temporary/$archive" aria2c > "$destination/aria2c.tmp"
chmod 755 "$destination/aria2c.tmp"
mv "$destination/aria2c.tmp" "$destination/aria2c"
actual_binary=$(sha256sum "$destination/aria2c" | awk '{print $1}')
if [ "$actual_binary" != "$binary_expected" ]; then
  printf 'SHA-256 inesperado para aria2c extraído\n' >&2
  rm -f "$destination/aria2c"
  exit 1
fi
if [ "$(uname -m)" = "$architecture" ]; then
  "$destination/aria2c" --version | sed -n '1p'
else
  file "$destination/aria2c"
fi
printf 'Dependência instalada em %s\n' "$destination/aria2c"
