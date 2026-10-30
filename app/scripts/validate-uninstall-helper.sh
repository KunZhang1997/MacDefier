#!/bin/bash
# Read-only packaging gate. Never starts, registers, or connects to the helper.
# Release packaging must call this without --structure-only.
set -euo pipefail
export LC_ALL=C

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s [--structure-only] APP_PATH\n' "$0" >&2; exit 2; }

structure_only=0
if [[ "${1:-}" == --structure-only ]]; then
  structure_only=1
  shift
fi
[[ $# == 1 && "$1" != -* ]] || usage
app="$1"
[[ -d "$app/Contents" ]] || fail "not an application bundle: $app"
app="$(cd "$app" && pwd -P)"
info="$app/Contents/Info.plist"
[[ -f "$info" && ! -L "$info" ]] || fail "missing or symlinked Info.plist"
/usr/bin/plutil -lint "$info" >/dev/null || fail "invalid Info.plist"

plist_string() {
  /usr/bin/plutil -extract "$2" raw -expect string -o - "$1" 2>/dev/null
}
bundle_id="$(plist_string "$info" CFBundleIdentifier)" || fail "missing bundle identifier"
case "$bundle_id" in
  com.macdefier.app|com.macdefier.app.dev) ;;
  *) fail "unsupported app bundle identifier: $bundle_id" ;;
esac
service="$bundle_id.uninstall-helper"
main_name="$(plist_string "$info" CFBundleExecutable)" || fail "missing main executable name"
[[ -n "$main_name" && "$main_name" != */* && "$main_name" != . && "$main_name" != .. ]] \
  || fail "invalid main executable name"
main="$app/Contents/MacOS/$main_name"
helper="$app/Contents/MacOS/MacDefier-UninstallHelper"
for executable in "$main" "$helper"; do
  [[ -f "$executable" && -x "$executable" && ! -L "$executable" ]] \
    || fail "missing, non-executable, or symlinked binary: $executable"
done
for directory in "$app/Contents" "$app/Contents/MacOS" "$app/Contents/Library" "$app/Contents/Library/LaunchDaemons"; do
  [[ -d "$directory" && ! -L "$directory" ]] || fail "missing or symlinked directory: $directory"
done

# Reject mixed Debug/Release services and unexpected launch configuration files.
shopt -s nullglob dotglob
launch_entries=("$app/Contents/Library/LaunchDaemons/"*)
shopt -u nullglob dotglob
[[ ${#launch_entries[@]} == 1 ]] || fail "LaunchDaemons must contain exactly one plist"
plist="$app/Contents/Library/LaunchDaemons/$service.plist"
[[ "${launch_entries[0]}" == "$plist" && -f "$plist" && ! -L "$plist" ]] \
  || fail "unexpected launch daemon plist; expected $service.plist"
/usr/bin/plutil -lint "$plist" >/dev/null || fail "invalid launch daemon plist"
[[ "$(plist_string "$plist" Label)" == "$service" ]] || fail "launch daemon Label mismatch"
[[ "$(plist_string "$plist" BundleProgram)" == Contents/MacOS/MacDefier-UninstallHelper ]] \
  || fail "launch daemon BundleProgram mismatch"
mach_keys="$(/usr/bin/plutil -extract MachServices raw -expect dictionary -o - "$plist" 2>/dev/null)" \
  || fail "MachServices must be a dictionary"
[[ "$mach_keys" == "$service" ]] || fail "MachServices must advertise only $service"
# Dots in a plutil key path must be escaped; check type as well as value.
service_key="${service//./\\.}"
mach_enabled="$(/usr/bin/plutil -extract "MachServices.$service_key" raw -expect bool -o - "$plist" 2>/dev/null)" \
  || fail "MachServices entry must be a boolean"
[[ "$mach_enabled" == true ]] || fail "MachServices entry must be true"
for override in Program ProgramArguments; do
  if /usr/bin/plutil -type "$override" "$plist" >/dev/null 2>&1; then
    fail "launch daemon must not override BundleProgram with $override"
  fi
done

architectures() {
  /usr/bin/lipo -archs "$1" | /usr/bin/tr ' ' '\n' | /usr/bin/sort -u
}
main_arches="$(architectures "$main")" || fail "main executable is not a valid Mach-O"
helper_arches="$(architectures "$helper")" || fail "helper is not a valid Mach-O"
[[ -n "$main_arches" && "$helper_arches" == "$main_arches" ]] || fail "helper/main architecture mismatch"

if (( structure_only )); then
  printf 'PASS: helper structure and architectures (%s). SIGNATURES NOT VALIDATED.\n' "$service"
  exit 0
fi

/usr/bin/codesign --verify --strict --all-architectures "$app" \
  || fail "app signature verification failed"
/usr/bin/codesign --verify --strict --all-architectures "$helper" \
  || fail "helper signature verification failed"

team=""
check_signature() {
  local target="$1" expected_id="$2" arch="$3" metadata identifier actual_team flags entitlements key
  metadata="$(/usr/bin/codesign -d --arch "$arch" --verbose=4 "$target" 2>&1)" \
    || fail "cannot read signature: $target ($arch)"
  identifier="$(printf '%s\n' "$metadata" | /usr/bin/sed -n 's/^Identifier=//p')"
  actual_team="$(printf '%s\n' "$metadata" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  flags="$(printf '%s\n' "$metadata" | /usr/bin/sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-fA-F]*\).*/\1/p')"
  [[ "$identifier" == "$expected_id" ]] || fail "signing identifier mismatch: $target ($arch)"
  [[ "$actual_team" =~ ^[A-Z0-9]{10}$ ]] || fail "missing valid signing Team: $target ($arch)"
  if [[ -z "$team" ]]; then team="$actual_team"; fi
  [[ "$actual_team" == "$team" ]] || fail "helper/main signing Team mismatch ($arch)"
  [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]] || fail "cannot read signature flags: $target ($arch)"
  (( (flags & 0x10000) != 0 && (flags & 0x2) == 0 )) \
    || fail "hardened runtime required; ad-hoc signature forbidden: $target ($arch)"
  /usr/bin/codesign --verify --strict --arch "$arch" \
    -R "=anchor apple generic and identifier \"$expected_id\" and certificate leaf[subject.OU] = \"$team\"" "$target" \
    || fail "Apple signing requirement failed: $target ($arch)"
  entitlements="$(/usr/bin/codesign -d --arch "$arch" --entitlements - --xml "$target" 2>/dev/null)" \
    || fail "cannot read entitlements: $target ($arch)"
  if [[ -n "$entitlements" ]]; then
    printf '%s' "$entitlements" | /usr/bin/plutil -lint - >/dev/null \
      || fail "invalid entitlements: $target ($arch)"
    for key in 'com\.apple\.security\.get-task-allow' 'com\.apple\.security\.cs\.disable-library-validation'; do
      if printf '%s' "$entitlements" | /usr/bin/plutil -type "$key" - >/dev/null 2>&1; then
        fail "forbidden entitlement $key: $target ($arch)"
      fi
    done
  fi
}

# Inspect every slice: the default codesign display only describes one architecture.
while IFS= read -r arch; do
  check_signature "$app" "$bundle_id" "$arch"
  check_signature "$helper" "$service" "$arch"
done <<< "$main_arches"
printf 'PASS: helper structure, signatures, Team %s, runtime, entitlements and architectures (%s).\n' "$team" "$service"
