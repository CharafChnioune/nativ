#!/bin/bash
set -euo pipefail
# Runs trusted main-branch tooling only. It never builds or launches artifact code.
[[ $# == 1 && -f "$1" ]] || { echo 'Provide the unsigned fork ZIP artifact' >&2; exit 1; }
for name in RELEASE_SHA RELEASE_TAG GH_TOKEN APPLE_TEAM_ID DEVELOPER_ID_APPLICATION_P12_BASE64 \
  DEVELOPER_ID_APPLICATION_P12_PASSWORD PROVISIONING_PROFILE_BASE64 SPARKLE_PRIVATE_KEY \
  APPLE_API_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER; do
  [[ -n "${!name:-}" ]] || { echo "Missing owner setup: $name" >&2; exit 1; }
done
[[ "${GITHUB_REPOSITORY:-}" == CharafChnioune/nativ ]] || { echo 'Publisher is restricted to the fork' >&2; exit 1; }
python3 scripts/fork_release.py preflight --sha "$RELEASE_SHA" --tag "$RELEASE_TAG"
[[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || exit 1
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/nativ-fork-release.XXXXXX")"
keychain="$temporary_directory/signing.keychain-db"
cleanup() { security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$temporary_directory"; }
trap cleanup EXIT
python3 scripts/fork_release.py archive "$1"
ditto -x -k "$1" "$temporary_directory/app"
app="$temporary_directory/app/Nativ.app"
python3 scripts/fork_release.py bundle "$app" --sha "$RELEASE_SHA"
printf '%s' "$DEVELOPER_ID_APPLICATION_P12_BASE64" | base64 -D > "$temporary_directory/certificate.p12"
printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 -D > "$temporary_directory/fork.provisionprofile"
printf '%s' "$APPLE_API_KEY_P8_BASE64" | base64 -D > "$temporary_directory/notary.p8"
chmod 600 "$temporary_directory/certificate.p12" "$temporary_directory/fork.provisionprofile" "$temporary_directory/notary.p8"
keychain_password="$(uuidgen)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 10800 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$temporary_directory/certificate.p12" -P "$DEVELOPER_ID_APPLICATION_P12_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
scripts/sign_macos_release.sh --team-id "$APPLE_TEAM_ID" --provisioning-profile "$temporary_directory/fork.provisionprofile" "$app"
codesign --verify --deep --strict "$app"
version="${RELEASE_TAG#v}"
mkdir -p dist/release
archive="dist/release/Nativ-${version}.dmg"
scripts/package_macos_dmg.sh --team-id "$APPLE_TEAM_ID" --output "$archive" "$app"
scripts/notarize_macos_release.sh --key "$temporary_directory/notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" "$archive"
# The workflow prepared checksum-verified Sparkle binaries before this secret-bearing step.
# Swift package manifests are executable code: never resolve/build them here.
[[ -n "${SPARKLE_GENERATE_APPCAST:-}" && -x "$SPARKLE_GENERATE_APPCAST" ]] || {
  echo 'Verified Sparkle release tooling was not prepared' >&2; exit 1;
}
[[ -n "${SPARKLE_SIGN_UPDATE:-}" && -x "$SPARKLE_SIGN_UPDATE" ]] || {
  echo 'Verified Sparkle feed signing tooling was not prepared' >&2; exit 1;
}
export NATIV_GITHUB_REPOSITORY=CharafChnioune/nativ
scripts/generate_macos_appcast.sh --tag "$RELEASE_TAG" --output dist/release/appcast.xml "$archive"
# Recheck stale identity immediately before publishing. Existing signed assets are immutable.
python3 scripts/fork_release.py preflight --sha "$RELEASE_SHA" --tag "$RELEASE_TAG"
if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --verify-tag --draft --title "Nativ fork $version" --notes "Fork of Neywa-Labs/nativ with Live Translate. Combined commit: $RELEASE_SHA."
fi
existing="$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')"
if [[ -n "$existing" ]]; then echo 'Refusing to replace existing release assets' >&2; exit 1; fi
gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" "$archive" dist/release/appcast.xml
if [[ "$version" == *rc* ]]; then
  gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease
else
  gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest
fi
# Explicitly refresh the preview feed here: GITHUB_TOKEN release events do not chain workflows.
python3 scripts/macos_release.py publish-preview --repository "$GITHUB_REPOSITORY"
scripts/verify_macos_appcast.sh "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/appcast.xml" \
  "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/Nativ-$version.dmg" dist/release/appcast.xml
