import '../models/leftover_models.dart';

/// Curated uninstall leftovers for the supported applications.
///
/// Add an entry only after verifying both the data directory and every install
/// marker against a real installer. A wrong install marker can make a live
/// application look uninstalled.
abstract final class LeftoverCatalog {
  static const entries = <LeftoverCatalogEntry>[
    LeftoverCatalogEntry(
      id: 'slack',
      appName: 'Slack',
      appNameEn: 'Slack',
      description:
          'Slack 的本地配置、登录状态、会话缓存与离线数据。'
          '仅在检测不到 Slack 安装信息时显示；清理会丢失本地登录状态和设置。',
      descriptionEn:
          'Slack local settings, sign-in state, session caches, and '
          'offline data. Shown only when a Slack installation cannot be '
          'detected; cleaning removes the local sign-in state and settings.',
      dataPathPatterns: [r'%APPDATA%\Slack'],
      installMarkerPatterns: [r'%LOCALAPPDATA%\slack\app-*'],
      installDisplayNamePrefixes: ['Slack'],
    ),
    LeftoverCatalogEntry(
      id: 'discord',
      appName: 'Discord',
      appNameEn: 'Discord',
      description:
          'Discord 的本地配置、登录状态与消息缓存。'
          '仅在检测不到 Discord 安装信息时显示；清理会丢失本地登录状态和设置。',
      descriptionEn:
          'Discord local settings, sign-in state, and message '
          'caches. Shown only when a Discord installation cannot be detected; '
          'cleaning removes the local sign-in state and settings.',
      dataPathPatterns: [r'%APPDATA%\discord'],
      installMarkerPatterns: [r'%LOCALAPPDATA%\Discord\Update.exe'],
      installDisplayNamePrefixes: ['Discord'],
    ),
    LeftoverCatalogEntry(
      id: 'vscode',
      appName: 'VS Code',
      appNameEn: 'VS Code',
      description:
          'VS Code 的本地用户设置、扩展缓存与工作区状态，代码文件不在此目录。'
          '仅在检测不到 VS Code 安装信息时显示；清理会丢失本地设置。',
      descriptionEn:
          'VS Code local user settings, extension caches, and '
          'workspace state. Source files are not stored here. Shown only when '
          'a VS Code installation cannot be detected; cleaning removes the '
          'local settings.',
      dataPathPatterns: [r'%APPDATA%\Code'],
      installMarkerPatterns: [
        r'%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe',
        r'%PROGRAMFILES%\Microsoft VS Code\Code.exe',
      ],
      installDisplayNamePrefixes: [
        'Microsoft Visual Studio Code',
        'Visual Studio Code',
      ],
    ),
    LeftoverCatalogEntry(
      id: 'notion',
      appName: 'Notion',
      appNameEn: 'Notion',
      description:
          'Notion 的本地缓存、登录状态与离线页面副本。'
          '尚未同步到云端的编辑内容会随之丢失；页面正文保存在 Notion 服务器。'
          '仅在检测不到 Notion 安装信息时显示。',
      descriptionEn:
          'Notion local caches, sign-in state, and offline page copies. '
          'Edits that were never synced are lost; page content itself lives on '
          "Notion's servers. Shown only when a Notion installation cannot be "
          'detected.',
      dataPathPatterns: [r'%APPDATA%\Notion'],
      installMarkerPatterns: [
        r'%LOCALAPPDATA%\Notion\app-*',
        r'%LOCALAPPDATA%\Programs\Notion\Notion.exe',
      ],
      installDisplayNamePrefixes: ['Notion'],
    ),
    LeftoverCatalogEntry(
      id: 'obsidian',
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
      dataPathPatterns: [r'%APPDATA%\obsidian'],
      installMarkerPatterns: [
        r'%LOCALAPPDATA%\Obsidian\Obsidian.exe',
        r'%PROGRAMFILES%\Obsidian\Obsidian.exe',
      ],
      installDisplayNamePrefixes: ['Obsidian'],
    ),
    LeftoverCatalogEntry(
      id: 'figma',
      appName: 'Figma',
      appNameEn: 'Figma',
      description:
          'Figma 桌面端的本地缓存、登录状态与离线文件副本。'
          '未同步到云端的本地草稿会随之丢失。'
          '仅在检测不到 Figma 安装信息时显示。',
      descriptionEn:
          'Figma desktop caches, sign-in state, and offline file copies. Local '
          'drafts that were never synced are lost. Shown only when a Figma '
          'installation cannot be detected.',
      dataPathPatterns: [r'%APPDATA%\Figma'],
      installMarkerPatterns: [
        r'%LOCALAPPDATA%\Figma\Figma.exe',
        r'%LOCALAPPDATA%\Figma\app-*',
      ],
      installDisplayNamePrefixes: ['Figma'],
    ),
    LeftoverCatalogEntry(
      id: 'zoom',
      appName: 'Zoom',
      appNameEn: 'Zoom',
      description:
          'Zoom 的本地配置、登录状态与虚拟背景设置。'
          '本地录制文件位于“文档\\Zoom”，不在清理范围。'
          '仅在检测不到 Zoom 安装信息时显示。',
      descriptionEn:
          'Zoom local settings, sign-in state, and virtual background '
          'configuration. Local recordings under Documents\\Zoom are out of '
          'scope. Shown only when a Zoom installation cannot be detected.',
      dataPathPatterns: [r'%APPDATA%\Zoom\data'],
      installMarkerPatterns: [
        r'%APPDATA%\Zoom\bin\Zoom.exe',
        r'%PROGRAMFILES%\Zoom\bin\Zoom.exe',
      ],
      installDisplayNamePrefixes: ['Zoom'],
    ),
    LeftoverCatalogEntry(
      id: 'signal',
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
      dataPathPatterns: [r'%APPDATA%\Signal'],
      installMarkerPatterns: [
        r'%LOCALAPPDATA%\Programs\signal-desktop\Signal.exe',
        r'%LOCALAPPDATA%\Signal\app-*',
      ],
      installDisplayNamePrefixes: ['Signal'],
    ),
    LeftoverCatalogEntry(
      id: 'discord-ptb',
      appName: 'Discord PTB',
      appNameEn: 'Discord PTB',
      description:
          'Discord PTB 的本地配置、登录状态与消息缓存。'
          '仅在检测不到 Discord PTB 安装信息时显示；清理会丢失本地登录状态和设置。',
      descriptionEn:
          'Discord PTB local settings, sign-in state, and message caches. '
          'Shown only when a Discord PTB installation cannot be detected; '
          'cleaning removes the local sign-in state and settings.',
      dataPathPatterns: [r'%APPDATA%\discordptb'],
      installMarkerPatterns: [r'%LOCALAPPDATA%\DiscordPTB\Update.exe'],
      installDisplayNamePrefixes: ['Discord PTB'],
    ),
  ];

