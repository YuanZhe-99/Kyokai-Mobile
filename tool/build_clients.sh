#!/bin/bash
# Builds Kyokai's SSH, Remote Desktop and VNC clients (third_party/kyokai
# cmd/kyokai-clients, Go) for Android with the NDK and puts
# libkyokai_clients.so where Gradle packs it.
#
#   tool/build_clients.sh          arm64-v8a
#
# Needs: Go (go.mod's version) and the NDK from ANDROID_NDK_HOME, else the
# newest under the Android SDK.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk" ]; then
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) sdk="$LOCALAPPDATA/Android/Sdk" ;;
	Darwin) sdk="$HOME/Library/Android/sdk" ;;
	*) sdk="$HOME/Android/Sdk" ;;
	esac
fi
ndk="${ANDROID_NDK_HOME:-$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)}"
[ -d "$ndk" ] || { echo "no NDK: set ANDROID_NDK_HOME" >&2; exit 1; }
host=$(ls "$ndk/toolchains/llvm/prebuilt" | head -1)
bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
ext=""
[ -e "$bin/clang.exe" ] && ext=".cmd"

out="$root/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$out"
cd third_party/kyokai
# 16 KB pages, as Android 15 devices may use.
CC="$bin/aarch64-linux-android26-clang$ext" GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
	go build -buildmode=c-shared -trimpath \
	-ldflags="-s -w -extldflags=-Wl,-z,max-page-size=16384" \
	-o "$out/libkyokai_clients.so" ./cmd/kyokai-clients
rm -f "$out/libkyokai_clients.h"
ls -la "$out/libkyokai_clients.so"
