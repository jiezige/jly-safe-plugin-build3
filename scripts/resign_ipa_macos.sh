#!/usr/bin/env bash
set -euo pipefail

INPUT_IPA="${1:?input IPA path required}"
OUTPUT_IPA="${2:?output IPA path required}"
WORKDIR="$(mktemp -d)"
KEYCHAIN_PATH="$WORKDIR/build.keychain-db"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

replace_bytes() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2].encode()
new = sys.argv[3].encode()
if len(new) > len(old):
    raise SystemExit(f"replacement is longer: {new!r} > {old!r}")
data = bytearray(path.read_bytes())
count = data.count(old)
if count == 0:
    raise SystemExit(f"pattern not found in {path}: {old!r}")
data = data.replace(old, new + b"\0" * (len(old) - len(new)))
path.write_bytes(data)
print(f"Replaced {count} occurrence(s) in {path}: {old.decode()} -> {new.decode()}")
PY
}

unzip -q "$INPUT_IPA" -d "$WORKDIR/ipa"
APP_DIR="$(find "$WORKDIR/ipa/Payload" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [[ -z "$APP_DIR" ]]; then
  echo "Payload app directory not found" >&2
  exit 1
fi

APP_BIN="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_DIR/Info.plist")"
ROOT_MIAOTAO="$APP_DIR/libmiaotao 2.dylib"
FW_MIAOTAO="$APP_DIR/Frameworks/libmiaotao.dylib"
test -f "$ROOT_MIAOTAO"
mkdir -p "$APP_DIR/Frameworks"
mv "$ROOT_MIAOTAO" "$FW_MIAOTAO"

replace_bytes "$APP_DIR/$APP_BIN" "@executable_path/libmiaotao 2.dylib" "@rpath/libmiaotao.dylib"
replace_bytes "$FW_MIAOTAO" "/usr/local/lib/libmiaotao.dylib" "@rpath/libmiaotao.dylib"

cat > "$WORKDIR/inert_addon.c" <<'C'
__attribute__((used)) static const char *jly_resign_marker[] = {
  "https://pee.jlyapp.cn",
  "/api/posts/app-list",
  "https://pee.jlyapp.cn/vip1/meet-list",
  "sm/meet/getmeetlist",
  "sm/matchmaker/recommend",
  "https://pee.jlyapp.cn/api/posts/all-app-list",
  "Circle/detailV1"
};
void jly_resign_marker_function(void) {}
C

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -isysroot "$SDK" \
  -target arm64-apple-ios12.0 \
  -dynamiclib \
  -miphoneos-version-min=12.0 \
  "$WORKDIR/inert_addon.c" \
  -o "$APP_DIR/JLYSearchAddon.dylib"
cp "$APP_DIR/JLYSearchAddon.dylib" "$APP_DIR/cike.dylib"

python3 - "$APP_DIR/$APP_BIN" <<'PY'
import importlib.util
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("patch_ipa", "scripts/patch_ipa.py")
patch_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_ipa)
data = bytearray(target.read_bytes())
if b"@executable_path/JLYSearchAddon.dylib" not in data:
    injector = patch_ipa.MachOLoadCommandInjector(data)
    target.write_bytes(injector.inject("@executable_path/JLYSearchAddon.dylib"))
PY

if [[ -n "${MOBILEPROVISION_BASE64:-}" ]]; then
  echo "$MOBILEPROVISION_BASE64" | base64 --decode > "$APP_DIR/embedded.mobileprovision"
fi

ENTITLEMENTS="$WORKDIR/entitlements.plist"
if [[ -f "$APP_DIR/embedded.mobileprovision" ]]; then
  security cms -D -i "$APP_DIR/embedded.mobileprovision" > "$WORKDIR/profile.plist" || true
  /usr/libexec/PlistBuddy -x -c 'Print Entitlements' "$WORKDIR/profile.plist" > "$ENTITLEMENTS" || true
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "Signing identity: ${IDENTITY}"
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
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
otool -l "$APP_DIR/$APP_BIN" | grep -E '@rpath/libmiaotao.dylib|@executable_path/JLYSearchAddon.dylib'
grep -q 'Frameworks/libmiaotao.dylib' "$APP_DIR/_CodeSignature/CodeResources"

mkdir -p "$(dirname "$OUTPUT_IPA")"
(
  cd "$WORKDIR/ipa"
  ditto -c -k --sequesterRsrc --keepParent Payload "$OLDPWD/$OUTPUT_IPA"
)

echo "Built $OUTPUT_IPA"
