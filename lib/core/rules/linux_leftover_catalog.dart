import '../models/leftover_models.dart';

/// Curated uninstall leftovers for Linux desktop applications.
///
/// Data paths are XDG directories owned by one application. Install detection
/// combines the package inventory (dpkg/rpm/flatpak/snap) with explicit
/// flatpak, snap, and local-binary markers. A candidate is only produced when a
/// data directory exists and every marker and package id is absent.
abstract final class LinuxLeftoverCatalog {
  static const entries = <LeftoverCatalogEntry>[
    LeftoverCatalogEntry(
      id: 'linux-slack',
      appName: 'Slack',
      appNameEn: 'Slack',
      description:
          'Slack 的本地配置、登录状态与会话缓存。'
          '仅在检测不到 Slack 安装信息时显示；清理会丢失本地登录状态和设置。',
      descriptionEn:
          'Slack local settings, sign-in state, and session caches. Shown only '
          'when a Slack installation cannot be detected; cleaning removes the '
          'local sign-in state and settings.',
      dataPathPatterns: [r'$XDG_CONFIG_HOME/Slack', r'$XDG_CACHE_HOME/slack'],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/com.slack.Slack',
        r'/var/lib/flatpak/app/com.slack.Slack',
        r'/snap/slack/current',
        r'$HOME/.local/bin/slack',
        r'/usr/bin/slack',
        r'/usr/local/bin/slack',
      ],
      installDisplayNamePrefixes: ['Slack'],
      installPackageIds: ['slack', 'com.slack.Slack'],
    ),
    LeftoverCatalogEntry(
      id: 'linux-discord',
      appName: 'Discord',
      appNameEn: 'Discord',
      description:
          'Discord 的本地配置、登录状态与消息缓存。'
          '仅在检测不到 Discord 安装信息时显示；清理会丢失本地登录状态和设置。',
      descriptionEn:
          'Discord local settings, sign-in state, and message caches. Shown '
          'only when a Discord installation cannot be detected; cleaning '
          'removes the local sign-in state and settings.',
      dataPathPatterns: [
        r'$XDG_CONFIG_HOME/discord',
        r'$XDG_CACHE_HOME/discord',
      ],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/com.discordapp.Discord',
        r'/var/lib/flatpak/app/com.discordapp.Discord',
        r'/snap/discord/current',
        r'$HOME/.local/bin/discord',
        r'/usr/bin/discord',
        r'/usr/local/bin/discord',
      ],
      installDisplayNamePrefixes: ['Discord'],
      installPackageIds: ['discord', 'com.discordapp.Discord'],
    ),
    LeftoverCatalogEntry(
      id: 'linux-vscode',
      appName: 'VS Code',
      appNameEn: 'VS Code',
      description:
          'VS Code 的本地用户设置、扩展状态与缓存，代码文件不在此目录。'
          '仅在检测不到 VS Code 安装信息时显示；清理会丢失本地设置。',
      descriptionEn:
          'VS Code local user settings, extension state, and caches. Source '
          'files are not stored here. Shown only when a VS Code installation '
          'cannot be detected; cleaning removes the local settings.',
      dataPathPatterns: [r'$XDG_CONFIG_HOME/Code', r'$XDG_CACHE_HOME/Code'],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/com.visualstudio.code',
        r'/var/lib/flatpak/app/com.visualstudio.code',
        r'/snap/code/current',
        r'$HOME/.local/bin/code',
        r'/usr/bin/code',
        r'/usr/local/bin/code',
      ],
      installDisplayNamePrefixes: ['Visual Studio Code', 'Code'],
      installPackageIds: ['code', 'com.visualstudio.code'],
    ),
    LeftoverCatalogEntry(
      id: 'linux-obsidian',
      appName: 'Obsidian',
      appNameEn: 'Obsidian',
      description:
          'Obsidian 的应用配置、主题与插件设置。'
          '笔记库（vault）由用户单独选择位置，不在此目录，不会被清理。'
          '仅在检测不到 Obsidian 安装信息时显示。',
      descriptionEn:
          'Obsidian app settings, themes, and plugin configuration. The note '
          'vault lives wherever the user chose and is never touched. Shown only '
          'when an Obsidian installation cannot be detected.',
      dataPathPatterns: [
        r'$XDG_CONFIG_HOME/obsidian',
        r'$XDG_CACHE_HOME/obsidian',
      ],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/md.obsidian.Obsidian',
        r'/var/lib/flatpak/app/md.obsidian.Obsidian',
        r'/snap/obsidian/current',
        r'$HOME/.local/bin/obsidian',
        r'/usr/bin/obsidian',
        r'/usr/local/bin/obsidian',
      ],
      installDisplayNamePrefixes: ['Obsidian'],
      installPackageIds: ['obsidian', 'md.obsidian.Obsidian'],
    ),
    LeftoverCatalogEntry(
      id: 'linux-spotify',
      appName: 'Spotify',
      appNameEn: 'Spotify',
      description:
          'Spotify 桌面端的本地配置、登录状态与缓存。'
          '离线内容需要重新下载；仅在检测不到 Spotify 安装信息时显示。',
      descriptionEn:
          'Spotify desktop local settings, sign-in state, and caches. Offline '
          'content must be downloaded again; shown only when a Spotify '
          'installation cannot be detected.',
      dataPathPatterns: [
        r'$XDG_CONFIG_HOME/spotify',
        r'$XDG_CACHE_HOME/spotify',
      ],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/com.spotify.Client',
        r'/var/lib/flatpak/app/com.spotify.Client',
        r'/snap/spotify/current',
        r'$HOME/.local/bin/spotify',
        r'/usr/bin/spotify',
        r'/usr/local/bin/spotify',
      ],
      installDisplayNamePrefixes: ['Spotify'],
      installPackageIds: ['spotify-client', 'spotify', 'com.spotify.Client'],
    ),
    LeftoverCatalogEntry(
      id: 'linux-signal',
      appName: 'Signal',
      appNameEn: 'Signal',
      description:
          'Signal 桌面端的本地消息数据库、附件缓存与登录状态。'
          '清理后本地聊天记录无法恢复，重新使用需要再次配对设备。'
          '仅在检测不到 Signal 安装信息时显示。',
      descriptionEn:
          'Signal desktop local message database, attachment caches, and '
          'sign-in state. Cleaning removes local chat history permanently and '
          'requires pairing the device again. Shown only when a Signal '
          'installation cannot be detected.',
      dataPathPatterns: [r'$XDG_CONFIG_HOME/Signal', r'$XDG_CACHE_HOME/Signal'],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/org.signal.Signal',
        r'/var/lib/flatpak/app/org.signal.Signal',
        r'/snap/signal-desktop/current',
        r'$HOME/.local/bin/signal-desktop',
        r'/usr/bin/signal-desktop',
        r'/usr/local/bin/signal-desktop',
      ],
      installDisplayNamePrefixes: ['Signal'],
      installPackageIds: ['signal-desktop', 'org.signal.Signal'],
    ),
    LeftoverCatalogEntry(
      id: 'linux-zoom',
      appName: 'Zoom',
      appNameEn: 'Zoom',
      description:
          'Zoom 的本地配置、登录状态与虚拟背景设置。'
          '本地录制文件位于用户选择的保存目录，不在清理范围。'
          '仅在检测不到 Zoom 安装信息时显示。',
      descriptionEn:
          'Zoom local settings, sign-in state, and virtual background '
          'configuration. Local recordings live in the user-selected folder '
          'and are out of scope. Shown only when a Zoom installation cannot be '
          'detected.',
      dataPathPatterns: [r'$XDG_CONFIG_HOME/zoom', r'$XDG_CACHE_HOME/zoom'],
      installMarkerPatterns: [
        r'$XDG_DATA_HOME/flatpak/app/us.zoom.Zoom',
        r'/var/lib/flatpak/app/us.zoom.Zoom',
        r'/snap/zoom-client/current',
        r'$HOME/.local/bin/zoom',
        r'/usr/bin/zoom',
        r'/usr/local/bin/zoom',
      ],
      installDisplayNamePrefixes: ['Zoom'],
      installPackageIds: ['zoom', 'us.zoom.Zoom', 'zoom-client'],
    ),
  ];

  static const _allowedDataRoots = <String>[
    r'$XDG_CONFIG_HOME',
    r'$XDG_CACHE_HOME',
    r'$XDG_DATA_HOME',
    r'$HOME',
  ];

  static const _sharedDataRoots = <String>{
    r'$XDG_CONFIG_HOME',
    r'$XDG_CACHE_HOME',
    r'$XDG_DATA_HOME',
    r'$HOME',
    r'$HOME/.config',
    r'$HOME/.cache',
    r'$HOME/.local',
    r'$HOME/.local/share',
    r'$HOME/.local/bin',
    r'$XDG_DATA_HOME/applications',
    r'$XDG_DATA_HOME/flatpak',
    r'$XDG_DATA_HOME/Trash',
  };

  static LeftoverCatalogEntry? entryForRuleId(String ruleId) {
    if (!ruleId.startsWith(leftoverRuleIdPrefix)) return null;
    final id = ruleId.substring(leftoverRuleIdPrefix.length);
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  static void validate() => validateEntries(entries);

  static void validateEntries(List<LeftoverCatalogEntry> entries) {
    final ids = <String>{};
    final dataPaths = <String>{};
    for (final entry in entries) {
      if (!RegExp(r'^[a-z0-9][a-z0-9_.-]*$').hasMatch(entry.id)) {
        throw FormatException('Linux 卸载残留清单 id 无效：${entry.id}');
      }
      if (entry.id.startsWith(leftoverRuleIdPrefix)) {
        throw FormatException('Linux 卸载残留清单 id 不能包含规则前缀：${entry.id}');
      }
      if (!ids.add(entry.id)) {
        throw FormatException('Linux 卸载残留清单 id 重复：${entry.id}');
      }
      _requireText(entry.appName, '${entry.id}.appName');
      _requireText(entry.appNameEn, '${entry.id}.appNameEn');
      _requireText(entry.description, '${entry.id}.description');
      _requireText(entry.descriptionEn, '${entry.id}.descriptionEn');
      if (entry.dataPathPatterns.isEmpty) {
        throw FormatException('${entry.id} 缺少数据目录');
      }
      if (entry.installMarkerPatterns.isEmpty) {
        throw FormatException('${entry.id} 缺少安装标记');
      }
      if (entry.installDisplayNamePrefixes.isEmpty &&
          entry.installPackageIds.isEmpty) {
        throw FormatException('${entry.id} 缺少安装识别信息');
      }
      for (final prefix in entry.installDisplayNamePrefixes) {
        _requireText(prefix, '${entry.id}.installDisplayNamePrefixes');
      }
      for (final packageId in entry.installPackageIds) {
        if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$')
            .hasMatch(packageId.trim())) {
          throw FormatException('${entry.id} 的包名无效：$packageId');
        }
      }
      for (final pattern in entry.dataPathPatterns) {
        _validateDataPath(pattern, entry);
        if (!dataPaths.add(pattern.toLowerCase())) {
          throw FormatException('${entry.id} 的数据目录与其他条目重复：$pattern');
        }
      }
      for (final pattern in entry.installMarkerPatterns) {
        _validateInstallMarker(pattern, entry);
      }
      _validateNoInstallOverlap(entry);
    }
  }

  static void _requireText(String value, String field) {
    if (value.trim().isEmpty) {
      throw FormatException('Linux 卸载残留清单字段为空：$field');
    }
  }

  static void _validateDataPath(String pattern, LeftoverCatalogEntry entry) {
    _validateCommonPath(pattern, entry);
    if (pattern.contains('*') || pattern.contains('?')) {
      throw FormatException('${entry.id} 的数据目录不能使用通配符：$pattern');
    }
    final root = _dataRootOf(pattern);
    if (root == null) {
      throw FormatException('${entry.id} 的数据目录必须位于 XDG 用户目录：$pattern');
    }
    if (pattern == root) {
      throw FormatException('${entry.id} 的数据目录不能是根目录：$pattern');
    }
    final normalized = pattern.toLowerCase();
    if (_sharedDataRoots.any((root) => root.toLowerCase() == normalized)) {
      throw FormatException('${entry.id} 的数据目录指向共享目录：$pattern');
    }
  }

  static void _validateInstallMarker(
    String pattern,
    LeftoverCatalogEntry entry,
  ) {
    _validateCommonPath(pattern, entry);
    if (!pattern.startsWith(r'$') &&
        !pattern.startsWith('~') &&
        !pattern.startsWith('/')) {
      throw FormatException('${entry.id} 的安装标记必须以环境变量、~ 或 / 开头：$pattern');
    }
    final segments = pattern
        .split(RegExp(r'[\\/]'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      throw FormatException('${entry.id} 的安装标记不能是根目录：$pattern');
    }
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final hasWildcard = segment.contains('*') || segment.contains('?');
      if (hasWildcard && index != segments.length - 1) {
        throw FormatException('${entry.id} 的安装标记通配符只能位于最后一段：$pattern');
      }
    }
  }

  static void _validateNoInstallOverlap(LeftoverCatalogEntry entry) {
    for (final marker in entry.installMarkerPatterns) {
      final markerDir = _markerDirectory(marker);
      if (markerDir == null) continue;
      for (final dataPath in entry.dataPathPatterns) {
        final data = dataPath.toLowerCase();
        final install = markerDir.toLowerCase();
        if (_isSameOrAncestor(data, install) ||
            _isSameOrAncestor(install, data)) {
          throw FormatException('${entry.id} 的数据目录与安装目录重叠：$dataPath 与 $marker');
        }
      }
    }
  }

  static String? _markerDirectory(String pattern) {
    final match = RegExp(r'[\\/][^\\/]*$').firstMatch(pattern);
    if (match == null || match.start == 0) return null;
    return pattern.substring(0, match.start);
  }

  static bool _isSameOrAncestor(String ancestor, String candidate) {
    if (candidate == ancestor) return true;
    return candidate.startsWith('$ancestor/');
  }

  static void _validateCommonPath(String pattern, LeftoverCatalogEntry entry) {
    if (pattern.isEmpty || pattern != pattern.trim()) {
      throw FormatException('${entry.id} 的路径为空或包含首尾空白：$pattern');
    }
    if (pattern.endsWith('\\') || pattern.endsWith('/')) {
      throw FormatException('${entry.id} 的路径不能以分隔符结尾：$pattern');
    }
    if (pattern.contains('\u0000') ||
        pattern.contains('<') ||
        pattern.contains('>') ||
        pattern.contains('|') ||
        pattern.contains('"')) {
      throw FormatException('${entry.id} 的路径包含非法字符：$pattern');
    }
    if (RegExp(r'(^|[\\/])\.\.([\\/]|$)').hasMatch(pattern)) {
      throw FormatException('${entry.id} 的路径不能包含 ..：$pattern');
    }
  }

  static String? _dataRootOf(String pattern) {
    for (final root in _allowedDataRoots) {
      if (pattern.startsWith('$root/')) return root;
    }
    return null;
  }
}
