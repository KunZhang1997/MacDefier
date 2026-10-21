#!/usr/bin/env bash
# 正式发版：Developer ID 签名 → 公证 → staple → DMG/ZIP
# 用法：
#   ./scripts/package-release.sh                 # 默认 0.1.0
#   ./scripts/package-release.sh 0.1.1
# 前置：
#   xcrun notarytool store-credentials "macdefier-notary" ...
# 工程在 iCloud Desktop 时，在本地缓存目录构建，避免 xcodebuild 卡死。
set -euo pipefail

VER="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT_APP="$ROOT/app"
DIST="$ROOT/dist"
CACHE="${MACDEFIER_BUILD_CACHE:-$HOME/Library/Caches/MacDefier-build}"
NOTARY_PROFILE="${NOTARY_PROFILE:-macdefier-notary}"
SIGN_ID="${SIGN_ID:?Set SIGN_ID to your Developer ID Application identity}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"

assert_safe_scratch() {
  local requested="$1" label="$2" marker="$3"
  case "$requested" in
    "$HOME/Library/Caches/MacDefier-"*|"$HOME/Library/Caches/MacDefier/"*|/private/tmp/MacDefier-*|/tmp/MacDefier-*) ;;
    # bash 3.2 + set -u: always use ${var}; never write $var： (fullwidth colon binds into name)
    *) echo "拒绝不安全的 ${label} 路径: ${requested}" >&2; exit 2 ;;
  esac
  case "$requested" in
    *"/../"*|*"/.."|*"/./"*|*"//"*) echo "拒绝未规范化的 ${label} 路径: ${requested}" >&2; exit 2 ;;
  esac
  local parent="$(dirname "$requested")" leaf="$(basename "$requested")"
  [[ -d "$parent" ]] || mkdir -p "$parent"
  local path="$(cd "$parent" && pwd -P)/$leaf"
  [[ ! -L "$requested" ]] || { echo "拒绝符号链接 ${label}: ${requested}" >&2; exit 2; }
  [[ ! -e "$path" || -d "$path" ]] || { echo "${label} 不是目录: ${path}" >&2; exit 2; }
  for broad in / "$HOME" "$ROOT" "$VAULT_APP" "$DIST"; do
    [[ "$path" != "$broad" && "$broad" != "$path/"* ]] \
      || { echo "拒绝项目/宽泛 ${label} 路径: ${path}" >&2; exit 2; }
  done
  [[ "$path" != "$ROOT/"* && "$path" != "$VAULT_APP/"* && "$path" != "$DIST/"* ]] \
    || { echo "拒绝项目内 ${label} 路径: ${path}" >&2; exit 2; }
  local cacheRoot="$(cd "$HOME/Library/Caches" && pwd -P)"
  [[ "$path" == "$cacheRoot/MacDefier-"* || "$path" == "$cacheRoot/MacDefier/"* \
      || "$path" == /private/tmp/MacDefier-* || "$path" == /tmp/MacDefier-* ]] \
    || { echo "拒绝 canonical 逃逸的 ${label} 路径: ${path}" >&2; exit 2; }
  mkdir -p "$path"
  local markerPath="$path/.macdefier-$marker"
  if [[ -f "$markerPath" ]]; then
    [[ "$(<"$markerPath")" == "macdefier-scratch-v1" ]] \
      || { echo "${label} marker 无效: ${markerPath}" >&2; exit 2; }
  elif [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'macdefier-scratch-v1' > "$markerPath"
  else
    echo "拒绝复用没有 marker 的非空 ${label}: ${path}" >&2; exit 2
  fi
  printf '%s\n' "$path"
}

CACHE="$(assert_safe_scratch "$CACHE" "build cache" build-cache)"

PRODUCT_REL="DerivedData/Build/Products/Release/MacDefier.app"
APP_IN_CACHE="$CACHE/$PRODUCT_REL"
ENTITLEMENTS_REL="MacDefier/MacDefier.entitlements"

echo "==> [0/8] preflight"
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
security find-identity -v -p codesigning | grep -F "$SIGN_ID" >/dev/null \
  || { echo "missing signing identity: $SIGN_ID"; security find-identity -v -p codesigning; exit 1; }
test -f "$VAULT_APP/$ENTITLEMENTS_REL" || { echo "missing $ENTITLEMENTS_REL"; exit 1; }

