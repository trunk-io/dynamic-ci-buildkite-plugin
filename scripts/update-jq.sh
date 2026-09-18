#!/usr/bin/env bash
# Refresh the vendored jq binaries in `vendor/`.
#
#     scripts/update-jq.sh 1.8.1
#
# Downloads the three platforms `lib/jq.sh` knows how to resolve, verifies each
# against the checksum file upstream publishes on the same release, and rewrites
# `vendor/SHA256SUMS` from those upstream sums rather than from the bytes that
# just landed — a file that hashes whatever it downloaded would agree with itself
# no matter what it downloaded.
#
# `__tests__/vendored-jq.vitest.ts` asserts the version, so it changes with this.
set -euo pipefail

readonly PLATFORMS=(jq-linux-amd64 jq-linux-arm64 jq-macos-arm64)

version="${1-}"
if [[ -z ${version} ]]; then
    echo "usage: ${0##*/} <jq-version>   (e.g. ${0##*/} 1.8.1)" >&2
    exit 1
fi

readonly base="https://github.com/jqlang/jq/releases/download/jq-${version}"
vendor_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../vendor" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "fetching upstream checksums for jq-${version}"
curl -fsSL --retry 3 "${base}/sha256sum.txt" -o "${work}/upstream-sums"

for name in "${PLATFORMS[@]}"; do
    expected="$(awk -v n="${name}" '$2 == n { print $1 }' "${work}/upstream-sums")"
    if [[ -z ${expected} ]]; then
        echo "upstream publishes no checksum for ${name} at jq-${version}" >&2
        exit 1
    fi

    echo "fetching ${name}"
    curl -fsSL --retry 3 "${base}/${name}" -o "${work}/${name}"

    actual="$(sha256sum "${work}/${name}" | awk '{ print $1 }')"
    if [[ ${actual} != "${expected}" ]]; then
        echo "checksum mismatch for ${name}: expected ${expected}, got ${actual}" >&2
        exit 1
    fi
done

# Only now is anything in vendor/ touched, so a failed run leaves the working
# copy exactly as it found it.
for name in "${PLATFORMS[@]}"; do
    install -m 755 "${work}/${name}" "${vendor_dir}/${name}"
done

: >"${vendor_dir}/SHA256SUMS"
for name in "${PLATFORMS[@]}"; do
    awk -v n="${name}" '$2 == n { print $1 "  " $2 }' "${work}/upstream-sums" \
        >>"${vendor_dir}/SHA256SUMS"
done

echo
echo "vendor/ now holds jq-${version}. Remaining by hand:"
echo "  - update the version assertion in __tests__/vendored-jq.vitest.ts"
echo "  - pnpm test"
