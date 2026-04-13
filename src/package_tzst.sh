#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${1:-${SCRIPT_DIR}/../build}"
OUT_DIR="${2:-${SCRIPT_DIR}/../dist}"
VERSION="${WRAPPER_VERSION:-2.0.0}"

mkdir -p "${OUT_DIR}"

SO="${BUILD_DIR}/libvulkan_wrapper.so"
SPV="${BUILD_DIR}/bcn_decompress.comp.spv"

if [ ! -f "${SO}" ]; then
    echo "ERROR: ${SO} not found — run cmake --build first"
    exit 1
fi

echo "Packaging wrapper.tzst..."
STAGE=$(mktemp -d)
trap "rm -rf ${STAGE}" EXIT

USR_LIB="${STAGE}/usr/lib"
mkdir -p "${USR_LIB}"

cp "${SO}" "${USR_LIB}/libvulkan_wrapper.so"

if [ -f "${SPV}" ]; then
    cp "${SPV}" "${USR_LIB}/bcn_decompress.comp.spv"
fi

(cd "${STAGE}" && \
 tar --use-compress-program="zstd -19 -T0" \
     -cf "${OUT_DIR}/wrapper.tzst" \
     usr/)

echo "wrapper.tzst created: $(du -h "${OUT_DIR}/wrapper.tzst" | cut -f1)"

echo "Packaging extra_libs.tzst..."
STAGE2=$(mktemp -d)
trap "rm -rf ${STAGE} ${STAGE2}" EXIT

USR_LIB2="${STAGE2}/usr/lib"
mkdir -p "${USR_LIB2}"

if [ -f "${SPV}" ]; then
    cp "${SPV}" "${USR_LIB2}/bcn_decompress.comp.spv"
fi

(cd "${STAGE2}" && \
 tar --use-compress-program="zstd -19 -T0" \
     -cf "${OUT_DIR}/extra_libs.tzst" \
     usr/) 2>/dev/null || true

echo "Done. Output:"
ls -lh "${OUT_DIR}/"*.tzst 2>/dev/null || true

SHA_FILE="${OUT_DIR}/SHA256SUMS.txt"
cd "${OUT_DIR}"
sha256sum *.tzst *.so 2>/dev/null > "${SHA_FILE}" || true
echo ""
cat "${SHA_FILE}"