echo "==> [1/8] rsync vault app → cache (avoid iCloud xcodebuild hang)"
rsync -a --delete \
  --exclude '.macdefier-*' \
  --exclude '.build' --exclude 'build' --exclude 'DerivedData' \
  --exclude '.git' --exclude '*.xcodeproj/project.xcworkspace/xcuserdata' \
  --exclude '*.xcodeproj/xcuserdata' \
  "$VAULT_APP/" "$CACHE/"

cd "$CACHE"
test -f project.yml
test -f "$ENTITLEMENTS_REL"

echo "==> [2/8] xcodegen"
xcodegen generate

echo "==> [3/8] xcodebuild Release (Developer ID + hardened runtime)"
rm -rf "$CACHE/DerivedData"
# 注意：不要在命令行传 CODE_SIGN_ENTITLEMENTS（会灌进 SPM 依赖导致找不到文件）。
# 主 App entitlements 在构建后 codesign 步骤统一挂上。
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Release \
  -derivedDataPath "$CACHE/DerivedData" \
  -destination 'generic/platform=macOS' \
  build \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VER" \
  CURRENT_PROJECT_VERSION="$VER"

test -d "$APP_IN_CACHE" || { echo "missing product: $APP_IN_CACHE"; exit 1; }

# 签名/公证全程在非 iCloud 本地目录做，避免 Desktop/iCloud 的 FinderInfo xattr 导致 codesign 失败
STAGE_ROOT="${MACDEFIER_RELEASE_STAGE:-$HOME/Library/Caches/MacDefier-release}"
STAGE_ROOT="$(assert_safe_scratch "$STAGE_ROOT" "release stage" release-stage)"
STAGE_APP="$STAGE_ROOT/MacDefier.app"
echo "==> [4/8] stage (local cache) + deep sign verify"
find "$STAGE_ROOT" -mindepth 1 -maxdepth 1 ! -name '.macdefier-release-stage' -exec rm -rf -- {} +
mkdir -p "$DIST"
ditto "$APP_IN_CACHE" "$STAGE_APP"
# NOTICE 缺失立即失败（M11-3）
NOTICE_SRC=""
if [[ -f "$CACHE/NOTICE" ]]; then NOTICE_SRC="$CACHE/NOTICE"
elif [[ -f "$ROOT/app/NOTICE" ]]; then NOTICE_SRC="$ROOT/app/NOTICE"
elif [[ -f "$(dirname "$0")/../NOTICE" ]]; then NOTICE_SRC="$(dirname "$0")/../NOTICE"
fi
[[ -n "$NOTICE_SRC" && -f "$NOTICE_SRC" ]] || { echo "ERROR: NOTICE missing — refuse release" >&2; exit 1; }
ditto "$NOTICE_SRC" "$STAGE_APP/Contents/Resources/NOTICE"
test -f "$STAGE_APP/Contents/Resources/NOTICE" || { echo "ERROR: NOTICE not in App Resources" >&2; exit 1; }

# notary 前拒绝 debug / preview dylib 与 ad-hoc 签名（M11-4）
if find "$STAGE_APP" \( -name '*.debug.dylib' -o -name '__preview.dylib' \) | grep -q .; then
  echo "ERROR: debug/preview dylib in stage — refuse notary" >&2
  find "$STAGE_APP" \( -name '*.debug.dylib' -o -name '__preview.dylib' \) >&2
  exit 1
fi

# 清掉 iCloud/Finder 扩展属性（否则 codesign: resource fork / Finder information not allowed）
xattr -cr "$STAGE_APP" 2>/dev/null || true
find "$STAGE_APP" -print0 | xargs -0 xattr -c 2>/dev/null || true

# 内嵌可执行文件先签，再签主 bundle（--deep 对某些 layout 不够稳）
while IFS= read -r -d '' bin; do
  # Skip the main app binary here; signed with entitlements below
  if [[ "$(basename "$bin")" == "MacDefier" ]] && [[ "$bin" == *"/MacOS/MacDefier" ]]; then
    continue
  fi
  if ! codesign --force --options runtime --timestamp \
    --sign "$SIGN_ID" "$bin"; then
    echo "ERROR: codesign failed for embedded binary: $bin" >&2
    exit 1
  fi
done < <(find "$STAGE_APP/Contents" -type f -perm -111 -print0 2>/dev/null)

codesign --force --options runtime --timestamp \
  --entitlements "$CACHE/$ENTITLEMENTS_REL" \
  --sign "$SIGN_ID" \
  "$STAGE_APP"

codesign --verify --deep --strict --verbose=2 "$STAGE_APP"
spctl -a -vv -t exec "$STAGE_APP" 2>&1 || true
codesign -dv --verbose=4 "$STAGE_APP" 2>&1 | head -40

