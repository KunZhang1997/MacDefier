#!/usr/bin/env bash
# CI：唯一构建锁 / Sparkle 门禁 / UninstallHelperKit / CleanupKit / PetArchiveKit / MonitorKit / MacDefierTests + Debug & 双架构 Release 构建与资源门禁。
# 任何一步失败即退出；发布前必跑。
# Vault 在 iCloud Desktop 时，构建与单测在缓存目录跑，避免 NSFileCoordinator 卡死。
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIFECYCLE="$ROOT/app/scripts/single_app_build.py"
if [[ "${SINGLE_APP_PRODUCT:-}" != MacDefier ]]; then
  exec python3 "$LIFECYCLE" run /bin/bash "$0" "$@"
fi
APP_DIR="$ROOT/app"
CK_SRC="$APP_DIR/CleanupKit"
CK_CACHE="${MACDEFIER_CK_TEST_DIR:-$HOME/Library/Caches/MacDefier-CleanupKit-test}"
BUILD_CACHE="${MACDEFIER_BUILD_DIR:-$HOME/Library/Caches/MacDefier-build}"

assert_safe_scratch() {
  local requested="$1" label="$2" marker="$3"
  case "$requested" in
    "$HOME/Library/Caches/MacDefier-"*|"$HOME/Library/Caches/MacDefier/"*|/private/tmp/MacDefier-*|/tmp/MacDefier-*) ;;
    *) echo "拒绝不安全的 $label 路径：$requested" >&2; exit 2 ;;
  esac
  case "$requested" in
    *"/../"*|*"/.."|*"/./"*|*"//"*) echo "拒绝未规范化的 $label 路径：$requested" >&2; exit 2 ;;
  esac
  local parent="$(dirname "$requested")" leaf="$(basename "$requested")"
  [[ -d "$parent" ]] || mkdir -p "$parent"
  local path="$(cd "$parent" && pwd -P)/$leaf"
  [[ ! -L "$requested" ]] || { echo "拒绝符号链接 $label：$requested" >&2; exit 2; }
  [[ ! -e "$path" || -d "$path" ]] || { echo "$label 不是目录：$path" >&2; exit 2; }
  for broad in / "$HOME" "$ROOT" "$APP_DIR" "$CK_SRC"; do
    [[ "$path" != "$broad" && "$broad" != "$path/"* ]] \
      || { echo "拒绝项目/宽泛 $label 路径：$path" >&2; exit 2; }
  done
  [[ "$path" != "$ROOT/"* && "$path" != "$APP_DIR/"* && "$path" != "$CK_SRC/"* ]] \
    || { echo "拒绝项目内 $label 路径：$path" >&2; exit 2; }
  local cacheRoot="$(cd "$HOME/Library/Caches" && pwd -P)"
  [[ "$path" == "$cacheRoot/MacDefier-"* || "$path" == "$cacheRoot/MacDefier/"* \
      || "$path" == /private/tmp/MacDefier-* || "$path" == /tmp/MacDefier-* ]] \
    || { echo "拒绝 canonical 逃逸的 $label 路径：$path" >&2; exit 2; }
  mkdir -p "$path"
  local markerPath="$path/.macdefier-$marker"
  if [[ -f "$markerPath" ]]; then
    [[ "$(<"$markerPath")" == "macdefier-scratch-v1" ]] \
      || { echo "$label marker 无效：$markerPath" >&2; exit 2; }
  elif [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf '%s\n' 'macdefier-scratch-v1' > "$markerPath"
  else
    echo "拒绝复用没有 marker 的非空 $label：$path" >&2; exit 2
  fi
  printf '%s\n' "$path"
}

# XCTest / Swift Testing failures can yield EXIT 0 in mixed suites unless both
# text diagnostics and exit status are verified.
run_verified_swift_test() {
  local label="$1" pkg_dir="$2"
  shift 2
  set +e
  local test_log
  test_log="$(mktemp -t "macdefier-${label}-test.XXXXXX")"
  (cd "$pkg_dir" && swift test "$@" 2>&1 | tee "$test_log")
  local test_ec=${PIPESTATUS[0]}
  set -e
  if grep -Eiq 'failed \(| error: |XCTAssert[^[:space:]]* failed|Test Case .* failed| Testhad failures|failures before|failed \([1-9]' "$test_log"; then
    echo "==> $label tests reported failures (see log)" >&2
    rm -f "$test_log"
    exit 1
  fi
  if grep -E 'Executed [0-9]+ tests?' "$test_log" | tail -5 | grep -Eq 'with [1-9][0-9]* failure'; then
    echo "==> $label XCTest summary has failures" >&2
    rm -f "$test_log"
    exit 1
  fi
  if grep -Eiq '^error: |Building for debugging.*error:|Test Suite .* failed' "$test_log"; then
    echo "==> $label test build/run error" >&2
    rm -f "$test_log"
    exit 1
  fi
  if [[ "$test_ec" -ne 0 ]]; then
    echo "==> $label swift test exit $test_ec" >&2
    rm -f "$test_log"
    exit 1
  fi
  rm -f "$test_log"
}

