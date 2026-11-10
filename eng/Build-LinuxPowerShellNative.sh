#!/bin/sh
set -eu

case "$1" in
  glibc)
    dnf install -y --setopt=install_weak_deps=False gcc gcc-c++ make cmake
    ;;
  musl)
    apk add --no-cache build-base cmake
    ;;
  *)
    echo "Expected glibc or musl, got: $1" >&2
    exit 1
    ;;
esac

cmake -S /native/src/libpsl-native -B /tmp/powershell-native-build -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build /tmp/powershell-native-build --target psl-native --parallel 2
install -m 755 /native/src/powershell-unix/libpsl-native.so "/native/pwsh-native-$1-arm64.so"
