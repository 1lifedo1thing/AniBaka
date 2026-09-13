#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "Usage: $0 <app-path> <identity> <keychain> <use-timestamp> <entitlements>" >&2
  exit 64
fi

app_path=$1
signing_identity=$2
signing_keychain=$3
use_timestamp=$4
entitlements_path=$5

if [ ! -d "$app_path" ]; then
  echo "::error::macOS app bundle was not found at $app_path."
  exit 1
fi
if [ ! -f "$entitlements_path" ]; then
  echo "::error::macOS entitlements were not found at $entitlements_path."
  exit 1
fi

# Signing the bundle's main executable also seals the enclosing app. Leave it
# for the final bundle signature, after all frameworks have been signed.
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")
executable_path="$app_path/Contents/MacOS/$executable_name"
if [ -z "$executable_name" ] || [ ! -f "$executable_path" ]; then
  echo "::error::macOS main executable was not found at $executable_path."
  exit 1
fi

# Bash 3.2 treats an empty array as unset under nounset.
timestamp_option=
if [ "$use_timestamp" = "true" ]; then
  timestamp_option=--timestamp
fi

sign_code() {
  echo "Signing nested code: $1"
  codesign \
    --force \
    --verbose \
    --options runtime \
    ${timestamp_option:+"$timestamp_option"} \
    --keychain "$signing_keychain" \
    --sign "$signing_identity" \
    "$1"
}

# Apple requires manual signing to proceed from the innermost code outwards.
# Signing nested Mach-O files first also replaces vendor signatures on media_kit's
# versioned frameworks, including Ass.framework/Versions/A/Ass.
while IFS= read -r -d '' item; do
  if [ "$item" -ef "$executable_path" ]; then
    continue
  fi
  if file -b "$item" | grep -q 'Mach-O'; then
    sign_code "$item"
  fi
done < <(find "$app_path/Contents" -type f -print0)

# Seal nested code bundles after their executables, deepest bundle first.
while IFS= read -r -d '' item; do
  case "$item" in
    *.app|*.appex|*.bundle|*.framework|*.plugin|*.xpc)
      sign_code "$item"
      ;;
  esac
done < <(find "$app_path/Contents" -depth -type d -print0)

# The app is always signed last and must retain its runtime exceptions. A
# self-signed release identity has no Apple Team ID, while bundled media
# frameworks may carry a vendor Team ID; this entitlement prevents dyld from
# rejecting those libraries before main() runs.
echo "Signing app bundle: $app_path"
codesign \
  --force \
  --verbose \
  --options runtime \
  ${timestamp_option:+"$timestamp_option"} \
  --keychain "$signing_keychain" \
  --sign "$signing_identity" \
  --entitlements "$entitlements_path" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

signed_entitlements=$(mktemp "${RUNNER_TEMP:-/tmp}/anibaka-entitlements.XXXXXX")
trap 'rm -f "$signed_entitlements"' EXIT
codesign --display --entitlements :- "$app_path" > "$signed_entitlements"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$signed_entitlements" 2>/dev/null)" != "true" ]; then
  echo "::error::The signed app is missing the disable-library-validation entitlement."
  exit 1
fi
