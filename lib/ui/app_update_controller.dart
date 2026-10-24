import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app/app_update_service.dart';
import '../core/app/linux_app_update_service.dart';
import '../core/app/linux_update_installer.dart';
import '../core/platform/app_version.dart';
import '../l10n/broom_strings.dart';

enum AppUpdateDistribution { windowsInstaller, linuxPackage }

/// Drives the "software update" section in settings.
///
/// Windows only reads the App Installer feed and lets Windows perform the
/// update. On Linux the controller can download and verify the manifest
/// artifact itself: AppImages are replaced atomically, deb / RPM packages are
/// handed to the desktop software installer, and everything else stays on disk
/// with manual instructions. Downloaded code is never executed by Broom.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.versionSource,
    this.fetcher,
    this.distribution = AppUpdateDistribution.windowsInstaller,
    this.installer,
    void Function()? exitApp,
  }) : _exitApp = exitApp ?? _defaultExitApp;

  final AppVersionSource versionSource;
  final AppUpdateFetcher? fetcher;
  final AppUpdateDistribution distribution;
  final LinuxUpdateInstaller? installer;
  final void Function() _exitApp;

  bool get usesWindowsInstaller =>
      distribution == AppUpdateDistribution.windowsInstaller;

  AppVersion? _currentVersion;
  AppUpdateInfo? _info;
  LinuxUpdateArtifact? _artifact;
  String? _installUnavailableReason;
  bool _busy = false;
  bool _checked = false;
  String? _error;
  String? _notice;
  bool _installing = false;
  double? _downloadProgress;
  int? _downloadTotal;
  String? _installError;
  String? _installNotice;
  LinuxUpdateInstallOutcome? _installOutcome;
  bool _disposed = false;

  bool get busy => _busy;

  bool get checked => _checked;

  String? get error => _error;

  String? get notice => _notice;

  AppUpdateInfo? get info => _info;

  bool get installing => _installing;

  /// `0..1` while downloading, or null when the total size is unknown.
  double? get downloadProgress => _downloadProgress;

  int? get downloadTotal => _downloadTotal;

  String? get installError => _installError;

  String? get installNotice => _installNotice;

  LinuxUpdateInstallOutcome? get installOutcome => _installOutcome;

  bool get canInstallInApp =>
      !usesWindowsInstaller &&
      installer != null &&
      info != null &&
      info!.hasUpdate &&
      _artifact != null;

  /// Explains why the in-app install action is unavailable after a check.
  String? get installUnavailableReason => _installUnavailableReason;

  bool get restartAvailable =>
      _installOutcome?.mode == LinuxUpdateInstallMode.appImageReplaced;

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
    _installError = null;
    _installNotice = null;
    _installOutcome = null;
    _installUnavailableReason = null;
    _artifact = null;
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
      if (!usesWindowsInstaller &&
          installer != null &&
          info is LinuxAppUpdateInfo) {
        _artifact = installer!.selectArtifact(info);
        if (info.hasUpdate) {
          _installUnavailableReason = installer!.unavailableReason(info);
        }
      }
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
      } else if (installer == null) {
        _notice = trf('发现新版本 {latest}（当前 {current}）。请下载新版本安装包，或通过发行版包管理器升级。', {
          'latest': info.latestVersion.toString(),
          'current': version.toString(),
        });
      } else if (_artifact != null) {
        _notice = trf('发现新版本 {latest}（当前 {current}）。可下载并校验安装包后完成更新。', {
          'latest': info.latestVersion.toString(),
          'current': version.toString(),
        });
      } else {
        _notice = trf('发现新版本 {latest}（当前 {current}）。请按下方说明完成更新。', {
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

  /// Downloads the selected artifact, verifies its SHA-256 and applies it.
  Future<void> installUpdate() async {
    final currentInstaller = installer;
    final artifact = _artifact;
    if (_installing || currentInstaller == null || artifact == null) return;
    _installing = true;
    _installError = null;
    _installNotice = null;
    _installOutcome = null;
    _downloadProgress = 0;
    _downloadTotal = null;
    _notify();
    var lastNotifiedProgress = -1.0;
    try {
      final package = await currentInstaller.download(
        artifact: artifact,
        onProgress: (received, total) {
          _downloadTotal = total;
          final progress = total != null && total > 0
              ? (received / total).clamp(0.0, 1.0).toDouble()
              : null;
          _downloadProgress = progress;
          final bucket = progress == null
              ? 0.0
              : (progress * 100).floor() / 100;
          if (bucket != lastNotifiedProgress) {
            lastNotifiedProgress = bucket;
            _notify();
          }
        },
        isActive: () => !_disposed,
      );
      _downloadProgress = 1;
      _notify();
      if (_disposed) return;
      final outcome = await currentInstaller.install(
        package: package,
        artifact: artifact,
        isActive: () => !_disposed,
      );
      _installOutcome = outcome;
      switch (outcome.mode) {
        case LinuxUpdateInstallMode.appImageReplaced:
          _installNotice = tr('更新已安装，重启应用后生效。');
        case LinuxUpdateInstallMode.installerOpened:
          _installNotice = tr('更新包已校验，并交给系统安装器。请完成授权与安装。');
        case LinuxUpdateInstallMode.manual:
          _installNotice = outcome.detail ?? tr('更新包已校验并保存，请按说明手动完成安装。');
      }
    } on AppUpdateException catch (error) {
      _installError = error.message;
    } catch (error) {
      _installError = trf('安装更新失败：{error}', {'error': error});
    } finally {
      _installing = false;
      _downloadProgress = null;
      _downloadTotal = null;
      _notify();
    }
  }

  /// Starts the freshly replaced AppImage and closes the current instance.
  Future<void> restartApp() async {
    final currentInstaller = installer;
    final path = _installOutcome?.path;
    if (currentInstaller == null || path == null || !restartAvailable) return;
    try {
      await currentInstaller.relaunch(path);
      _exitApp();
    } catch (error) {
      _installError = trf('无法重启应用：{error}', {'error': error});
      _notify();
    }
  }

  Future<void> openDownloadsFolder() async {
    final currentInstaller = installer;
    if (currentInstaller == null) return;
    final opened = await currentInstaller.openDownloadsFolder();
    if (!opened) {
      _installError = tr('无法打开更新包所在目录。');
      _notify();
    }
  }

  static void _defaultExitApp() => exit(0);

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
