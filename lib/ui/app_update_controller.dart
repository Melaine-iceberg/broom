import 'package:flutter/foundation.dart';

import '../core/app/app_update_service.dart';
import '../core/app/linux_app_update_service.dart';
import '../core/platform/app_version.dart';
import '../l10n/broom_strings.dart';

enum AppUpdateDistribution { windowsInstaller, linuxPackage }

/// Drives the "software update" section in settings.
///
/// It only ever reads the published feed and compares versions. Installing is
/// left to the platform: Windows uses App Installer, while Linux users update
/// through their distribution package manager or by replacing the tar.gz
/// bundle. The app never downloads or launches installers itself.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.versionSource,
    this.fetcher,
    this.distribution = AppUpdateDistribution.windowsInstaller,
  });

  final AppVersionSource versionSource;
  final AppUpdateFetcher? fetcher;
  final AppUpdateDistribution distribution;

  bool get usesWindowsInstaller =>
      distribution == AppUpdateDistribution.windowsInstaller;

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

  String get feedUrl => usesWindowsInstaller
      ? AppUpdateService.compiledFeedUrl
      : LinuxAppUpdateService.compiledFeedUrl;

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
      final info = usesWindowsInstaller
          ? await AppUpdateService(
              currentVersion: version,
              fetcher: fetcher,
            ).check()
          : await LinuxAppUpdateService(
              currentVersion: version,
              fetcher: fetcher,
            ).check();
      _info = info;
      _checked = true;
      if (!info.hasUpdate) {
        _notice = tr('当前已是最新版本。');
      } else if (usesWindowsInstaller) {
        _notice = trf(
          '发现新版本 {latest}（当前 {current}）。Windows 会在后台完成更新，重启应用即可生效。',
          {
            'latest': info.latestVersion.toString(),
            'current': version.toString(),
          },
        );
      } else {
        _notice = trf('发现新版本 {latest}（当前 {current}）。请下载新版本安装包，或通过发行版包管理器升级。', {
          'latest': info.latestVersion.toString(),
          'current': version.toString(),
        });
      }
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
