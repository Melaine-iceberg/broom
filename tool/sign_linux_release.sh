#!/usr/bin/env bash
#
# Writes SHA256SUMS and the Linux update manifest for the packages already in
# dist/, then optionally signs every artifact and both metadata files with a
# detached GPG signature.
#
# The manifest matches lib/core/app/linux_app_update_service.dart
# (schemaVersion 1). The application reads it, then can download an artifact,
# verify its SHA-256 and install it: AppImages are replaced in place, deb / RPM
# packages are handed to the system installer.
#
# This script never uploads files. Copy dist/ to the host named by --base-url
# after verifying the signatures.
#
# Usage:
#   bash tool/sign_linux_release.sh --base-url https://example.com/broom/
#   BROOM_GPG_KEY="<gpg-key-id>" bash tool/sign_linux_release.sh \
#     --base-url https://example.com/broom/
#   bash tool/sign_linux_release.sh --url https://example.com/broom/app.AppImage
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() {
  cat <<'EOF'
Usage: bash tool/sign_linux_release.sh [options]

Options:
  --base-url URL        HTTPS directory containing the artifacts; file names are
                        appended. Must end with a slash.
  --url URL             Use this exact HTTPS download URL for the preferred
                        artifact instead of --base-url.
  --artifact PATH       Preferred artifact for the manifest's "url" field.
                        Defaults to the AppImage, then the .deb, tar.gz and RPM.
  --published-at VALUE  Override the UTC publication timestamp.
  --output PATH         Manifest path (default: dist/broom-linux.json).
  --skip-sign           Do not sign, even when BROOM_GPG_KEY is set.

Set BROOM_GPG_KEY to a GPG key id/email to write armored detached signatures
for every artifact, SHA256SUMS and the manifest. The key must be unlocked.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

base_url=""
url=""
artifact=""
published_at=""
output="dist/broom-linux.json"
sign=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      [[ $# -ge 2 ]] || die "Missing value for --base-url."
      base_url="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || die "Missing value for --url."
      url="$2"
      shift 2
      ;;
    --artifact)
      [[ $# -ge 2 ]] || die "Missing value for --artifact."
      artifact="$2"
      shift 2
      ;;
    --published-at)
      [[ $# -ge 2 ]] || die "Missing value for --published-at."
      published_at="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "Missing value for --output."
      output="$2"
      shift 2
      ;;
    --skip-sign)
      sign=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1
Try 'bash tool/sign_linux_release.sh --help'."
      ;;
  esac
done

version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | cut -d+ -f1)"
[[ -n "$version" ]] || die "Unable to read the version from pubspec.yaml."

[[ -n "$base_url" || -n "$url" ]] ||
  die "Pass --base-url or --url so the manifest contains an HTTPS download address."
if [[ -n "$base_url" ]]; then
  [[ "$base_url" == https://* ]] || die "--base-url must use HTTPS."
  [[ "$base_url" == */ ]] || base_url="${base_url}/"
fi

[[ -d dist ]] || die "Missing dist/. Build the packages first."

mapfile -t artifacts < <(
  find dist -maxdepth 1 -type f \
    \( -name "broom-${version}-linux-x64.tar.gz" \
       -o -name "broom-${version}-linux-x64.AppImage" \
       -o -name "broom_${version}-1_amd64.deb" \
       -o -name "broom-${version}-1.*.rpm" \) |
    sort
)
[[ "${#artifacts[@]}" -gt 0 ]] ||
  die "No packages for version ${version} found in dist/. Build at least one first."

format_of() {
  case "$1" in
    *.AppImage) echo appimage ;;
    *.deb) echo deb ;;
    *.rpm) echo rpm ;;
    *.tar.gz) echo "tar.gz" ;;
    *) echo unknown ;;
  esac
}

if [[ -z "$artifact" && -n "$url" ]]; then
  candidate="dist/$(basename "${url%%\?*}")"
  [[ -f "$candidate" ]] ||
    die "--url points at $(basename "$candidate"), which is not present in dist/.
Pass --artifact explicitly or build that package first."
  artifact="$candidate"
fi
if [[ -z "$artifact" ]]; then
  for preferred in \
    "dist/broom-${version}-linux-x64.AppImage" \
    "dist/broom_${version}-1_amd64.deb" \
    "dist/broom-${version}-linux-x64.tar.gz"; do
    if [[ -f "$preferred" ]]; then
      artifact="$preferred"
      break
    fi
  done
  if [[ -z "$artifact" ]]; then
    artifact="${artifacts[0]}"
  fi
fi
[[ -f "$artifact" ]] || die "Preferred artifact not found: $artifact"

artifact_name="$(basename "$artifact")"
if [[ -z "$url" ]]; then
  url="${base_url}${artifact_name}"
fi
[[ "$url" == https://* ]] || die "The manifest download URL must use HTTPS."

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

published_at="${published_at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

mkdir -p "$(dirname "$output")"
checksums="dist/SHA256SUMS"
rm -f "$checksums"
(
  cd dist
  for path in "${artifacts[@]}"; do
    sha256sum "$(basename "$path")"
  done
) > "$checksums"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "version": "%s",\n' "$(json_escape "$version")"
  printf '  "publishedAt": "%s",\n' "$(json_escape "$published_at")"
  printf '  "url": "%s",\n' "$(json_escape "$url")"
  printf '  "sha256": "%s",\n' "$(sha256_of "$artifact")"
  printf '  "artifacts": [\n'
  first=1
  for path in "${artifacts[@]}"; do
    if [[ "$first" -eq 0 ]]; then
      printf ',\n'
    fi
    first=0
    file="$(basename "$path")"
    if [[ "$path" == "$artifact" && -n "$url" ]]; then
      file_url="$url"
    elif [[ -n "$base_url" ]]; then
      file_url="${base_url}${file}"
    else
      file_url=""
    fi
    printf '    {'
    printf '"format": "%s", ' "$(format_of "$path")"
    printf '"file": "%s", ' "$(json_escape "$file")"
    printf '"url": "%s", ' "$(json_escape "$file_url")"
    printf '"sha256": "%s"' "$(sha256_of "$path")"
    printf '}'
  done
  printf '\n  ]\n'
  printf '}\n'
} > "$output"

if [[ "$sign" -eq 1 ]]; then
  if [[ -z "${BROOM_GPG_KEY:-}" ]]; then
    echo "BROOM_GPG_KEY is not set; wrote unsigned metadata." >&2
  else
    command -v gpg >/dev/null 2>&1 || die "Missing required command: gpg"
    for path in "${artifacts[@]}" "$checksums" "$output"; do
      rm -f "${path}.asc"
      gpg --batch --yes --armor --detach-sign \
        --local-user "$BROOM_GPG_KEY" "$path"
    done
    echo "Signed ${#artifacts[@]} artifact(s), SHA256SUMS and $(basename "$output")."
  fi
fi

echo "Created ${checksums}"
echo "Created ${output}"
echo "Preferred artifact: ${artifact}"
