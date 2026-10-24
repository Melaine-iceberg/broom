#!/usr/bin/env bash
#
# Builds a binary RPM containing:
#   - the Flutter release bundle
#   - broom-system-helper
#   - the generated Polkit policy
#   - desktop entry, icon and documentation
#
# The script only builds and packages. It never installs the RPM, never runs
# pkexec and never performs a system cleanup.
#
# Usage:
#   bash tool/package_rpm.sh
#   bash tool/package_rpm.sh --skip-flutter-build
#
# Requirements: Linux x86_64, Flutter, CMake/C++ toolchain and rpm-build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() {
  cat <<'EOF'
Usage: bash tool/package_rpm.sh [--skip-flutter-build]

Builds dist/broom-<version>-1.<dist>.x86_64.rpm and its SHA-256 file.

  --skip-flutter-build  Reuse build/linux/x64/release/bundle instead of
                        running `flutter build linux --release`.

The script always rebuilds the system helper and the Polkit policy. It never
installs the RPM, runs pkexec or performs a system cleanup.
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
      echo "Try 'bash tool/package_rpm.sh --help'." >&2
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

[[ "$(uname -s)" == "Linux" ]] || die "RPM packaging must run on Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "This package targets x86_64 only."

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | cut -d+ -f1)"
[[ -n "$version" ]] || die "Unable to read the version from pubspec.yaml."

need cmake
need rpm
need rpmbuild
need tar
need sha256sum
need install

bundle="build/linux/x64/release/bundle"
if [[ "$build_flutter" -eq 1 ]]; then
  need flutter
  flutter build linux --release
fi
[[ -x "${bundle}/broom" ]] ||
  die "Missing ${bundle}/broom. Build the Flutter Linux bundle first."

helper_build="build/system-helper-rpm"
cmake -S linux/system_helper -B "$helper_build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DBROOM_HELPER_BUILD_TESTS=OFF
cmake --build "$helper_build" --parallel

helper_bin="${helper_build}/broom-system-helper"
policy="${helper_build}/com.broom.Broom.policy"
helper_install_path="$(rpm --eval '%{_libexecdir}/broom/broom-system-helper')"
[[ -x "$helper_bin" ]] || die "Missing built helper: $helper_bin"
[[ -f "$policy" ]] || die "Missing generated Polkit policy: $policy"
grep -Fq "$helper_install_path" "$policy" ||
  die "The generated policy does not point at ${helper_install_path}.
Reconfigure the helper with CMAKE_INSTALL_PREFIX=/usr for this distro."

work="build/rpm"
source_name="broom-bundle-${version}"
source_root="${work}/sources/${source_name}"
topdir="${work}/topdir"
source_tar="${work}/sources/${source_name}.tar.gz"

rm -rf "$source_root" "$source_tar" "$topdir"
mkdir -p "$source_root/bundle" "$source_root/helper" "$source_root/packaging" \
  "$source_root/docs"
cp -a "${bundle}/." "$source_root/bundle/"
install -m 0755 "$helper_bin" "$source_root/helper/broom-system-helper"
install -m 0644 linux/packaging/broom.desktop \
  "$source_root/packaging/broom.desktop"
install -m 0644 linux/packaging/broom.png "$source_root/packaging/broom.png"
install -m 0644 "$policy" "$source_root/packaging/com.broom.Broom.policy"
install -m 0644 README.md "$source_root/README.md"
install -m 0644 docs/linux-system-cache.md \
  "$source_root/docs/linux-system-cache.md"
if [[ -f LICENSE ]]; then
  install -m 0644 LICENSE "$source_root/LICENSE"
fi

tar -C "${work}/sources" -czf "$source_tar" "$source_name"

mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cp "$source_tar" "$topdir/SOURCES/"
cp packaging/rpm/broom.spec "$topdir/SPECS/broom.spec"

rpmbuild -bb "$topdir/SPECS/broom.spec" \
  --define "_topdir ${root}/${topdir}" \
  --define "broom_version ${version}"

mapfile -t built_rpms < <(find "$topdir/RPMS" -type f -name 'broom-*.rpm')
[[ "${#built_rpms[@]}" -eq 1 ]] ||
  die "Expected exactly one RPM, found ${#built_rpms[@]}."

mkdir -p dist
final_rpm="dist/$(basename "${built_rpms[0]}")"
rm -f "$final_rpm" "${final_rpm}.sha256"
cp "${built_rpms[0]}" "$final_rpm"
(cd dist && sha256sum "$(basename "$final_rpm")" > "$(basename "$final_rpm").sha256")

echo "Created ${final_rpm}"
echo "Created ${final_rpm}.sha256"