verify_app_bundle_resources() {
  local app_bundle="$1" label="$2"
  local res_dir="$app_bundle/Contents/Resources"
  [[ -d "$res_dir" ]] || { echo "==> [$label] Resources 目录缺失：$res_dir" >&2; exit 1; }
  if find "$res_dir" -name '*.zip' -print -quit | grep -q .; then
    echo "==> [$label] 发现误打包的 .zip 资源（如 defier-guard-bot.zip）：" >&2
    find "$res_dir" -name '*.zip' >&2
    exit 1
  fi
  for required in "zh-Hans.lproj/Localizable.strings" "en.lproj/Localizable.strings" "Assets.car"; do
    [[ -f "$res_dir/$required" ]] || {
      echo "==> [$label] 缺少关键应用资源：$res_dir/$required" >&2
      exit 1
    }
  done
}

CK_CACHE="$(assert_safe_scratch "$CK_CACHE" "CleanupKit test cache" cleanup-test)"
BUILD_CACHE="$(assert_safe_scratch "$BUILD_CACHE" "build cache" build-cache)"
python3 "$LIFECYCLE" track "$BUILD_CACHE"

echo "==> [1/9] xcodegen（iCloud Desktop 下同步至构建缓存树）"
if [[ "$APP_DIR" == *"/Desktop/"* ]] || [[ "$APP_DIR" == *"Mobile Documents"* ]]; then
  rsync -a --delete \
    --exclude '.macdefier-*' \
    --exclude '.build' --exclude 'build' --exclude 'DerivedData' \
    --exclude 'CleanupKit/.build' --exclude 'MonitorKit/.build' \
    --exclude 'PetArchiveKit/.build' --exclude 'UninstallHelperKit/.build' \
    "$APP_DIR/" "$BUILD_CACHE/"
  WORK_APP="$BUILD_CACHE"
else
  WORK_APP="$APP_DIR"
fi
cd "$WORK_APP"
xcodegen generate

echo "==> [2/9] single_app_build.py 唯一构建锁与回滚单测"
python3 -B -m unittest discover -s "$WORK_APP/scripts/tests" -p "test_*.py"

echo "==> [3/9] Sparkle 更新源与嵌套签名顺序门禁"
bash "$WORK_APP/scripts/test-update-feed.sh"

echo "==> [4/9] UninstallHelperKit 单测（root 助手安全边界 / IPC）"
run_verified_swift_test "UninstallHelperKit" "$WORK_APP/UninstallHelperKit"

echo "==> [5/9] CleanupKit 单测（PathGate 删除安全 / 匹配引擎）"
rsync -a --delete \
  --exclude '.macdefier-*' \
  --exclude '.build' --exclude 'build' \
  "$CK_SRC/" "$CK_CACHE/"
if [[ "$WORK_APP" != "$APP_DIR" ]]; then
  rsync -a --delete --exclude '.build' --exclude '.macdefier-*' "$CK_SRC/" "$WORK_APP/CleanupKit/"
fi
run_verified_swift_test "CleanupKit" "$WORK_APP/CleanupKit" --scratch-path "$CK_CACHE/.build"

echo "==> [6/9] PetArchiveKit 单测（M10 pet zip symlink/slip）"
run_verified_swift_test "PetArchiveKit" "$WORK_APP/PetArchiveKit"

echo "==> [7/9] MonitorKit 单测（进程退出 / 超时 / Pipe / 采样生命周期）"
run_verified_swift_test "MonitorKit" "$WORK_APP/MonitorKit"

echo "==> [8/9] MacDefierTests 主工程单测（AI / 诊断 / 树图 / 更新 / 引导 / 卸载错误 / 本地化与几何）"
cd "$WORK_APP"
set +e
APP_TEST_LOG="$(mktemp -t macdefier-apptests.XXXXXX)"
xcodebuild test -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  -only-testing:MacDefierTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$APP_TEST_LOG"
APP_TEST_EC=${PIPESTATUS[0]}
set -e
if grep -Eiq '\*\* TEST FAILED \*\*|Test Case .* failed|XCTAssert[^[:space:]]* failed' "$APP_TEST_LOG" || [[ "$APP_TEST_EC" -ne 0 ]]; then
  echo "==> MacDefierTests failed (exit $APP_TEST_EC)" >&2
  rm -f "$APP_TEST_LOG"
  exit 1
fi
rm -f "$APP_TEST_LOG"

echo "==> [9/9] App 全量构建（Debug + 双架构 Release）与打包资源校验"
cd "$WORK_APP"
xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Debug \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
verify_app_bundle_resources "$WORK_APP/build/DerivedData/Build/Products/Debug/MacDefier-Dev.app" "Debug"

python3 "$LIFECYCLE" cleanup "$WORK_APP/build"

xcodebuild -project MacDefier.xcodeproj -scheme MacDefier -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
verify_app_bundle_resources "$WORK_APP/build/DerivedData/Build/Products/Release/MacDefier.app" "Release"

RELEASE_BIN="$WORK_APP/build/DerivedData/Build/Products/Release/MacDefier.app/Contents/MacOS/MacDefier"
RELEASE_ARCHS="$(lipo -archs "$RELEASE_BIN")"
if [[ "$RELEASE_ARCHS" != *"arm64"* || "$RELEASE_ARCHS" != *"x86_64"* ]]; then
  echo "==> [Release] 双架构校验失败，当前架构：$RELEASE_ARCHS" >&2
  exit 1
fi
if nm "$RELEASE_BIN" 2>/dev/null | grep -q 'IconExport'; then
  echo "==> [Release] IconExport 调试符号未隔离出正式包" >&2
  exit 1
fi

echo "==> CI OK：全链路单测 + Debug/双架构 Release 构建与资源校验全部通过"
