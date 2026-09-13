#!/usr/bin/env bash
# Portable signing-order regression test. Apple tools are mocked; this does not
# replace codesign verification on a macOS runner.
set -euo pipefail

script_path=${1:-"$(cd "$(dirname "$0")/.." && pwd)/sign-macos-app.sh"}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/anibaka-signing-test.XXXXXX")
case "$fixture" in
  "${TMPDIR:-/tmp}"/anibaka-signing-test.*) ;;
  *) echo 'Unexpected temporary fixture path.' >&2; exit 1 ;;
esac
trap 'rm -rf "$fixture"' EXIT
app_path="$fixture/Test App.app"
framework_path="$app_path/Contents/Frameworks/Avfilter.framework"
mkdir -p "$app_path/Contents/MacOS" "$framework_path/Versions/A"
touch "$app_path/Contents/Info.plist" "$fixture/Release.entitlements"
touch "$app_path/Contents/MacOS/Baka" "$framework_path/Versions/A/Avfilter"

for timestamp in false true; do
  (
    nested_binary_signed=false
    framework_signed=false
    app_signed=false
    app_verified=false

    function /usr/libexec/PlistBuddy() {
      case "$2" in
        'Print :CFBundleExecutable') echo Baka ;;
        'Print :com.apple.security.cs.disable-library-validation') echo true ;;
        *) return 1 ;;
      esac
    }

    file() {
      case "$2" in
        */Baka|*/Avfilter) echo 'Mach-O 64-bit executable' ;;
        *) echo 'XML document' ;;
      esac
    }

    codesign() {
      local target="${!#}"
      case "$1" in
        --force)
          [[ " $* " != *' --deep '* ]]
          if [ "$timestamp" = true ]; then
            [[ " $* " == *' --timestamp '* ]]
          else
            [[ " $* " != *' --timestamp '* ]]
          fi
          case "$target" in
            "$app_path/Contents/MacOS/Baka")
              echo 'Main executable must only be signed through the final app bundle.' >&2
              return 1
              ;;
            "$framework_path/Versions/A/Avfilter") nested_binary_signed=true ;;
            "$framework_path")
              [ "$nested_binary_signed" = true ]
              framework_signed=true
              ;;
            "$app_path")
              [ "$framework_signed" = true ]
              [[ " $* " == *" --entitlements $fixture/Release.entitlements "* ]]
              app_signed=true
              ;;
            *) return 1 ;;
          esac
          ;;
        --verify)
          [ "$app_signed" = true ]
          [ "$target" = "$app_path" ]
          [[ " $* " == *' --deep --strict '* ]]
          app_verified=true
          ;;
        --display)
          [ "$app_verified" = true ]
          echo '<plist><dict/></plist>'
          ;;
        *) return 1 ;;
      esac
    }

    export RUNNER_TEMP="$fixture"
    source "$script_path" "$app_path" test-identity test-keychain "$timestamp" "$fixture/Release.entitlements"
    [ "$app_verified" = true ]
  )
done
echo 'macOS signing order, final entitlements, verification, and timestamp variants passed (mock tools).'
