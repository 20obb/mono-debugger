#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="/mnt/c/Users/devil/Documents/tewak"
BUILD_DIR="$HOME/tewak-build"
OUT_DIR="$SRC_DIR"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -f "$OUT_DIR"/com.devil.miniprocmon_*.deb

rsync -a --delete \
  --exclude .theos \
  --exclude packages \
  --exclude packages-wsl \
  "$SRC_DIR/" "$BUILD_DIR/"

cd "$BUILD_DIR"
make clean package FINALPACKAGE=1

cp -f packages/*.deb "$OUT_DIR/"
ls -la "$OUT_DIR"
