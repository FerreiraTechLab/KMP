#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
go_binary=${GO_BINARY:-go}
output_dir=${1:-"$repo_dir/build/torrentd"}
case "$output_dir" in
  /*) ;;
  *) output_dir="$repo_dir/$output_dir" ;;
esac
mkdir -p "$output_dir"

build() {
  target_os=$1
  target_arch=$2
  output_name=$3
  printf 'Building %s/%s -> %s\n' "$target_os" "$target_arch" "$output_name"
  (cd "$repo_dir/torrentd" && \
    CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" \
    "$go_binary" build -trimpath -ldflags='-s -w' \
      -o "$output_dir/$output_name" ./cmd/kmp-torrentd)
}

build linux arm64 kmp-torrentd-linux-arm64
build linux amd64 kmp-torrentd-linux-amd64
build windows amd64 kmp-torrentd-windows-amd64.exe
build darwin arm64 kmp-torrentd-darwin-arm64
build darwin amd64 kmp-torrentd-darwin-amd64

sha256sum "$output_dir"/*
