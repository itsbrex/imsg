#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="imsg"
HELPER_NAME="imsg-bridge-helper.dylib"
ENTITLEMENTS="${ROOT}/Resources/imsg.entitlements"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/bin}"
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
HELPER_ARCHES_VALUE=${HELPER_ARCHES:-"arm64e x86_64"}
HELPER_ARCH_LIST=( ${HELPER_ARCHES_VALUE} )
BUILD_MODE=${BUILD_MODE:-release}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"-"}

for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c "$BUILD_MODE" --product "$APP_NAME" --arch "$ARCH"
done

FIRST_ARCH="${ARCH_LIST[0]}"
BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
  BINARIES+=("${ROOT}/.build/${ARCH}-apple-macosx/${BUILD_MODE}/${APP_NAME}")
done

DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-universal.XXXXXX")"
trap 'rm -rf "$DIST_DIR"' EXIT

lipo -create "${BINARIES[@]}" -output "${DIST_DIR}/${APP_NAME}"
HELPER_CLANG_ARCH_ARGS=()
for ARCH in "${HELPER_ARCH_LIST[@]}"; do
  HELPER_CLANG_ARCH_ARGS+=("-arch" "$ARCH")
done
clang -dynamiclib "${HELPER_CLANG_ARCH_ARGS[@]}" -fobjc-arc \
  -Wno-arc-performSelector-leaks \
  -framework Foundation \
  -o "${DIST_DIR}/${HELPER_NAME}" \
  "${ROOT}/Sources/IMsgHelper/IMsgInjected.m"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.steipete.imsg \
    "${DIST_DIR}/${APP_NAME}"
  codesign --force --sign - \
    --identifier com.steipete.imsg.bridge-helper \
    "${DIST_DIR}/${HELPER_NAME}"
else
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.steipete.imsg \
    "${DIST_DIR}/${APP_NAME}"
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
    --identifier com.steipete.imsg.bridge-helper \
    "${DIST_DIR}/${HELPER_NAME}"
fi

for bundle in "${ROOT}/.build/${FIRST_ARCH}-apple-macosx/${BUILD_MODE}"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

mkdir -p "$OUTPUT_DIR"
if command -v trash >/dev/null 2>&1; then
  for existing in "$OUTPUT_DIR/$APP_NAME" "$OUTPUT_DIR/$HELPER_NAME" "$OUTPUT_DIR"/*.bundle; do
    [[ -e "$existing" ]] || continue
    trash "$existing"
  done
fi

cp "${DIST_DIR}/${APP_NAME}" "$OUTPUT_DIR/$APP_NAME"
cp "${DIST_DIR}/${HELPER_NAME}" "$OUTPUT_DIR/$HELPER_NAME"
for bundle in "${DIST_DIR}"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$OUTPUT_DIR/"
  fi
done

echo "Built ${OUTPUT_DIR}/${APP_NAME} (${ARCHES_VALUE})"
echo "Built ${OUTPUT_DIR}/${HELPER_NAME} (${HELPER_ARCHES_VALUE})"
