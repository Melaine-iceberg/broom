#!/usr/bin/env bash
#
# Packages the Linux release bundle into dist/broom-<version>-linux-<arch>.tar.gz.
# Run `flutter build linux --release` first, or let CI run it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | cut -d+ -f1)"
if [[ -z "$version" ]]; then
  echo "Unable to read the version from pubspec.yaml" >&2
  exit 1
fi

arch="x64"
bundle="build/linux/${arch}/release/bundle"
if [[ ! -x "${bundle}/broom" ]]; then
  echo "Missing ${bundle}/broom. Run 'flutter build linux --release' first." >&2
  exit 1
fi

name="broom-${version}-linux-${arch}"
stage="dist/${name}"
archive="dist/${name}.tar.gz"

rm -rf "$stage" "$archive" "${archive}.sha256"
mkdir -p "$stage"
cp -R "${bundle}/." "$stage/"
install -m 0644 linux/packaging/broom.desktop "${stage}/broom.desktop"
install -m 0644 linux/packaging/broom.png "${stage}/broom.png"
if [[ -f LICENSE ]]; then
  install -m 0644 LICENSE "${stage}/LICENSE"
fi

tar -C dist -czf "$archive" "$name"
if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum "${name}.tar.gz" > "${name}.tar.gz.sha256")
fi
echo "Created ${archive}"
