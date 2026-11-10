#!/bin/bash
# Builds the signed release APK for arm64 phones, stamped with the version,
# commit and time the About section and the diagnostics page show. Signs
# with android/key.properties when present (the kyokai key), else the
# debug key.
#
#   tool/build_apk.sh            then: build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f android/app/src/main/jniLibs/arm64-v8a/libkyokai_core.so ] || { echo "no core: run tool/build_core.sh" >&2; exit 1; }
commit=$(git rev-parse --short HEAD 2>/dev/null || echo none)
git diff --quiet HEAD 2>/dev/null || commit="$commit+"
# The version is pubspec.yaml's, the one Android shows too: 0.1.0+1 is
# name 0.1.0, build 1.
version=$(sed -n 's/^version: *//p' pubspec.yaml)
name=${version%%+*}
build=1
case "$version" in *+*) build=${version#*+} ;; esac
flutter build apk --release --target-platform android-arm64 \
	--dart-define=APP_VERSION="$name" \
	--dart-define=BUILD_NUMBER="$build" \
	--dart-define=BUILD_COMMIT="$commit" \
	--dart-define=BUILD_TIME="$(date -u +%Y-%m-%dT%H:%MZ)"
