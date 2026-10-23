#!/usr/bin/env bash
set -euo pipefail

BINARY_PATH="${1:?Supply the Mach-O binary to verify}"

# Some Apple lipo versions reject multiple architectures in -verify_arch. Separate
# checks retain the requirement for both slices across supported toolchains.
for architecture in arm64 x86_64; do
  lipo "$BINARY_PATH" -verify_arch "$architecture"
done
