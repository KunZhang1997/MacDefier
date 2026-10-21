#!/usr/bin/env bash
# Trial / unsigned package → dist/trial/ with -unsigned suffix (never overwrites release).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
DIST_TRIAL="$ROOT/dist/trial"
VER="${1:-0.1.0}"
PRODUCT="$APP_DIR/build/DerivedData/Build/Products/Release/MacDefier.app"
TRIAL_TAG="unsigned"
ZIP_OUT="$DIST_TRIAL/MacDefier-${VER}-${TRIAL_TAG}.zip"
DMG_OUT="$DIST_TRIAL/MacDefier-${VER}-${TRIAL_TAG}.dmg"
ZIP_SUM="$DIST_TRIAL/MacDefier-${VER}-${TRIAL_TAG}.sha256"
DMG_SUM="$DIST_TRIAL/MacDefier-${VER}-${TRIAL_TAG}.dmg.sha256"
SHARE_DIR="$DIST_TRIAL/MacDefier-${VER}-${TRIAL_TAG}-share"
NOTICE_SRC="$APP_DIR/NOTICE"

# Refuse release-reserved basenames at dist root
for reserved in \
  "$ROOT/dist/MacDefier-${VER}.zip" \
  "$ROOT/dist/release/MacDefier-${VER}.zip" \
  "$ROOT/dist/MacDefier-${VER}.dmg" \
  "$ROOT/dist/release/MacDefier-${VER}.dmg"
do
  if [[ "$ZIP_OUT" == "$reserved" || "$DMG_OUT" == "$reserved" ]]; then
    echo "ERROR: trial package must not use release filename" >&2
    exit 1
  fi
done
case "$ZIP_OUT$DMG_OUT" in
  *"-${TRIAL_TAG}."*) ;;
  *) echo "ERROR: trial outputs must contain -${TRIAL_TAG}" >&2; exit 1 ;;
esac

test -f "$NOTICE_SRC" || { echo "ERROR: missing NOTICE: $NOTICE_SRC" >&2; exit 1; }

echo "==> xcodegen"
cd "$APP_DIR"
xcodegen generate

echo "==> build Release (ad-hoc / unsigned trial)"
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Release \
  -derivedDataPath build/DerivedData \
  build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

test -d "$PRODUCT" || { echo "missing $PRODUCT"; exit 1; }

echo "==> package dist/trial (unsigned — not for public ship)"
# Do not leave loose MacDefier.app at dist root
rm -rf "$ROOT/dist/MacDefier.app" "$SHARE_DIR"
mkdir -p "$DIST_TRIAL" "$SHARE_DIR"

STAGE_APP="$SHARE_DIR/MacDefier.app"
ditto "$PRODUCT" "$STAGE_APP"
xattr -cr "$STAGE_APP" 2>/dev/null || true
codesign --force --deep --sign - "$STAGE_APP"

# NOTICE required in App Resources and zip root
ditto "$NOTICE_SRC" "$STAGE_APP/Contents/Resources/NOTICE"
test -f "$STAGE_APP/Contents/Resources/NOTICE" || { echo "ERROR: NOTICE not in app Resources" >&2; exit 1; }

# Refuse debug / preview dylibs in stage
if find "$STAGE_APP" \( -name '*.debug.dylib' -o -name '__preview.dylib' \) | grep -q .; then
  echo "ERROR: debug/preview dylib found in trial stage" >&2
  find "$STAGE_APP" \( -name '*.debug.dylib' -o -name '__preview.dylib' \) >&2
  exit 1
fi

cat > "$SHARE_DIR/使用说明.txt" << EOF
MacDefier ${VER} — 试用包（未公证 / unsigned）

系统要求
- macOS 14.0 或更高

怎么打开
1. 解压 zip
2. 把 MacDefier.app 拖到「应用程序」
3. 首次若提示无法验证：右键 → 打开
4. 正式外发请使用 dist/release/ 下无 -unsigned 的公证包

功能概览
- 诊断 / 清理（默认进废纸篓）/ 软件卸载 / 监控 / AI 协助（可关）
EOF
cp "$SHARE_DIR/使用说明.txt" "$SHARE_DIR/README.txt"
cp "$NOTICE_SRC" "$SHARE_DIR/NOTICE"

rm -f "$ZIP_OUT"
(
  cd "$SHARE_DIR"
  zip -ry "$ZIP_OUT" MacDefier.app 使用说明.txt README.txt NOTICE
)
test -f "$ZIP_OUT" || exit 1

DMG_STAGE="$DIST_TRIAL/dmg-stage"
rm -rf "$DMG_STAGE" "$DMG_OUT"
mkdir -p "$DMG_STAGE"
ditto "$STAGE_APP" "$DMG_STAGE/MacDefier.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp "$SHARE_DIR/使用说明.txt" "$DMG_STAGE/使用说明.txt"
cp "$SHARE_DIR/README.txt" "$DMG_STAGE/README.txt"
cp "$NOTICE_SRC" "$DMG_STAGE/NOTICE"
hdiutil create \
  -volname "MacDefier ${VER} unsigned" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 \
  "$DMG_OUT"
codesign --force --sign - "$DMG_OUT"
codesign --verify --verbose=2 "$DMG_OUT"
rm -rf "$DMG_STAGE"

shasum -a 256 "$ZIP_OUT" | tee "$ZIP_SUM"
shasum -a 256 "$DMG_OUT" | tee "$DMG_SUM"
ls -lh "$ZIP_OUT" "$DMG_OUT"
echo "OK trial → $DIST_TRIAL (unsigned only; formal names reserved for package-release)"
