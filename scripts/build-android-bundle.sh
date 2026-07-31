#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <meta-rule-directory> <output-directory>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
source_dir="$(cd "$1" && pwd)"
mkdir -p "$2"
output_dir="$(cd "$2" && pwd)"
manifest="${repo_dir}/resouces/android-bundle-mrs.txt"
archive="${output_dir}/BundleMRS-android.7z"
archive_manifest="${output_dir}/BundleMRS-android.manifest"
checksum="${output_dir}/BundleMRS-android.7z.sha256sum"
seven_zip="${SEVEN_ZIP:-7z}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nautilus-android-rules.XXXXXX")"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ ! -f "$manifest" ]]; then
  echo "manifest not found: $manifest" >&2
  exit 1
fi
if ! command -v "$seven_zip" >/dev/null 2>&1 && [[ ! -x "$seven_zip" ]]; then
  echo "7z executable not found: $seven_zip" >&2
  exit 1
fi
if [[ -n "$(LC_ALL=C sort "$manifest" | uniq -d)" ]]; then
  echo "manifest contains duplicate paths" >&2
  exit 1
fi

staging_dir="${work_dir}/staging"
verify_dir="${work_dir}/verify"
mkdir -p "$staging_dir" "$verify_dir"

while IFS= read -r path || [[ -n "$path" ]]; do
  [[ -z "$path" ]] && continue
  if [[ "$path" = /* || "$path" = *".."* || "$path" != *.mrs ]]; then
    echo "invalid manifest path: $path" >&2
    exit 1
  fi
  if [[ ! -f "${source_dir}/${path}" ]]; then
    echo "required rule is missing: $path" >&2
    exit 1
  fi

  mkdir -p "${staging_dir}/$(dirname "$path")"
  cp "${source_dir}/${path}" "${staging_dir}/${path}"
done < "$manifest"

rm -f "$archive" "$archive_manifest" "$checksum"
(
  cd "$staging_dir"
  "$seven_zip" a "$archive" -mx=9 -r . >/dev/null
)

"$seven_zip" x "$archive" "-o${verify_dir}" -y >/dev/null
(
  cd "$verify_dir"
  find . -type f | sed 's#^\./##' | LC_ALL=C sort
) > "${work_dir}/actual.manifest"
LC_ALL=C sort "$manifest" > "${work_dir}/expected.manifest"
if ! cmp -s "${work_dir}/expected.manifest" "${work_dir}/actual.manifest"; then
  echo "archive contents do not match the Android manifest" >&2
  diff -u "${work_dir}/expected.manifest" "${work_dir}/actual.manifest" >&2 || true
  exit 1
fi

cp "$manifest" "$archive_manifest"
archive_size="$(wc -c < "$archive" | tr -d ' ')"
if (( archive_size > 1000000 )); then
  echo "Android rule bundle exceeds 1,000,000 bytes: ${archive_size}" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  (
    cd "$output_dir"
    sha256sum "$(basename "$archive")" > "$(basename "$checksum")"
  )
else
  archive_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
  printf '%s  %s\n' "$archive_hash" "$(basename "$archive")" > "$checksum"
fi

echo "Built $(basename "$archive"): ${archive_size} bytes"
