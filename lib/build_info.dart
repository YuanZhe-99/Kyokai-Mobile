// What build this is, for diagnostics and bug reports. Release builds pass
// these with --dart-define (tool/build_apk.sh); a plain `flutter run` shows
// the defaults.

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.1.0');
const buildNumber = String.fromEnvironment('BUILD_NUMBER', defaultValue: '1');
const buildCommit = String.fromEnvironment('BUILD_COMMIT', defaultValue: 'dev');
const buildTime = String.fromEnvironment('BUILD_TIME', defaultValue: '-');