echo "==> [5/8] zip for notary + submit"
ZIP_FOR_NOTARY="$STAGE_ROOT/MacDefier-${VER}-notary.zip"
rm -f "$ZIP_FOR_NOTARY"
ditto -c -k --sequesterRsrc --keepParent "$STAGE_APP" "$ZIP_FOR_NOTARY"

xcrun notarytool submit "$ZIP_FOR_NOTARY" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> [6/8] staple app"
xcrun stapler staple "$STAGE_APP"
xcrun stapler validate "$STAGE_APP"
spctl -a -vv -t exec "$STAGE_APP"

echo "==> [7/8] DMG + ZIP 分发包 → vault dist/release/"
# 正式名仅 notary+staple 成功后写入；trial 在 dist/trial/ 且带 -unsigned
DIST_REL="$DIST/release"
mkdir -p "$DIST_REL"
DMG_STAGE="$STAGE_ROOT/dmg-stage"
DMG_OUT_LOCAL="$STAGE_ROOT/MacDefier-${VER}.dmg"
ZIP_OUT_LOCAL="$STAGE_ROOT/MacDefier-${VER}.zip"
DMG_OUT="$DIST_REL/MacDefier-${VER}.dmg"
ZIP_OUT="$DIST_REL/MacDefier-${VER}.zip"
# 已存在同版本正式包时 fail，不静默覆盖
if [[ -f "$DMG_OUT" || -f "$ZIP_OUT" ]]; then
  echo "ERROR: release artifact already exists for ${VER} — refuse overwrite" >&2
  echo "  $DMG_OUT / $ZIP_OUT" >&2
  exit 1
fi
rm -rf "$DMG_STAGE" "$DMG_OUT_LOCAL" "$ZIP_OUT_LOCAL"
mkdir -p "$DMG_STAGE"

ditto "$STAGE_APP" "$DMG_STAGE/MacDefier.app"
ln -s /Applications "$DMG_STAGE/Applications"

cat > "$DMG_STAGE/使用说明.txt" << EOF
MacDefier ${VER}

系统要求
- macOS 14.0 或更高
- Apple Silicon 或 Intel

安装
1. 打开本 DMG
2. 把 MacDefier.app 拖到 Applications
3. 从启动台或「应用程序」打开

说明
- 已 Developer ID 签名并经 Apple 公证
- 清理默认进废纸篓，可预览
- AI 可选；关闭不影响清理/卸载
EOF
cp "$DMG_STAGE/使用说明.txt" "$DMG_STAGE/README.txt"

hdiutil create \
  -volname "MacDefier ${VER}" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 \
  "$DMG_OUT_LOCAL"

codesign --force --sign "$SIGN_ID" --timestamp "$DMG_OUT_LOCAL"
xcrun notarytool submit "$DMG_OUT_LOCAL" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG_OUT_LOCAL"
xcrun stapler validate "$DMG_OUT_LOCAL"
spctl -a -vv -t open --context context:primary-signature "$DMG_OUT_LOCAL"

(
  cd "$DMG_STAGE"
  # ZIP 根必须有 NOTICE
  test -f "MacDefier.app/Contents/Resources/NOTICE" \
    || { echo "ERROR: NOTICE missing in staged app" >&2; exit 1; }
  cp "MacDefier.app/Contents/Resources/NOTICE" NOTICE
  zip -ry "$ZIP_OUT_LOCAL" MacDefier.app 使用说明.txt README.txt NOTICE
)

# dist/release: dmg/zip/sha only — no loose .app
rm -rf "$DIST/MacDefier.app"
ditto "$DMG_OUT_LOCAL" "$DMG_OUT"
ditto "$ZIP_OUT_LOCAL" "$ZIP_OUT"
rm -rf "$DMG_STAGE" "$ZIP_FOR_NOTARY"

echo "==> [8/8] checksums"
shasum -a 256 "$DMG_OUT" | tee "$DIST_REL/MacDefier-${VER}.dmg.sha256"
shasum -a 256 "$ZIP_OUT" | tee "$DIST_REL/MacDefier-${VER}.sha256"
ls -lh "$DMG_OUT" "$ZIP_OUT"

echo ""
echo "OK 正式包："
echo "  DMG: $DMG_OUT"
echo "  ZIP: $ZIP_OUT"
echo "发给别人：优先发 DMG。对方拖到 Applications 即可，无需右键仍要打开。"
echo "本地已公证 app 缓存：$STAGE_APP"
