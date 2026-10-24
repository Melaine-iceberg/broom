#!/usr/bin/env bash
#
# Builds a binary Debian package containing:
#   - the Flutter release bundle
#   - broom-system-helper
#   - the generated Polkit policy
#   - desktop entry, icons and documentation
#
# The script only builds and packages. It never installs the .deb, never runs
# pkexec and never performs a system cleanup.
#
# Usage:
#   bash tool/package_deb.sh
#   bash tool/package_deb.sh --skip-flutter-build
#   BROOM_GPG_KEY="<gpg-key-id>" bash tool/package_deb.sh
#
# Requirements: x86_64 Linux, CMake/C++ toolchain and dpkg-deb. Signing
# additionally needs gnupg and an unlocked key.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() {
  cat <<'EOF'
Usage: bash tool/package_deb.sh [--skip-flutter-build]

Builds dist/broom_<version>-1_amd64.deb and its SHA-256 file.

  --skip-flutter-build  Reuse build/linux/x64/release/bundle instead of
                        running `flutter build linux --release`.

The script always rebuilds the system helper and the Polkit policy. It never
installs the package, runs pkexec or performs a system cleanup.

Set BROOM_GPG_KEY to a GPG key id/email to write an armored detached
signature next to the package and its SHA-256 file. Signing needs an unlocked
key.
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
      echo "Try 'bash tool/package_deb.sh --help'." >&2
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

[[ "$(uname -s)" == "Linux" ]] || die "Debian packaging must run on Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "This package targets amd64 only."

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | cut -d+ -f1)"
[[ -n "$version" ]] || die "Unable to read the version from pubspec.yaml."
[[ "$version" =~ ^[0-9] ]] || die "Debian versions must start with a digit: ${version}"

# WSL mounts Windows drives as 9p/v9fs, which silently ignores chmod. dpkg then
# records unusable file modes, so refuse to build from such a path.
filesystem_type="$(stat -f -c %T "$root" 2>/dev/null || true)"
case "$filesystem_type" in
  9p|v9fs)
    die "The repository is on a ${filesystem_type} mount (for example /mnt/k in WSL).
Copy it to a Linux-native path such as \$HOME before packaging, or every file
in the package will have unusable permissions."
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

need cmake
need dpkg-deb
need install
need sha256sum

bundle="build/linux/x64/release/bundle"
if [[ "$build_flutter" -eq 1 ]]; then
  need flutter
  flutter build linux --release
fi
[[ -x "${bundle}/broom" ]] ||
  die "Missing ${bundle}/broom. Build the Flutter Linux bundle first."

helper_build="build/system-helper-deb"
cmake -S linux/system_helper -B "$helper_build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBEXECDIR=libexec \
  -DBROOM_HELPER_BUILD_TESTS=OFF
cmake --build "$helper_build" --parallel

helper_bin="${helper_build}/broom-system-helper"
policy="${helper_build}/com.broom.Broom.policy"
helper_install_path="/usr/libexec/broom/broom-system-helper"
[[ -x "$helper_bin" ]] || die "Missing built helper: $helper_bin"
[[ -f "$policy" ]] || die "Missing generated Polkit policy: $policy"
grep -Fq "$helper_install_path" "$policy" ||
  die "The generated policy does not point at ${helper_install_path}."

name="broom_${version}-1_amd64"
stage="build/deb/${name}"
deb="dist/${name}.deb"

rm -rf "$stage" "$deb" "${deb}.sha256" "${deb}.asc" "${deb}.sha256.asc"
mkdir -p "$stage/DEBIAN" \
  "$stage/usr/bin" \
  "$stage/usr/lib/broom" \
  "$stage/usr/libexec/broom" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/doc/broom" \
  "$stage/usr/share/icons/hicolor/256x256/apps" \
  "$stage/usr/share/icons/hicolor/512x512/apps" \
  "$stage/usr/share/icons/hicolor/256x256@2/apps" \
  "$stage/usr/share/icons/hicolor/512x512@2/apps" \
  "$stage/usr/share/polkit-1/actions"

cp -a "${bundle}/." "$stage/usr/lib/broom/"
install -m 0755 "$helper_bin" "$stage/usr/libexec/broom/broom-system-helper"
install -m 0644 "$policy" "$stage/usr/share/polkit-1/actions/com.broom.Broom.policy"
install -m 0644 linux/packaging/com.broom.Broom.desktop \
  "$stage/usr/share/applications/com.broom.Broom.desktop"
install -m 0644 linux/packaging/broom-256.png \
  "$stage/usr/share/icons/hicolor/256x256/apps/broom.png"
install -m 0644 linux/packaging/broom-512.png \
  "$stage/usr/share/icons/hicolor/512x512/apps/broom.png"
install -m 0644 linux/packaging/broom-512.png \
  "$stage/usr/share/icons/hicolor/256x256@2/apps/broom.png"
install -m 0644 linux/packaging/broom.png \
  "$stage/usr/share/icons/hicolor/512x512@2/apps/broom.png"
ln -s ../lib/broom/broom "$stage/usr/bin/broom"

install -m 0644 README.md "$stage/usr/share/doc/broom/README.md"
install -m 0644 docs/linux-system-cache.md \
  "$stage/usr/share/doc/broom/linux-system-cache.md"
install -m 0644 packaging/deb/copyright "$stage/usr/share/doc/broom/copyright"

installed_size="$(du -sk "$stage" | cut -f1)"
sed -e "s/@VERSION@/${version}/g" \
  -e "s/@INSTALLED_SIZE@/${installed_size}/g" \
  packaging/deb/control.in > "$stage/DEBIAN/control"
install -m 0755 packaging/deb/postinst "$stage/DEBIAN/postinst"
install -m 0755 packaging/deb/prerm "$stage/DEBIAN/prerm"

mkdir -p dist
dpkg-deb --root-owner-group --build "$stage" "$deb"
(cd dist && sha256sum "$(basename "$deb")" > "$(basename "$deb").sha256")

if [[ -n "${BROOM_GPG_KEY:-}" ]]; then
  need gpg
  gpg --batch --yes --armor --detach-sign \
    --local-user "$BROOM_GPG_KEY" "$deb"
  gpg --batch --yes --armor --detach-sign \
    --local-user "$BROOM_GPG_KEY" "${deb}.sha256"
fi

echo "Created ${deb}"
echo "Created ${deb}.sha256"
if [[ -n "${BROOM_GPG_KEY:-}" ]]; then
  echo "Created ${deb}.asc and ${deb}.sha256.asc"
fi
