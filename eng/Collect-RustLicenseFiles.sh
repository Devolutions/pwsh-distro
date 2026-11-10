#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <cargo-registry-src> <destination> <rust-library-notice>" >&2
  exit 1
fi

registry_root="$1"
destination_root="$2"
rust_library_notice="$3"
if [ ! -d "$registry_root" ] || [ -e "$destination_root" ] || [ ! -f "$rust_library_notice" ]; then
  echo "Cargo registry and Rust library notice must exist and license destination must not exist: $registry_root -> $destination_root ($rust_library_notice)" >&2
  exit 1
fi

mkdir -p "$destination_root"
mkdir -p "$destination_root/rust-standard-library"
cp "$rust_library_notice" "$destination_root/rust-standard-library/COPYRIGHT-library.html"
count=0
for registry in "$registry_root"/*; do
  [ -d "$registry" ] || continue
  for crate in "$registry"/*; do
    [ -d "$crate" ] || continue
    if [ ! -f "$crate/Cargo.toml" ]; then
      echo "Missing Cargo.toml for $crate" >&2
      exit 1
    fi
    destination="$destination_root/${crate##*/}"
    if [ -e "$destination" ]; then
      echo "Duplicate crate license destination: $destination" >&2
      exit 1
    fi
    mkdir -p "$destination"
    cp "$crate/Cargo.toml" "$destination/"
    find "$crate" -type f \( \
      -iname 'license*' -o -iname 'licence*' -o -iname 'copying*' -o -iname 'copyright*' -o \
      -iname 'notice*' -o -iname 'unlicense*' -o -iname 'authors*' -o -iname 'patents*' -o \
      -path "$crate/[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*/*" -o -path "$crate/*/[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*/*" -o \
      -path "$crate/[Ll][Ii][Cc][Ee][Nn][Cc][Ee]*/*" -o -path "$crate/*/[Ll][Ii][Cc][Ee][Nn][Cc][Ee]*/*" \
    \) -exec sh -eu -c '
      crate=$1
      destination=$2
      shift 2
      for file do
        relative=${file#"$crate"/}
        mkdir -p "$destination/$(dirname "$relative")"
        cp "$file" "$destination/$relative"
      done
    ' sh "$crate" "$destination" {} +
    count=$((count + 1))
  done
done

if [ "$count" -eq 0 ]; then
  echo "No crate licenses found under $registry_root" >&2
  exit 1
fi
echo "Collected license metadata for $count Rust crates."
