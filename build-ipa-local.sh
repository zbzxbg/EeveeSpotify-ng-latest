#!/usr/bin/env bash
# Local IPA build — mirror of .github/workflows/main.yml. Produces an IPA
# you can sign with Sideloadly/AltStore/TrollStore.
#
# Pipeline:
#   1. Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source
#      (renamed module — see Tools/SwiftProtobufBuild/).
#   2. theos `make package FINALPACKAGE=1 NO_JBROOT=1` — produces .deb with
#      EeveeSpotify.dylib + EeveeSpotify.bundle + framework. NO_JBROOT=1 keeps
#      libroot (/var/jb/...) out of the dylib: this deb is only a dylib source,
#      and a load-time libroot dependency crashes the app on TrollStore.
#   3. Build zxPluginsInject.dylib — sideload compat shim (keychain redirect,
#      group containers, CloudKit stub). LC-injected via ipapatch in step 6.
#   4. cyan inject deb-contents (dylib + framework + bundle) into vanilla IPA
#      → Outputs/IPAS/<name>.ipa            (no patch)
#   5. copy that, then ipapatch LC-inject zxPluginsInject into main exec + every
#      appex → Outputs/IPAS/<name>-patched.ipa  ← TrollStore / sideload: this one
#   6. Strip Watch.app from both if it survived cyan -du.
#
# Requires: theos, cyan (pyzule-rw), ipapatch, dpkg, ldid, plutil.

set -euo pipefail

VANILLA_IPA="${1:-}"
[ -n "$VANILLA_IPA" ] && [ -f "$VANILLA_IPA" ] || {
    echo "usage: $0 <path/to/Spotify-vanilla.ipa>" >&2
    exit 1
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

[ -n "${THEOS:-}" ] || { [ -d "$HOME/theos" ] && export THEOS="$HOME/theos" || { echo "THEOS not set"; exit 1; }; }

VERSION=$(grep -E '^Version:' control | awk '{print $2}')
SPOT_VERSION=$(unzip -p "$VANILLA_IPA" 'Payload/Spotify.app/Info.plist' \
    | plutil -extract CFBundleShortVersionString raw - 2>/dev/null || echo "unknown")
OUT_DIR="Outputs/IPAS"
OUT_IPA="$OUT_DIR/EeveeSpotify-${VERSION}-${SPOT_VERSION}.ipa"
mkdir -p "$OUT_DIR"

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

color "1/6  EeveeSwiftProtobuf.framework"
chmod +x Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh

color "2/6  theos make package"
# NO_JBROOT=1：这份 deb 只当 dylib 的来源，不发布。TrollStore / 侧载设备上
# 没有 /var/jb，而 libroot 是加载期依赖，链上它 App 会直接起不来。
THEOS_PACKAGE_SCHEME=rootless NO_JBROOT=1 make package FINALPACKAGE=1
DEB_FILE=$(ls -t packages/com.eevee.spotify_*.deb 2>/dev/null | head -1)
[ -n "$DEB_FILE" ] || { echo "deb not produced"; exit 1; }

color "3/6  zxPluginsInject.dylib"
chmod +x Tools/build-zxpi.sh
Tools/build-zxpi.sh >/dev/null

color "4/6  extract deb"
DEB_EXTRACT="$REPO_DIR/Outputs/deb-extract"
rm -rf "$DEB_EXTRACT"; mkdir -p "$DEB_EXTRACT"
dpkg-deb -R "$DEB_FILE" "$DEB_EXTRACT"
DYLIB_SRC=$(find "$DEB_EXTRACT" -name 'EeveeSpotify.dylib' | head -1)
BUNDLE_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSpotify.bundle' | head -1)
FRAMEWORK_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSwiftProtobuf.framework' | head -1)
[ -n "$DYLIB_SRC" ] || { echo "dylib not in deb"; exit 1; }

color "5/6  cyan inject"
INJECT=("$DYLIB_SRC")
[ -n "$FRAMEWORK_SRC" ] && INJECT+=("$FRAMEWORK_SRC")
[ -n "$BUNDLE_SRC" ]    && INJECT+=("$BUNDLE_SRC")
rm -f "$OUT_IPA"
cyan -i "$VANILLA_IPA" -o "$OUT_IPA" -f "${INJECT[@]}" -c 9 -m 15.0 -du

color "6/6  ipapatch LC-inject zxPluginsInject (patched copy)"
# 先复制再注入：$OUT_IPA 保持"无 patch"那份（tweak 本体），另一个文件才带
# zxPluginsInject。TrollStore / 侧载装 *-patched.ipa。
PATCHED_IPA="${OUT_IPA%.ipa}-patched.ipa"
cp -f "$OUT_IPA" "$PATCHED_IPA"
ipapatch --input "$PATCHED_IPA" --inplace --noconfirm --dylib packages/zxPluginsInject.dylib

# Belt-and-suspenders: cyan -du strips appex/Watch but verify. 两份都要查。
cd "$OUT_DIR"
for IPA in "$(basename "$OUT_IPA")" "$(basename "$PATCHED_IPA")"; do
    rm -rf Payload
    unzip -q "$IPA"
    if [ -d "Payload/Spotify.app/Watch" ]; then
        rm -rf Payload/Spotify.app/Watch
        zip -qry "$IPA" Payload
        echo "已剔除 Watch.app: $IPA"
    fi
    rm -rf Payload
done
cd - >/dev/null

color "Done"
ls -lh "$OUT_IPA" "$PATCHED_IPA"
cat <<'EOF'
  <name>.ipa          = 无 patch（tweak 本体：Orion + dylib + bundle + framework）
  <name>-patched.ipa  = 多一个 LC 注入的 zxPluginsInject（keychain / group / CloudKit 垫片）
                        → TrollStore / Sideloadly / AltStore 装这份
  两份都不依赖越狱路径（NO_JBROOT=1）；RootHide 越狱请装 roothide 的 .deb。
EOF
