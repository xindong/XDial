#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or newer}"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.1.12297006}"
bash scripts/prepare-patched-go-mod.sh
mkdir -p build/android/tools
export GOWORK="$PWD/build/patched-go/xdial.work"
export GOFLAGS=
# Build the generator from the same pinned module as gomobile.
go build -o build/android/tools/gobind github.com/sagernet/gomobile/cmd/gobind
export PATH="$PWD/build/android/tools:$PATH"
go run github.com/sagernet/gomobile/cmd/gomobile bind \
 -target="${ANDROID_GO_TARGET:-android/arm64,android/amd64}" -androidapi 26 \
 -trimpath -buildvcs=false -ldflags="-s -w" \
 -tags with_gvisor,with_utls -o build/android/Libbox.aar ./core/libbox
