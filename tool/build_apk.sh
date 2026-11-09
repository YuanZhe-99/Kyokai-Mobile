#!/bin/bash
# Builds the signed release APK for arm64 phones, stamped with the commit
# and time the diagnostics page shows. Signs with android/key.properties
# when present (the kyokai key), else the debug key.
#
#   tool/build_apk.sh            then: build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f android/app/src/main/jniLibs/arm64-v8a/libkyokai_core.so ] || { echo "no core: run tool/build_core.sh" >&2; exit 1; }
commit=$(git rev-parse --short HEAD 2>/dev/null || echo none)
git diff --quiet HEAD 2>/dev/null || commit="$commit+"
flutter build apk --release --target-platform android-arm64 \
	--dart-define=BUILD_COMMIT="$commit" \
	--dart-define=BUILD_TIME="$(date -u +%Y-%m-%dT%H:%MZ)"
