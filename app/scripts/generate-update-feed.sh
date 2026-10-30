#!/usr/bin/env bash
# Local-only Sparkle feed generation. Never uploads or modifies a release archive.
# Usage: MACDEFIER_SPARKLE_TOOLS_DIR=/path/to/Sparkle/bin ./generate-update-feed.sh ARCHIVE VERSION [OUTPUT_DIR]
#        ./generate-update-feed.sh --check-signing
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd -- "$script_dir/.." && pwd)"
signing_account="com.macdefier.app.sparkle"
update_repo="${MACDEFIER_UPDATE_REPOSITORY:-KunZhang1997/MacDefier}"

fail() { echo "ERROR: $*" >&2; exit 1; }

resolve_tools() {
  local candidate
  if [[ -n "${MACDEFIER_SPARKLE_TOOLS_DIR:-}" ]]; then
    candidate="$MACDEFIER_SPARKLE_TOOLS_DIR"
    [[ -x "$candidate/generate_appcast" ]] || candidate="$candidate/bin"
  else
    candidate="$app_dir/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [[ ! -x "$candidate/generate_appcast" ]]; then
      candidate="${MACDEFIER_BUILD_CACHE:-$HOME/Library/Caches/MacDefier-build}/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    fi
  fi
  for tool in generate_keys generate_appcast sign_update; do
    [[ -x "$candidate/$tool" ]] || fail "Sparkle tools missing. Set MACDEFIER_SPARKLE_TOOLS_DIR to the pinned Sparkle distribution's bin directory."
  done
  sparkle_bin="$(cd -- "$candidate" && pwd -P)"
}

