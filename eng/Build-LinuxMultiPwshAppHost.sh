#!/bin/sh
set -eu

case "$1" in
  glibc)
    dnf install -y --setopt=install_weak_deps=False gcc gcc-c++ make curl ca-certificates
    export RUSTUP_HOME=/tmp/rustup
    export CARGO_HOME=/tmp/cargo
    curl --fail --silent --show-error --location --retry 3 https://sh.rustup.rs -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN_VERSION" --no-modify-path
    PATH="$CARGO_HOME/bin:$PATH"
    export PATH
    ;;
  musl)
    apk add --no-cache build-base
    export RUSTFLAGS='-C target-feature=-crt-static'
    ;;
  *)
    echo "Expected glibc or musl, got: $1" >&2
    exit 1
    ;;
esac

export PWSH_HOST_SKIP_DOTNET_BUILD=1
export CARGO_TARGET_DIR=/tmp/multi-pwsh-target
cargo build --locked --release --package multi-pwsh --bin multi-pwsh
sh /eng/Collect-RustLicenseFiles.sh \
  "${CARGO_HOME:-$HOME/.cargo}/registry/src" /src/pwsh-linux-apphost-third-party \
  "$(rustc --print sysroot)/share/doc/rust/COPYRIGHT-library.html"
install -m 755 "$CARGO_TARGET_DIR/release/multi-pwsh" /src/pwsh-linux-apphost
