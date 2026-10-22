#!/bin/bash
# Sign the archive and feed with our update key, independently of Apple code signing.
set -euo pipefail
cd "$(dirname "$0")/.."

arch="${1:-}"
version="${2:-}"
archive="${3:-}"
if [[ "$#" != 3 || ! "$arch" =~ ^(arm64|x64)$ || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "Usage: $0 <arm64|x64> <version> <dmg>" >&2
    exit 2
fi
[[ -s "$archive" && "$(basename "$archive")" == "Mac-TaskManager-v${version}-${arch}.dmg" ]] || {
    echo "Update archive missing or named incorrectly." >&2; exit 1;
}
archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
feed="$(dirname "$archive")/appcast-${arch}.xml"
tools_dir="$PWD/.build/sparkle-tools/2.10.0"
mkdir -p "$tools_dir"
if [[ ! -f "$tools_dir/Sparkle.tar.xz" ]]; then
    curl --fail --location --retry 3 \
        https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
        --output "$tools_dir/Sparkle.tar.xz"
fi
printf '%s  %s\n' c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c "$tools_dir/Sparkle.tar.xz" | shasum -a 256 -c -
tar -xf "$tools_dir/Sparkle.tar.xz" -C "$tools_dir"

signing_args=(--account local.Mac-TaskManager.updates)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    signing_args=(--ed-key-file -)
fi
with_signing_key() {
    if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
        printf '%s' "$SPARKLE_PRIVATE_KEY" | "$@" "${signing_args[@]}"
    else
        "$@" "${signing_args[@]}"
    fi
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mac-update-feed.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
cp "$archive" "$work_dir/$(basename "$archive")"
with_signing_key "$tools_dir/bin/generate_appcast" \
    --download-url-prefix "https://github.com/Flashhhhhhzj/mac-task-manager/releases/download/v${version}/" \
    --full-release-notes-url "https://github.com/Flashhhhhhzj/mac-task-manager/releases/tag/v${version}" \
    --link "https://github.com/Flashhhhhhzj/mac-task-manager/releases/tag/v${version}" \
    --maximum-deltas 0 --maximum-versions 1 -o "$feed" "$work_dir"
archive_signature="$(with_signing_key "$tools_dir/bin/sign_update" -p "$archive")"
# Check the signing secret against the public key actually embedded by build.sh.
swift - "$(<updates/public-key.txt)" "$archive_signature" "$archive" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
guard let publicData = Data(base64Encoded: args[1]), let signature = Data(base64Encoded: args[2]) else {
    fatalError("Malformed update signing key or signature")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else { fatalError("Update signing secret does not match bundled public key") }
SWIFT
python3 - "$feed" "$archive" "$version" "$archive_signature" <<'PY'
import base64
import os
import sys
import xml.etree.ElementTree as ET

feed, archive, version, signature = sys.argv[1:]
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
ET.register_namespace("sparkle", ns["s"])
tree = ET.parse(feed)
item = tree.getroot().find("channel/item")
if item is None:
    raise SystemExit("Appcast has no update item")
enclosure = item.find("enclosure")
expected = f"https://github.com/Flashhhhhhzj/mac-task-manager/releases/download/v{version}/{os.path.basename(archive)}"
if enclosure is None or enclosure.get("url") != expected or int(enclosure.get("length", "0")) != os.path.getsize(archive):
    raise SystemExit("Appcast archive URL or size mismatch")
# Older bundles lack SUPublicEDKey, so generate_appcast omits their archive signature.
enclosure.set("{" + ns["s"] + "}edSignature", signature)
if len(base64.b64decode(signature, validate=True)) != 64:
    raise SystemExit("Appcast archive signature missing")
if item.findtext("s:shortVersionString", namespaces=ns) != version.split("-")[0]:
    raise SystemExit("Appcast version does not match archive")
tree.write(feed, encoding="utf-8", xml_declaration=True)
PY
with_signing_key "$tools_dir/bin/sign_update" "$feed"
with_signing_key "$tools_dir/bin/sign_update" --verify "$feed"
echo "Signed update feed ready: $feed"
