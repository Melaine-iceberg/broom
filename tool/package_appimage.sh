#!/usr/bin/env bash
#
# Builds a portable AppImage containing the Flutter release bundle.
#
# The AppImage never contains broom-system-helper or the Polkit policy: an
# AppImage cannot install files into /usr, so the in-app system cache entry
# stays hidden. Regular user-level scanning, quarantine and cleanup work as
# usual.
#
# Usage:
#   bash tool/package_appimage.sh
#   bash tool/package_appimage.sh --skip-flutter-build
#   BROOM_GPG_KEY="<gpg-key-id>" bash tool/package_appimage.sh
#
# Requirements: x86_64 Linux, curl and an unlocked GPG key when signing.
# appimagetool is downloaded once into build/tools and verified by SHA-256;
# set APPIMAGETOOL to use a local copy instead.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

appimagetool_version="1.9.1"
appimagetool_sha256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
appimagetool_url="https://github.com/AppImage/appimagetool/releases/download/${appimagetool_version}/appimagetool-x86_64.AppImage"

usage() {
  cat <<'EOF'
Usage: bash tool/package_appimage.sh [--skip-flutter-build]

Builds dist/broom-<version>-linux-x64.AppImage and its SHA-256 file.

  --skip-flutter-build  Reuse build/linux/x64/release/bundle instead of
                        running `flutter build linux --release`.

Set BROOM_GPG_KEY to a GPG key id/email to embed an AppImage signature and
write armored detached signatures for the AppImage and its SHA-256 file.
Signing needs gpg2 and an unlocked key.
EOF
}

build_flutter=1
for argument in "$@"; do
  case "$argument" in
    --skip-flutter-build)
      build_flutter=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $argument" >&2
      echo "Try 'bash tool/package_appimage.sh --help'." >&2
      exit 64
      ;;
  esac
done

die() {
  echo "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

[[ "$(uname -s)" == "Linux" ]] || die "AppImage packaging must run on Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "This package targets x86_64 only."

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | cut -d+ -f1)"
[[ -n "$version" ]] || die "Unable to read the version from pubspec.yaml."

# WSL mounts Windows drives as 9p/v9fs, which silently ignores chmod. An
# AppImage loses its executable bits and the desktop integration on such a
# path, so refuse to build there.
filesystem_type="$(stat -f -c %T "$root" 2>/dev/null || true)"
case "$filesystem_type" in
  9p|v9fs)
    die "The repository is on a ${filesystem_type} mount (for example /mnt/k in WSL).
Copy it to a Linux-native path such as \$HOME before packaging."
    ;;
esac

probe="$(mktemp "$root/.broom-perm-probe.XXXXXX")" ||
  die "Unable to create a permission probe in ${root}."
chmod 600 "$probe"
probe_mode="$(stat -c %a "$probe")"
rm -f "$probe"
[[ "$probe_mode" == "600" ]] ||
  die "The repository filesystem ignores POSIX permissions (expected 600, got ${probe_mode}).
Copy the repository to a Linux-native path before packaging."

need file
need install
need sha256sum

bundle="build/linux/x64/release/bundle"
if [[ "$build_flutter" -eq 1 ]]; then
  need flutter
  flutter build linux --release
fi
[[ -x "${bundle}/broom" ]] ||
  die "Missing ${bundle}/broom. Build the Flutter Linux bundle first."

appdir="build/appimage/broom.AppDir"
name="broom-${version}-linux-x64"
output="dist/${name}.AppImage"
rm -rf "$appdir" "$output" "${output}.sha256" "${output}.asc" "${output}.sha256.asc"
mkdir -p "$appdir/usr/bin" \
  "$appdir/usr/lib/broom" \
  "$appdir/usr/share/applications" \
  "$appdir/usr/share/icons/hicolor/256x256/apps" \
  "$appdir/usr/share/icons/hicolor/512x512/apps"

cp -a "${bundle}/." "$appdir/usr/lib/broom/"
ln -s ../lib/broom/broom "$appdir/usr/bin/broom"

install -m 0755 packaging/appimage/AppRun "$appdir/AppRun"
install -m 0644 linux/packaging/com.broom.Broom.desktop \
  "$appdir/broom.desktop"
install -m 0644 linux/packaging/broom-512.png "$appdir/broom.png"
ln -s broom.png "$appdir/.DirIcon"
install -m 0644 linux/packaging/com.broom.Broom.desktop \
  "$appdir/usr/share/applications/com.broom.Broom.desktop"
install -m 0644 linux/packaging/broom-256.png \
  "$appdir/usr/share/icons/hicolor/256x256/apps/broom.png"
install -m 0644 linux/packaging/broom-512.png \
  "$appdir/usr/share/icons/hicolor/512x512/apps/broom.png"
if [[ -f LICENSE ]]; then
  install -m 0644 LICENSE "$appdir/LICENSE"
fi

tool="${APPIMAGETOOL:-}"
if [[ -z "$tool" ]]; then
  tool="build/tools/appimagetool-x86_64.AppImage"
  if [[ ! -x "$tool" ]]; then
    need curl
    mkdir -p build/tools
    download="${tool}.download"
    rm -f "$download"
    curl -fL --retry 3 --connect-timeout 20 -o "$download" "$appimagetool_url" ||
      die "Unable to download appimagetool from ${appimagetool_url}."
    echo "${appimagetool_sha256}  ${download}" | sha256sum -c --quiet - ||
      die "appimagetool download failed its SHA-256 check."
    chmod 0755 "$download"
    mv "$download" "$tool"
  fi
fi
[[ -x "$tool" ]] || die "appimagetool is not executable: $tool"

sign_args=()
if [[ -n "${BROOM_GPG_KEY:-}" ]]; then
  need gpg
  # appimagetool invokes gpg2 by name.
  if ! command -v gpg2 >/dev/null 2>&1; then
    mkdir -p build/tools/gpg-bin
    ln -sf "$(command -v gpg)" build/tools/gpg-bin/gpg2
    PATH="$PWD/build/tools/gpg-bin:$PATH"
    export PATH
  fi
  sign_args=(--sign --sign-key "$BROOM_GPG_KEY")
fi

mkdir -p dist
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 \
  "$tool" --no-appstream "${sign_args[@]}" "$appdir" "$output"
chmod 0755 "$output"
(cd dist && sha256sum "$(basename "$output")" > "$(basename "$output").sha256")

if [[ -n "${BROOM_GPG_KEY:-}" ]]; then
  gpg --batch --yes --armor --detach-sign \
    --local-user "$BROOM_GPG_KEY" "$output"
  gpg --batch --yes --armor --detach-sign \
    --local-user "$BROOM_GPG_KEY" "${output}.sha256"
fi

echo "Created ${output}"
echo "Created ${output}.sha256"
if [[ -n "${BROOM_GPG_KEY:-}" ]]; then
  echo "Created ${output}.asc and ${output}.sha256.asc"
fi
