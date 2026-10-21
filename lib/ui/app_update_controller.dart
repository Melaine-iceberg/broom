import 'package:flutter/foundation.dart';

import '../core/app/app_update_service.dart';
import '../core/platform/app_version.dart';
import '../l10n/broom_strings.dart';

/// Drives the "software update" section in settings.
///
/// It only ever reads the published App Installer feed and compares versions.
/// Installing is left to Windows: the app never downloads or launches installers
/// itself, which keeps the update path identical to the one a user gets by
/// opening `broom.appinstaller` by hand.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({required this.versionSource, this.fetcher});

  final AppVersionSource versionSource;
  final AppUpdateFetcher? fetcher;

  AppVersion? _currentVersion;
  AppUpdateInfo? _info;
  bool _busy = false;
  bool _checked = false;
  String? _error;
  String? _notice;
  bool _disposed = false;

  bool get busy => _busy;

  bool get checked => _checked;

  String? get error => _error;

  String? get notice => _notice;

  AppUpdateInfo? get info => _info;

  String get feedUrl => AppUpdateService.compiledFeedUrl;

  String? get currentVersion => _currentVersion?.toString();

  /// Reads the build-time version so the settings page can show it before the
  /// user ever runs a check.
  Future<void> loadVersion() async {
    if (_currentVersion != null) return;
    final version = await _readVersion();
    if (version == null || _disposed) return;
    _currentVersion = version;
    _notify();
  }

  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notice = null;
    _notify();
    try {
      final version = _currentVersion ?? await _readVersion();
      if (version == null) {
        throw const AppUpdateException('无法读取当前程序版本，可能是不完整的安装。');
      }
      _currentVersion = version;
      final service = AppUpdateService(
        currentVersion: version,
        fetcher: fetcher,
      );
      final info = await service.check();
      _info = info;
      _checked = true;
      _notice = info.hasUpdate
          ? trf('发现新版本 {latest}（当前 {current}）。Windows 会在后台完成更新，重启应用即可生效。', {
              'latest': info.latestVersion.toString(),
              'current': version.toString(),
            })
          : tr('当前已是最新版本。');
    } on AppUpdateException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = trf('检查更新失败：{error}', {'error': error});
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Reads the version once and caches it; a failed read is retried on the next
  /// check instead of being cached as a permanent failure.
  Future<AppVersion?> _readVersion() async {
    final raw = await versionSource.read();
    if (raw == null) return null;
    try {
      return AppVersion.parse(raw);
    } on FormatException {
      return null;
    }
  }

  void clearMessages() {
    _error = null;
    _notice = null;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
