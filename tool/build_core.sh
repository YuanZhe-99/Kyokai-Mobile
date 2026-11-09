#!/bin/bash
# Builds Kyokai's Rust core (the third_party/kyokai submodule) for Android
# with the NDK and puts libkyokai_core.so where Gradle packs it
# (android/app/src/main/jniLibs/<abi>/).
#
#   tool/build_core.sh                 arm64-v8a, release
#   tool/build_core.sh arm64-v8a x86_64
#   CHECK=1 tool/build_core.sh         cargo check only
#
# Needs: the Rust toolchain the submodule pins with the Android targets
# (rustup target add aarch64-linux-android x86_64-linux-android), and the
# NDK from ANDROID_NDK_HOME, else the newest under the Android SDK.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

abis=("$@")
[ ${#abis[@]} -eq 0 ] && abis=(arm64-v8a)

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
api=26

for abi in "${abis[@]}"; do
	case "$abi" in
	arm64-v8a) target=aarch64-linux-android ;;
	x86_64) target=x86_64-linux-android ;;
	*) echo "unsupported ABI $abi" >&2; exit 1 ;;
	esac
	env=$(echo "$target" | tr - _)
	upper=$(echo "$env" | tr '[:lower:]' '[:upper:]')
	export "CC_$env=$bin/$target$api-clang$ext"
	export "CXX_$env=$bin/$target$api-clang++$ext"
	export "AR_$env=$bin/llvm-ar"
	export "CARGO_TARGET_${upper}_LINKER=$bin/$target$api-clang$ext"
	export CARGO_TARGET_DIR="$root/build/core"
	cd "$root/third_party/kyokai/core"
	if [ -n "${CHECK:-}" ]; then
		cargo check -p kyokai-core --target "$target"
	else
		cargo build -p kyokai-core --release --target "$target"
		mkdir -p "$root/android/app/src/main/jniLibs/$abi"
		cp "$CARGO_TARGET_DIR/$target/release/libkyokai_core.so" "$root/android/app/src/main/jniLibs/$abi/"
	fi
	cd "$root"
done
