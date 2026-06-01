#!/usr/bin/env bash
set -euo pipefail

INPUT_IPA="${1:-miaotaoGOm0492_303_fixed.ipa}"
OUTPUT_IPA="${2:-dist/miaotaoGOm0492_303_cf.ipa}"
WORKDIR="$(mktemp -d)"
PATCHED_IPA="$WORKDIR/patched.ipa"
KEYCHAIN_PATH="$WORKDIR/build.keychain-db"
SEARCH_ADDON="$WORKDIR/JLYSearchAddon.dylib"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

chmod +x scripts/build_search_addon_macos.sh
scripts/build_search_addon_macos.sh "$SEARCH_ADDON"
python3 scripts/patch_ipa.py "$INPUT_IPA" "$PATCHED_IPA" --workdir "$WORKDIR/patch" --search-addon "$SEARCH_ADDON" --keep-ipa-app-list
unzip -q "$PATCHED_IPA" -d "$WORKDIR/ipa"
APP_DIR="$(find "$WORKDIR/ipa/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"

if [[ -n "${MOBILEPROVISION_BASE64:-}" ]]; then
  echo "$MOBILEPROVISION_BASE64" | base64 --decode > "$APP_DIR/embedded.mobileprovision"
fi

ENTITLEMENTS="$WORKDIR/entitlements.plist"
if [[ -f "$APP_DIR/embedded.mobileprovision" ]]; then
  security cms -D -i "$APP_DIR/embedded.mobileprovision" > "$WORKDIR/profile.plist" || true
  /usr/libexec/PlistBuddy -x -c 'Print Entitlements' "$WORKDIR/profile.plist" > "$ENTITLEMENTS" || true
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ -n "${SIGNING_CERT_P12_BASE64:-}" ]]; then
  security create-keychain -p "" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "" "$KEYCHAIN_PATH"
  echo "$SIGNING_CERT_P12_BASE64" | base64 --decode > "$WORKDIR/signing.p12"
  security import "$WORKDIR/signing.p12" -k "$KEYCHAIN_PATH" -P "${SIGNING_CERT_PASSWORD:-}" -T /usr/bin/codesign
  security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN_PATH"
fi

sign_target() {
  local target="$1"
  if [[ -s "$ENTITLEMENTS" && "$target" == "$APP_DIR" ]]; then
    codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$target"
  else
    codesign --force --sign "$IDENTITY" "$target"
  fi
}

if [[ -d "$APP_DIR/Frameworks" ]]; then
  find "$APP_DIR/Frameworks" -type f \( -perm -111 -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' file; do
    sign_target "$file" || true
  done
  find "$APP_DIR/Frameworks" -maxdepth 1 -name '*.framework' -type d -print0 | while IFS= read -r -d '' framework; do
    sign_target "$framework" || true
  done
fi
find "$APP_DIR" -maxdepth 1 -name '*.dylib' -type f -print0 | while IFS= read -r -d '' dylib; do
  sign_target "$dylib"
done
sign_target "$APP_DIR"

mkdir -p "$(dirname "$OUTPUT_IPA")"
(
  cd "$WORKDIR/ipa"
  ditto -c -k --sequesterRsrc --keepParent Payload "$OLDPWD/$OUTPUT_IPA"
)

echo "Built $OUTPUT_IPA"
