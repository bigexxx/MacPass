#!/bin/bash

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") --notary-profile <profile> [--team-id <team>] [--archive-path <path>] [--export-path <path>]

Builds a signed Developer ID archive, exports MacPass.app, submits it for notarization,
staples the ticket, and verifies the resulting app.

Required:
  --notary-profile   Keychain profile configured for xcrun notarytool

Optional:
  --team-id          Apple Developer Team ID to force during archive/export
  --archive-path     Output xcarchive path (default: /tmp/MacPass.xcarchive)
  --export-path      Output folder for exported app (default: /tmp/MacPass-export)
EOF
}

NOTARY_PROFILE=""
TEAM_ID=""
ARCHIVE_PATH="/tmp/MacPass.xcarchive"
EXPORT_PATH="/tmp/MacPass-export"
PROFILE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --archive-path)
            ARCHIVE_PATH="$2"
            shift 2
            ;;
        --export-path)
            EXPORT_PATH="$2"
            shift 2
            ;;
        --profile-name)
            PROFILE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${NOTARY_PROFILE}" ]]; then
    echo "Missing required --notary-profile" >&2
    usage
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/MacPass.xcodeproj"
SCHEME="MacPass"
APP_NAME="MacPass.app"
APP_PATH="${EXPORT_PATH}/${APP_NAME}"
ZIP_PATH="${EXPORT_PATH}/MacPass.zip"
EXPORT_OPTIONS_PLIST="${EXPORT_PATH}/ExportOptions.plist"

build_setting() {
    local key="$1"
    xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' -v key="${key}" '$1 ~ key"$" { print $2; exit }'
}

if [[ -z "${PROFILE_NAME}" ]]; then
    PROFILE_NAME="$(build_setting "PROVISIONING_PROFILE_SPECIFIER")"
fi

BUNDLE_ID="$(build_setting "PRODUCT_BUNDLE_IDENTIFIER")"

mkdir -p "${EXPORT_PATH}"
rm -rf "${ARCHIVE_PATH}" "${APP_PATH}" "${ZIP_PATH}" "${EXPORT_OPTIONS_PLIST}"

cat > "${EXPORT_OPTIONS_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
EOF

if [[ -n "${TEAM_ID}" ]]; then
    cat >> "${EXPORT_OPTIONS_PLIST}" <<EOF
    <key>teamID</key>
    <string>${TEAM_ID}</string>
EOF
fi

if [[ -n "${PROFILE_NAME}" && -n "${BUNDLE_ID}" ]]; then
    cat >> "${EXPORT_OPTIONS_PLIST}" <<EOF
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${PROFILE_NAME}</string>
    </dict>
EOF
fi

cat >> "${EXPORT_OPTIONS_PLIST}" <<EOF
</dict>
</plist>
EOF

ARCHIVE_CMD=(
    xcodebuild
    -project "${PROJECT_PATH}"
    -scheme "${SCHEME}"
    -configuration Release
    -archivePath "${ARCHIVE_PATH}"
    archive
)

EXPORT_CMD=(
    xcodebuild
    -exportArchive
    -archivePath "${ARCHIVE_PATH}"
    -exportPath "${EXPORT_PATH}"
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"
)

if [[ -n "${TEAM_ID}" ]]; then
    ARCHIVE_CMD+=(DEVELOPMENT_TEAM="${TEAM_ID}")
fi

echo "Archiving signed release..."
"${ARCHIVE_CMD[@]}"

echo "Exporting Developer ID app..."
"${EXPORT_CMD[@]}"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Expected exported app at ${APP_PATH}" >&2
    exit 1
fi

echo "Packaging app for notarization..."
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "Submitting for notarization..."
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "${APP_PATH}"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=4 "${APP_PATH}"

echo "Assessing with Gatekeeper..."
spctl --assess --type execute -vv "${APP_PATH}"

echo "Release app is ready at ${APP_PATH}"
