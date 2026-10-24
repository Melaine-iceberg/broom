/// Fallback version for platforms without a native version channel.
///
/// Desktop runners read `pubspec.yaml` at build time and expose the result
/// through `broom/system`, so this constant does not need a release-time edit.
const String broomAppVersion = '0.4.0';