check_signing() {
  # -p only looks up an existing key. Do not silently create a release signing identity.
  if ! signing_public_key="$("$sparkle_bin/generate_keys" --account "$signing_account" -p 2>/dev/null)"; then
    fail "Sparkle signing key unavailable. Run '$sparkle_bin/generate_keys --account $signing_account' once, put its public key in SUPublicEDKey, and keep a secure backup of the key."
  fi
  [[ "$signing_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || fail "Sparkle signing account has no valid public key. Check Keychain access for $signing_account."
}

check_configured_key() {
  local configured_key
  # project.yml is authoritative even before XcodeGen has emitted Config/Info.plist.
  configured_key="$(ruby -ryaml -e 'print YAML.load_file(ARGV.fetch(0)).dig("targets", "MacDefier", "info", "properties", "SUPublicEDKey").to_s' "$app_dir/project.yml")"
  if [[ -z "$configured_key" && -f "$app_dir/Config/Info.plist" ]]; then
    configured_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_dir/Config/Info.plist" 2>/dev/null)"
  fi
  [[ -n "$configured_key" ]] || fail "Configure target.info.properties.SUPublicEDKey in project.yml before packaging."
  [[ "$configured_key" == "$signing_public_key" ]] \
    || fail "Configured SUPublicEDKey does not match Keychain account $signing_account. Correct the project public key before building; never export a private key into the project."
}

resolve_tools
check_signing
if [[ "${1:-}" == --check-signing ]]; then
  [[ $# == 1 ]] || fail "Usage: $0 --check-signing"
  check_configured_key
  echo "Sparkle signing key is available for $signing_account."
  exit 0
fi
[[ $# -ge 2 && $# -le 3 ]] || fail "Usage: $0 ARCHIVE VERSION [OUTPUT_DIR]"
archive_input="$1"
expected_version="$2"
[[ "$expected_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "VERSION must be a numeric release version."
[[ "$update_repo" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] \
  || fail "MACDEFIER_UPDATE_REPOSITORY must be a GitHub owner/repository, not a URL."
release_tag="${MACDEFIER_RELEASE_TAG:-v${expected_version}}"
[[ "$release_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "MACDEFIER_RELEASE_TAG contains unsupported characters."
archive_dir="$(cd -- "$(dirname -- "$archive_input")" && pwd -P)"
archive_name="$(basename -- "$archive_input")"
archive="$archive_dir/$archive_name"
[[ -f "$archive" && ! -L "$archive" ]] || fail "Release archive must be a regular local file."
case "$archive_name" in
  "MacDefier-${expected_version}.dmg"|"MacDefier-${expected_version}.zip") ;;
  *) fail "Archive name must match MacDefier-${expected_version}.dmg or .zip; do not relabel an old package." ;;
esac
output_dir="${3:-$archive_dir}"
mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
[[ ! -L "$output_dir/appcast.xml" ]] || fail "Refusing to replace a symlink appcast.xml."

feed_scratch="$(mktemp -d /private/tmp/MacDefier-update-feed.XXXXXX)"
mounted_image=false
feed_output_temp=""
cleanup_feed() {
  local status=$?
  if [[ -n "$feed_output_temp" ]]; then rm -f -- "$feed_output_temp"; fi
  if [[ "$mounted_image" == true ]]; then
    if ! hdiutil detach "$feed_scratch/mount" >/dev/null; then
      echo "Could not detach read-only image; temporary files retained at $feed_scratch" >&2
      return "$status"
    fi
  fi
  rm -rf -- "$feed_scratch"
  return "$status"
}
trap cleanup_feed EXIT
mkdir "$feed_scratch/unpacked" "$feed_scratch/updates" "$feed_scratch/mount"
case "$archive_name" in
  *.dmg)
    hdiutil attach -readonly -nobrowse -mountpoint "$feed_scratch/mount" "$archive" >/dev/null
    mounted_image=true
    archive_app="$feed_scratch/mount/MacDefier.app"
    codesign --verify --strict "$archive"
    ;;
  *.zip)
    ditto -x -k "$archive" "$feed_scratch/unpacked"
    archive_app="$feed_scratch/unpacked/MacDefier.app"
    ;;
esac
info_plist="$archive_app/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "Archive does not contain MacDefier.app/Contents/Info.plist."
read_info() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null \
    || fail "Final app is missing Info.plist key $1. Rebuild the app before generating a feed."
}
bundle_id="$(read_info CFBundleIdentifier)"
bundle_version="$(read_info CFBundleVersion)"
short_version="$(read_info CFBundleShortVersionString)"
bundle_public_key="$(read_info SUPublicEDKey)"
[[ "$bundle_id" == com.macdefier.app ]] || fail "Feed must target com.macdefier.app, not a Debug or other app."
[[ "$bundle_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "Final CFBundleVersion must be numeric."
[[ "$short_version" == "$expected_version" ]] \
  || fail "Archive contains version $short_version (build $bundle_version), not $expected_version. Rebuild instead of renaming an older installer."
[[ "$bundle_public_key" == "$signing_public_key" ]] \
  || fail "Final app SUPublicEDKey does not match the Keychain account $signing_account. Rebuild with the matching public key; do not publish."
[[ "$(read_info SURequireSignedFeed)" == true && "$(read_info SUVerifyUpdateBeforeExtraction)" == true ]] \
  || fail "Final app must enable SURequireSignedFeed and SUVerifyUpdateBeforeExtraction as booleans."
expected_feed_url="https://github.com/$update_repo/releases/latest/download/appcast.xml"
[[ "$(read_info SUFeedURL)" == "$expected_feed_url" ]] \
  || fail "Final app SUFeedURL does not match $expected_feed_url."
codesign --verify --deep --strict "$archive_app"
if [[ "$mounted_image" == true ]]; then
  hdiutil detach "$feed_scratch/mount" >/dev/null
  mounted_image=false
fi

download_prefix="https://github.com/$update_repo/releases/download/$release_tag/"
ditto "$archive" "$feed_scratch/updates/$archive_name"
if ! "$sparkle_bin/generate_appcast" --account "$signing_account" \
  --download-url-prefix "$download_prefix" --link "https://github.com/$update_repo" \
  --versions "$bundle_version" --maximum-versions 0 --maximum-deltas 0 \
  -o "$feed_scratch/appcast.xml" "$feed_scratch/updates" >"$feed_scratch/generate.log" 2>&1; then
  tail -20 "$feed_scratch/generate.log" >&2
  fail "Sparkle could not generate a signed appcast. Existing release artifacts and feed were not changed."
fi
[[ -s "$feed_scratch/appcast.xml" ]] || fail "Sparkle did not generate appcast.xml."
# Sign explicitly as well: feeds cannot accidentally become unsigned if tool defaults change.
"$sparkle_bin/sign_update" --account "$signing_account" "$feed_scratch/appcast.xml"

archive_size="$(stat -f %z "$archive")"
archive_signature="$(ruby -rrexml/document - "$feed_scratch/appcast.xml" "$bundle_version" "$short_version" "$archive_size" "$download_prefix$archive_name" <<'RUBY'
document = REXML::Document.new(File.read(ARGV[0]))
items = document.get_elements('/rss/channel/item')
abort 'ERROR: Expected exactly one generated update item.' unless items.length == 1
item = items.first
enclosure = item.elements['enclosure']
abort 'ERROR: Appcast version does not match the final app.' unless item.elements['sparkle:version']&.text == ARGV[1]
abort 'ERROR: Appcast display version does not match the final app.' unless item.elements['sparkle:shortVersionString']&.text == ARGV[2]
abort 'ERROR: Appcast download URL or length is incorrect.' unless enclosure && enclosure.attributes['url'] == ARGV[4] && enclosure.attributes['length'] == ARGV[3]
signature = enclosure.attributes['sparkle:edSignature'].to_s
abort 'ERROR: Appcast archive signature is missing.' if signature.empty?
print signature
RUBY
)"
"$sparkle_bin/sign_update" --account "$signing_account" --verify "$archive" "$archive_signature"
"$sparkle_bin/sign_update" --account "$signing_account" --verify "$feed_scratch/appcast.xml"
# Replace only the latest feed, after every check succeeds. Versioned archives remain untouched.
[[ ! -L "$output_dir/appcast.xml" ]] || fail "Refusing to replace a symlink appcast.xml."
feed_output_temp="$(mktemp "$output_dir/.appcast.xml.XXXXXX")"
ditto "$feed_scratch/appcast.xml" "$feed_output_temp"
chmod 644 "$feed_output_temp"
mv -f "$feed_output_temp" "$output_dir/appcast.xml"
feed_output_temp=""
echo "Signed appcast: $output_dir/appcast.xml (version $short_version, build $bundle_version, tag $release_tag)"
echo "Publish this feed with the exact, unchanged $archive_name in the matching GitHub Release."