  static const _allowedDataRoots = <String>[
    r'%APPDATA%',
    r'%LOCALAPPDATA%',
    r'%USERPROFILE%\AppData\LocalLow',
  ];

  /// Vendor and container directories whose children are not owned by a
  /// single application. A leftover rule must never point at one of these.
  static const _sharedDataRoots = <String>[
    r'%APPDATA%\Adobe',
    r'%APPDATA%\Google',
    r'%APPDATA%\Microsoft',
    r'%LOCALAPPDATA%\Adobe',
    r'%LOCALAPPDATA%\Google',
    r'%LOCALAPPDATA%\Microsoft',
    r'%LOCALAPPDATA%\Packages',
    r'%LOCALAPPDATA%\Programs',
    r'%LOCALAPPDATA%\Temp',
    r'%USERPROFILE%\AppData\LocalLow\Google',
    r'%USERPROFILE%\AppData\LocalLow\Microsoft',
  ];

  static LeftoverCatalogEntry? entryForRuleId(String ruleId) {
    if (!isLeftoverRuleId(ruleId)) return null;
    final id = ruleId.substring(leftoverRuleIdPrefix.length);
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  static bool isLeftoverRuleId(String ruleId) =>
      ruleId.startsWith(leftoverRuleIdPrefix);

  static void validate() => validateEntries(entries);

  static void validateEntries(List<LeftoverCatalogEntry> entries) {
    final ids = <String>{};
    final dataPaths = <String>{};
    for (final entry in entries) {
      if (!RegExp(r'^[a-z0-9][a-z0-9_.-]*$').hasMatch(entry.id)) {
        throw FormatException('卸载残留清单 id 无效：${entry.id}');
      }
      if (entry.id.startsWith(leftoverRuleIdPrefix)) {
        throw FormatException('卸载残留清单 id 不能包含规则前缀：${entry.id}');
      }
      if (!ids.add(entry.id)) {
        throw FormatException('卸载残留清单 id 重复：${entry.id}');
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
      if (entry.installDisplayNamePrefixes.isEmpty) {
        throw FormatException('${entry.id} 缺少安装显示名前缀');
      }
      for (final prefix in entry.installDisplayNamePrefixes) {
        _requireText(prefix, '${entry.id}.installDisplayNamePrefixes');
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
      throw FormatException('卸载残留清单字段为空：$field');
    }
  }

  static void _validateDataPath(String pattern, LeftoverCatalogEntry entry) {
    _validateCommonPath(pattern, entry);
    if (pattern.contains('*') || pattern.contains('?')) {
      throw FormatException('${entry.id} 的数据目录不能使用通配符：$pattern');
    }
    final root = _dataRootOf(pattern);
    if (root == null) {
      throw FormatException('${entry.id} 的数据目录必须位于用户 AppData：$pattern');
    }
    final segments = _segmentsAfterRoot(pattern, root);
    if (segments.isEmpty) {
      throw FormatException('${entry.id} 的数据目录不能是根目录：$pattern');
    }
    final normalized = '$root\\${segments.join(r'\')}'.toLowerCase();
    for (final shared in _sharedDataRoots) {
      final sharedKey = shared.toLowerCase();
      if (normalized == sharedKey || normalized.startsWith('$sharedKey\\')) {
        throw FormatException('${entry.id} 的数据目录指向共享目录：$pattern');
      }
    }
  }

  static void _validateInstallMarker(
    String pattern,
    LeftoverCatalogEntry entry,
  ) {
    _validateCommonPath(pattern, entry);
    if (!pattern.startsWith('%')) {
      throw FormatException('${entry.id} 的安装标记必须以环境变量开头：$pattern');
    }
    final closing = pattern.indexOf('%', 1);
    if (closing <= 1) {
      throw FormatException('${entry.id} 的安装标记缺少完整的环境变量：$pattern');
    }
    final segments = pattern
        .substring(closing + 1)
        .split(RegExp(r'[\\/]'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      throw FormatException('${entry.id} 的安装标记不能是环境变量根目录：$pattern');
    }
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final hasWildcard = segment.contains('*') || segment.contains('?');
      if (hasWildcard && index != segments.length - 1) {
        throw FormatException('${entry.id} 的安装标记通配符只能位于最后一段：$pattern');
      }
    }
  }

  /// A data directory must never be the install directory, a parent of it, or
  /// a child of it. Otherwise cleaning the leftovers would also delete the
  /// application itself. Zoom installs into `%APPDATA%\Zoom\bin`, so this is a
  /// real hazard rather than a theoretical one.
  static void _validateNoInstallOverlap(LeftoverCatalogEntry entry) {
    for (final marker in entry.installMarkerPatterns) {
      final markerDir = _markerDirectory(marker);
      if (markerDir == null) continue;
      for (final dataPath in entry.dataPathPatterns) {
        final data = _normalizeForCompare(dataPath);
        final install = _normalizeForCompare(markerDir);
        if (_isSameOrAncestor(data, install) ||
            _isSameOrAncestor(install, data)) {
          throw FormatException('${entry.id} 的数据目录与安装目录重叠：$dataPath 与 $marker');
        }
      }
    }
  }

  /// Returns the directory that contains the marker's last segment.
  static String? _markerDirectory(String pattern) {
    final separator = pattern.lastIndexOf(RegExp(r'[\\/]'));
    if (separator <= 0) return null;
    return pattern.substring(0, separator);
  }

  static String _normalizeForCompare(String pattern) =>
      pattern.replaceAll('/', r'\').toLowerCase();

  static bool _isSameOrAncestor(String ancestor, String candidate) =>
      candidate == ancestor || candidate.startsWith('$ancestor\\');

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
    final upper = pattern.toUpperCase();
    for (final root in _allowedDataRoots) {
      final upperRoot = root.toUpperCase();
      if (upper == upperRoot || upper.startsWith('$upperRoot\\')) {
        return pattern.substring(0, root.length);
      }
    }
    return null;
  }

  static List<String> _segmentsAfterRoot(String pattern, String root) => pattern
      .substring(root.length)
      .split(RegExp(r'[\\/]'))
      .where((segment) => segment.isNotEmpty)
      .toList();
}
