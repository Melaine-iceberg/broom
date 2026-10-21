import '../models/cleaner_rule.dart';

final windowsSafeRules = <CleanerRule>[
  CleanerRule(
    id: 'windows.user_temp',
    title: '用户临时文件',
    titleEn: 'User temporary files',
    category: '系统缓存',
    categoryEn: 'System cache',
    description: '应用安装、解压与自动更新留下的临时文件，只处理超过 24 小时的内容。',
    descriptionEn: 'Temporary files left by installers, extraction, and automatic updates. Only items older than 24 hours are cleaned.',
    pathPatterns: [r'%TEMP%'],
    minAge: Duration(hours: 24),
    excludedPathPatterns: [r'%LOCALAPPDATA%\Temp\wsl-crashes'],
    note: '被占用的文件会自动跳过，不影响正在运行的程序。WSL 崩溃转储由独立规则按 7 天保留期处理，不会被本规则提前清理。',
    noteEn: 'Files in use are skipped automatically, so running programs are unaffected. WSL crash dumps have their own 7-day retention rule and are not claimed by this rule.',
    audit: RuleAudit(
      reviewNotes:
          '仅扫描 %TEMP% 下的普通文件，并要求修改时间超过 24 小时；不进入文档、桌面、下载或应用安装目录。'
          'WSL 崩溃转储目录由独立规则处理，先从本规则中排除。',
      reviewNotesEn:
          'Scans only regular files under %TEMP% that have not changed for '
          '24 hours. Documents, Desktop, Downloads, and application install '
          'directories are out of scope. The WSL crash dump folder is claimed '
          'by a separate rule and excluded here.',
      reverseEvidence: '临时目录本身、24 小时内的文件、符号链接与被排除路径均不处理；路径守卫不会把范围扩大到相邻目录。',
      reverseEvidenceEn:
          'The temp directory itself, files younger than 24 hours, links, and '
          'excluded paths are left untouched. The path guard cannot widen the '
          'scope to adjacent directories.',
      samples: [
        RuleAuditSample(
          pattern: r'%TEMP%',
          path: r'%TEMP%\broom-audit-old.tmp',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%TEMP%',
          path: r'%TEMP%\broom-audit-recent.tmp',
          inScope: false,
          age: Duration(hours: 1),
          reason: '24 小时内的文件必须保留',
        ),
        RuleAuditSample(
          pattern: r'%TEMP%',
          path: r'%USERPROFILE%\Documents\broom-audit-keep.txt',
          inScope: false,
          reason: '用户文档不在临时目录根下',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'windows.crash_dumps',
    title: '崩溃转储',
    titleEn: 'Crash dumps',
    category: '系统缓存',
    categoryEn: 'System cache',
    description: '程序崩溃时生成的 .dmp 转储文件，常规使用中不再需要。',
    descriptionEn: 'Dump files generated when programs crash. They are not needed for normal use.',
    pathPatterns: [r'%LOCALAPPDATA%\CrashDumps'],
    extensions: {'dmp'},
    audit: RuleAudit(
      reviewNotes:
          '仅扫描 %LOCALAPPDATA%\\CrashDumps 内扩展名为 .dmp 的文件；'
          '同目录的配置、日志与用户资料不在规则范围内。',
      reviewNotesEn:
          'Scans only .dmp files under %LOCALAPPDATA%\\CrashDumps. '
          'Configuration, logs, and user data in the same directory are out '
          'of scope.',
      reverseEvidence:
          '同目录的 .json/.log 文件与相邻的 CrashDumpsExtra 目录不会匹配；规则根目录本身永不删除。',
      reverseEvidenceEn:
          'Non-.dmp files in the directory and the adjacent CrashDumpsExtra '
          'directory do not match. The rule root itself is never deleted.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\CrashDumps',
          path: r'%LOCALAPPDATA%\CrashDumps\broom-audit.dmp',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\CrashDumps',
          path: r'%LOCALAPPDATA%\CrashDumps\broom-audit.json',
          inScope: false,
          reason: '扩展名过滤必须排除非转储文件',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\CrashDumps',
          path: r'%LOCALAPPDATA%\CrashDumpsExtra\broom-audit.dmp',
          inScope: false,
          reason: '相邻目录不能被前缀匹配误收',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'windows.wer_reports',
    title: 'Windows 错误报告',
    titleEn: 'Windows Error Reporting',
    category: '系统缓存',
    categoryEn: 'System cache',
    description: '系统与应用错误报告的历史归档，删除后不会影响系统正常运行。',
    descriptionEn: 'Archived system and application error reports. Removing them does not affect normal operation.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive',
      r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue',
    ],
    audit: RuleAudit(
      reviewNotes:
          '仅扫描 WER 的 ReportArchive 与 ReportQueue 两个历史报告目录；'
          '不包含 WER 配置、ReportHistory 或用户文档。',
      reviewNotesEn:
          'Scans only the WER ReportArchive and ReportQueue history folders. '
          'WER configuration, ReportHistory, and user documents are out of '
          'scope.',
      reverseEvidence:
          'WER 下的同级目录（如 ReportHistory、Temp）不会被任意通配符或前缀匹配误收，两个规则根各自独立。',
      reverseEvidenceEn:
          'Sibling directories under WER such as ReportHistory and Temp do not '
          'match either root, and the two declared roots remain independent.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive',
          path: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive\broom-audit-1\Report.wer',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue',
          path: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue\broom-audit-2\Report.wer',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive',
          path: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportHistory\broom-audit-3\Report.wer',
          inScope: false,
          reason: 'ReportHistory 不是声明的规则根',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue',
          path: r'%LOCALAPPDATA%\Microsoft\Windows\WER\Temp\broom-audit-4\Report.wer',
          inScope: false,
          reason: 'WER Temp 不是声明的规则根',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'browser.chrome',
    title: 'Google Chrome 缓存',
    titleEn: 'Google Chrome cache',
    category: '浏览器缓存',
    categoryEn: 'Browser cache',
    description: '网页缓存、代码缓存与 GPU 缓存，不会影响书签、密码或登录状态。',
    descriptionEn: 'Web, code, and GPU caches. Bookmarks, passwords, and sign-in state are untouched.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache',
      r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
      r'%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache',
      r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Service Worker\CacheStorage',
      r'%LOCALAPPDATA%\Google\Chrome\User Data\ShaderCache\GPUCache',
    ],
    note: 'Chrome 运行时部分文件会处于占用状态，将自动跳过。',
    noteEn: 'Some files are in use while Chrome runs and will be skipped.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖 Chrome User Data 下明确声明的缓存子目录（网页、代码、GPU 与 '
          'Service Worker 缓存）；书签、密码、Cookie、历史与扩展数据不在范围内。',
      reviewNotesEn:
          'Covers only the explicitly declared cache folders under Chrome '
          'User Data: web, code, GPU, and Service Worker caches. Bookmarks, '
          'passwords, cookies, history, and extension data are out of scope.',
      reverseEvidence: '通配符只匹配一个 profile 层级，History、Login Data、Bookmarks 等配置文件不匹配任何缓存目录；Service Worker 目录下只扫描 CacheStorage。',
      reverseEvidenceEn:
          'The wildcard matches exactly one profile segment. History, Login '
          'Data, Bookmarks, and similar files do not match any cache folder, '
          'and only CacheStorage is scanned below Service Worker.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache\Cache_Data\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\CacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 CacheExtra 目录必须保留',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\History',
          inScope: false,
          reason: '浏览历史不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Code Cache\js\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Code Cache Extra\broom-audit',
          inScope: false,
          reason: 'Code Cache 只匹配完整目录名',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Login Data',
          inScope: false,
          reason: '登录数据不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\GPUCache\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\GPUCacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 GPUCacheExtra 目录必须保留',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Bookmarks',
          inScope: false,
          reason: '书签数据不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Service Worker\CacheStorage',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Service Worker\CacheStorage\broom-audit\data',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Google\Chrome\User Data\*\Service Worker\CacheStorage',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\Default\Service Worker\CacheStorageExtra\broom-audit',
          inScope: false,
          reason: 'Service Worker 下只扫描 CacheStorage',
        ),
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\Google\Chrome\User Data\ShaderCache\GPUCache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\ShaderCache\GPUCache\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\Google\Chrome\User Data\ShaderCache\GPUCache',
          path: r'%LOCALAPPDATA%\Google\Chrome\User Data\ShaderCache\GPUCacheExtra\broom-audit',
          inScope: false,
          reason: 'ShaderCache 下的相邻目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'browser.edge',
    title: 'Microsoft Edge 缓存',
    titleEn: 'Microsoft Edge cache',
    category: '浏览器缓存',
    categoryEn: 'Browser cache',
    description: '网页缓存、代码缓存与 GPU 缓存，不会影响收藏、密码或登录状态。',
    descriptionEn: 'Web, code, and GPU caches. Favorites, passwords, and sign-in state are untouched.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache',
      r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
      r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache',
      r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Service Worker\CacheStorage',
      r'%LOCALAPPDATA%\Microsoft\Edge\User Data\ShaderCache\GPUCache',
    ],
    note: 'Edge 运行时部分文件会处于占用状态，将自动跳过。',
    noteEn: 'Some files are in use while Edge runs and will be skipped.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖 Edge User Data 下明确声明的缓存子目录（网页、代码、GPU 与 '
          'Service Worker 缓存）；收藏、密码、Cookie、历史与扩展数据不在范围内。',
      reviewNotesEn:
          'Covers only the explicitly declared cache folders under Edge '
          'User Data: web, code, GPU, and Service Worker caches. Favorites, '
          'passwords, cookies, history, and extension data are out of scope.',
      reverseEvidence: '通配符只匹配一个 profile 层级，History、Login Data、Bookmarks 等配置文件不匹配任何缓存目录；Service Worker 目录下只扫描 CacheStorage。',
      reverseEvidenceEn:
          'The wildcard matches exactly one profile segment. History, Login '
          'Data, Bookmarks, and similar files do not match any cache folder, '
          'and only CacheStorage is scanned below Service Worker.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache\Cache_Data\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\CacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 CacheExtra 目录必须保留',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\History',
          inScope: false,
          reason: '浏览历史不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Code Cache\js\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Code Cache Extra\broom-audit',
          inScope: false,
          reason: 'Code Cache 只匹配完整目录名',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Login Data',
          inScope: false,
          reason: '登录数据不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\GPUCache\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\GPUCacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 GPUCacheExtra 目录必须保留',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Bookmarks',
          inScope: false,
          reason: '收藏数据不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Service Worker\CacheStorage',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Service Worker\CacheStorage\broom-audit\data',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Service Worker\CacheStorage',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Service Worker\CacheStorageExtra\broom-audit',
          inScope: false,
          reason: 'Service Worker 下只扫描 CacheStorage',
        ),
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\Microsoft\Edge\User Data\ShaderCache\GPUCache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\ShaderCache\GPUCache\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\Microsoft\Edge\User Data\ShaderCache\GPUCache',
          path: r'%LOCALAPPDATA%\Microsoft\Edge\User Data\ShaderCache\GPUCacheExtra\broom-audit',
          inScope: false,
          reason: 'ShaderCache 下的相邻目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'browser.brave',
    title: 'Brave 缓存',
    titleEn: 'Brave cache',
    category: '浏览器缓存',
    categoryEn: 'Browser cache',
    description: '网页缓存、代码缓存与 GPU 缓存，不会影响书签、密码或登录状态。',
    descriptionEn: 'Web, code, and GPU caches. Bookmarks, passwords, and sign-in state are untouched.',
    pathPatterns: [
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache',
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Code Cache',
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\GPUCache',
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Service Worker\CacheStorage',
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\ShaderCache\GPUCache',
    ],
    note: 'Brave 运行时部分文件会处于占用状态，将自动跳过。',
    noteEn: 'Some files are in use while Brave runs and will be skipped.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖 Brave User Data 下明确声明的缓存子目录（网页、代码、GPU 与 '
          'Service Worker 缓存）；书签、密码、Cookie、历史与扩展数据不在范围内。',
      reviewNotesEn:
          'Covers only the explicitly declared cache folders under Brave '
          'User Data: web, code, GPU, and Service Worker caches. Bookmarks, '
          'passwords, cookies, history, and extension data are out of scope.',
      reverseEvidence: '通配符只匹配一个 profile 层级，History、Login Data、Bookmarks 等配置文件不匹配任何缓存目录；Service Worker 目录下只扫描 CacheStorage。',
      reverseEvidenceEn:
          'The wildcard matches exactly one profile segment. History, Login '
          'Data, Bookmarks, and similar files do not match any cache folder, '
          'and only CacheStorage is scanned below Service Worker.',
      samples: [
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache\Cache_Data\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\CacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 CacheExtra 目录必须保留',
        ),
        RuleAuditSample(
          pattern:
              r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Cache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\History',
          inScope: false,
          reason: '浏览历史不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Code Cache\js\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Code Cache Extra\broom-audit',
          inScope: false,
          reason: 'Code Cache 只匹配完整目录名',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Code Cache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Login Data',
          inScope: false,
          reason: '登录数据不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\GPUCache\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\GPUCacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 GPUCacheExtra 目录必须保留',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\GPUCache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Bookmarks',
          inScope: false,
          reason: '书签数据不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Service Worker\CacheStorage',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Service Worker\CacheStorage\broom-audit\data',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\Service Worker\CacheStorage',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Service Worker\CacheStorageExtra\broom-audit',
          inScope: false,
          reason: 'Service Worker 下只扫描 CacheStorage',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\ShaderCache\GPUCache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\ShaderCache\GPUCache\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\ShaderCache\GPUCache',
          path: r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\ShaderCache\GPUCacheExtra\broom-audit',
          inScope: false,
          reason: 'ShaderCache 下的相邻目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'browser.firefox',
    title: 'Firefox 缓存',
    titleEn: 'Firefox cache',
    category: '浏览器缓存',
    categoryEn: 'Browser cache',
    description: 'Firefox 的网页缓存与启动缓存，不会影响书签、密码或登录状态。',
    descriptionEn: 'Firefox web and startup caches. Bookmarks, passwords, and sign-in state are untouched.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2',
      r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\startupCache',
    ],
    note: 'Firefox 运行时部分文件会处于占用状态，将自动跳过。',
    noteEn: 'Some files are in use while Firefox runs and will be skipped.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖 Firefox profile 下的 cache2 与 startupCache；书签、密码、历史、'
          'prefs 与扩展数据不在范围内。',
      reviewNotesEn:
          'Covers only cache2 and startupCache below a Firefox profile. '
          'Bookmarks, passwords, history, prefs, and extension data are out of '
          'scope.',
      reverseEvidence: 'profile 根目录下的 places.sqlite、logins.json 等文件不匹配缓存子目录；cache3 等相似名称不会被前缀匹配。',
      reverseEvidenceEn:
          'Files such as places.sqlite and logins.json at the profile root do '
          'not match either cache child. Similar names such as cache3 are not '
          'accepted by prefix matching.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2',
          path: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\broom-audit.default-release\cache2\entries\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2',
          path: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\broom-audit.default-release\places.sqlite',
          inScope: false,
          reason: '书签与历史数据库位于 profile 根目录',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2',
          path: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\broom-audit.default-release\cache3\entries\broom-audit',
          inScope: false,
          reason: 'cache3 不能被 cache2 前缀匹配',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\startupCache',
          path: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\broom-audit.default-release\startupCache\startupCache.8.little',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\startupCache',
          path: r'%LOCALAPPDATA%\Mozilla\Firefox\Profiles\broom-audit.default-release\startupCacheExtra\startupCache.8.little',
          inScope: false,
          reason: '相邻的 startupCacheExtra 目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.npm',
    title: 'npm 缓存',
    titleEn: 'npm cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'npm 下载包的本地缓存，清理后下次安装依赖时需要重新下载。',
    descriptionEn: 'Local cache of downloaded npm packages. Dependencies will be downloaded again next time.',
    pathPatterns: [r'%LOCALAPPDATA%\npm-cache\_cacache'],
    audit: RuleAudit(
      reviewNotes: '仅覆盖 npm 的 _cacache 内容寻址缓存；全局安装包、配置、日志与可执行文件不在范围内。',
      reviewNotesEn:
          'Covers only npm\'s _cacache content-addressed cache. Global '
          'packages, configuration, logs, and executables are out of scope.',
      reverseEvidence:
          '同级的 _logs、node_modules 与 npm 目录不在规则根下；路径守卫拒绝根目录本身与相邻目录。',
      reverseEvidenceEn:
          'Sibling _logs and node_modules directories and the npm directory '
          'are outside the rule root. The path guard rejects the root itself '
          'and adjacent directories.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\npm-cache\_cacache',
          path: r'%LOCALAPPDATA%\npm-cache\_cacache\content-v2\sha512\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\npm-cache\_cacache',
          path: r'%LOCALAPPDATA%\npm-cache\_logs\broom-audit.log',
          inScope: false,
          reason: 'npm 日志目录不属于缓存',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\npm-cache\_cacache',
          path: r'%LOCALAPPDATA%\npm\node_modules\broom-audit\index.js',
          inScope: false,
          reason: '全局安装包不属于下载缓存',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.pip',
    title: 'pip 缓存',
    titleEn: 'pip cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Python 包的下载与构建缓存，清理后下次安装时会重新下载。',
    descriptionEn: 'Download and build cache for Python packages. Packages will be downloaded again next time.',
    pathPatterns: [r'%LOCALAPPDATA%\pip\Cache'],
    audit: RuleAudit(
      reviewNotes: '仅覆盖 pip 的 Cache 目录；Python 安装、虚拟环境、项目与 pip 配置文件不在范围内。',
      reviewNotesEn:
          'Covers only the pip Cache directory. Python installations, virtual '
          'environments, projects, and pip configuration are out of scope.',
      reverseEvidence: 'pip.ini 与 CacheExtra 等相邻路径不匹配规则根；扫描只处理根内的普通文件。',
      reverseEvidenceEn:
          'pip.ini and adjacent paths such as CacheExtra do not match the rule '
          'root. Scanning handles only regular files below the root.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\pip\Cache',
          path: r'%LOCALAPPDATA%\pip\Cache\http\broom-audit',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\pip\Cache',
          path: r'%LOCALAPPDATA%\pip\pip.ini',
          inScope: false,
          reason: 'pip 配置位于规则根之外',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\pip\Cache',
          path: r'%LOCALAPPDATA%\pip\CacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 CacheExtra 目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.pub',
    title: 'Pub 缓存',
    titleEn: 'Pub cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Dart/Flutter 依赖包的本地缓存，清理后下次获取依赖时需要重新下载。',
    descriptionEn: 'Local cache of Dart/Flutter packages. Dependencies will be downloaded again next time.',
    pathPatterns: [r'%LOCALAPPDATA%\Pub\Cache'],
    audit: RuleAudit(
      reviewNotes: '仅覆盖 Pub 的 Cache 包缓存；项目依赖、Pub 配置与全局激活工具不在范围内。',
      reviewNotesEn:
          'Covers only the Pub Cache package store. Project dependencies, Pub '
          'configuration, and globally activated tools are out of scope.',
      reverseEvidence: 'Pub\\bin、CacheExtra 等相邻目录不在规则根下；根目录本身不会被删除。',
      reverseEvidenceEn:
          'Pub\\bin, CacheExtra, and other sibling directories are outside the '
          'rule root. The root directory itself is never deleted.',
      samples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Pub\Cache',
          path: r'%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\broom-audit-1.0.0\lib\a.dart',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Pub\Cache',
          path: r'%LOCALAPPDATA%\Pub\bin\broom-audit.dart',
          inScope: false,
          reason: '全局激活工具不在包缓存内',
        ),
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Pub\Cache',
          path: r'%LOCALAPPDATA%\Pub\CacheExtra\broom-audit',
          inScope: false,
          reason: '相邻的 CacheExtra 目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.gradle',
    title: 'Gradle 缓存',
    titleEn: 'Gradle cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Gradle 构建依赖与下载缓存，清理后首次构建会明显变慢。',
    descriptionEn: 'Gradle build dependencies and download cache. The first build afterwards will be slower.',
    pathPatterns: [r'%USERPROFILE%\.gradle\caches'],
    note: '建议关闭 Android Studio 与正在运行的 Gradle 构建后再清理。',
    noteEn:
        'Close Android Studio and any running Gradle builds before cleaning.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖用户目录下的 .gradle\\caches 构建依赖缓存；wrapper、守护进程、'
          '项目文件与 Android SDK 不在范围内。',
      reviewNotesEn:
          'Covers only the .gradle\\caches build dependency cache under the '
          'user profile. Wrapper, daemon, project files, and the Android SDK '
          'are out of scope.',
      reverseEvidence: '.gradle\\wrapper 与 .gradle\\daemon 等相邻目录不匹配；清理前应关闭 Android Studio 与正在运行的构建。',
      reverseEvidenceEn:
          'Sibling directories such as .gradle\\wrapper and .gradle\\daemon do '
          'not match. Android Studio and running builds should be closed before '
          'cleaning.',
      samples: [
        RuleAuditSample(
          pattern: r'%USERPROFILE%\.gradle\caches',
          path: r'%USERPROFILE%\.gradle\caches\modules-2\files-2.1\broom-audit\artifact.jar',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%USERPROFILE%\.gradle\caches',
          path: r'%USERPROFILE%\.gradle\wrapper\dists\broom-audit.zip',
          inScope: false,
          reason: 'Gradle wrapper 不属于依赖缓存',
        ),
        RuleAuditSample(
          pattern: r'%USERPROFILE%\.gradle\caches',
          path: r'%USERPROFILE%\.gradle\cachesExtra\broom-audit\artifact.jar',
          inScope: false,
          reason: '相邻的 cachesExtra 目录必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'windows.thumbnail_icon_cache',
    title: '缩略图与图标缓存',
    titleEn: 'Thumbnail and icon cache',
    category: '缩略图与图标缓存',
    categoryEn: 'Thumbnail & icon cache',
    description: '资源管理器用于显示缩略图与图标的重建缓存，删除后会按需重新生成。',
    descriptionEn: 'Rebuildable Explorer caches for thumbnails and icons. They are regenerated on demand.',
    pathPatterns: [r'%LOCALAPPDATA%\Microsoft\Windows\Explorer'],
    extensions: {'db'},
    note: '资源管理器运行时缓存文件通常被占用；关闭或重新启动资源管理器后再扫描更完整。Broom 不会强制解锁。',
    noteEn: 'Explorer normally keeps these files open. Restart Explorer before scanning for a more complete cleanup; Broom never force-unlocks files.',
    audit: _directoryAudit(
      reviewNotes:
          '仅扫描 Explorer 目录下扩展名为 .db 的缩略图、图标缓存与对应索引文件；'
          '不会触碰同一目录中的配置、日志或用户文档。',
      reviewNotesEn:
          'Scans only .db thumbnail, icon, and index caches under the Explorer '
          'folder. Configuration, logs, and user documents in that folder are '
          'out of scope.',
      reverseEvidence:
          '非 .db 文件与相邻的 ExplorerExtra 目录均不匹配；资源管理器的锁定文件会在清理时跳过，不会被强制解锁。',
      reverseEvidenceEn:
          'Non-.db files and the adjacent ExplorerExtra folder do not match. '
          'Files locked by Explorer are skipped and never force-unlocked.',
      patterns: [r'%LOCALAPPDATA%\Microsoft\Windows\Explorer'],
      positiveRelativePath: 'broom-audit.db',
      extraSamples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Microsoft\Windows\Explorer',
          path: r'%LOCALAPPDATA%\Microsoft\Windows\Explorer\broom-audit-settings.json',
          inScope: false,
          reason: '扩展名过滤必须保留非 .db 文件',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'gpu.shader_caches',
    title: 'DirectX 与显卡着色器缓存',
    titleEn: 'DirectX and GPU shader caches',
    category: 'DirectX / GPU 缓存',
    categoryEn: 'DirectX / GPU cache',
    description: 'DirectX 与显卡驱动生成的着色器编译缓存，删除后游戏或图形程序首次启动会稍慢。',
    descriptionEn: 'Shader compilation caches created by DirectX and graphics drivers. Games or graphics apps may load slowly once after removal.',
    pathPatterns: [
      r'%LOCALAPPDATA%\D3DSCache',
      r'%LOCALAPPDATA%\NVIDIA\DXCache',
      r'%LOCALAPPDATA%\NVIDIA\GLCache',
      r'%LOCALAPPDATA%\NVIDIA\OptixCache',
      r'%LOCALAPPDATA%\NVIDIA Corporation\NV_Cache',
      r'%LOCALAPPDATA%\AMD\DxCache',
      r'%LOCALAPPDATA%\AMD\DxcCache',
      r'%LOCALAPPDATA%\AMD\GLCache',
      r'%LOCALAPPDATA%\Intel\ShaderCache',
    ],
    note: '显卡驱动会在需要时重新编译着色器；不会删除驱动、游戏或图形设置。',
    noteEn: 'Graphics drivers recompile shaders as needed. Drivers, games, and graphics settings are not removed.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 DirectX 与 NVIDIA / AMD / Intel 明确声明的着色器缓存目录；'
          '驱动安装目录、游戏文件与显卡控制面板设置不在范围内。',
      reviewNotesEn:
          'Covers only the explicitly declared DirectX and NVIDIA / AMD / Intel '
          'shader cache folders. Driver installations, games, and graphics '
          'control panel settings are out of scope.',
      reverseEvidence:
          '每个规则根都按完整目录名匹配，相邻的 DXCacheExtra 等目录不会命中；'
          '驱动配置与游戏存档位于其他位置。',
      reverseEvidenceEn:
          'Each root matches a complete directory name, so adjacent folders '
          'such as DXCacheExtra do not match. Driver configuration and game '
          'saves live elsewhere.',
      patterns: [
        r'%LOCALAPPDATA%\D3DSCache',
        r'%LOCALAPPDATA%\NVIDIA\DXCache',
        r'%LOCALAPPDATA%\NVIDIA\GLCache',
        r'%LOCALAPPDATA%\NVIDIA\OptixCache',
        r'%LOCALAPPDATA%\NVIDIA Corporation\NV_Cache',
        r'%LOCALAPPDATA%\AMD\DxCache',
        r'%LOCALAPPDATA%\AMD\DxcCache',
        r'%LOCALAPPDATA%\AMD\GLCache',
        r'%LOCALAPPDATA%\Intel\ShaderCache',
      ],
    ),
  ),
  CleanerRule(
    id: 'logs.app_diagnostics',
    title: '应用日志与诊断',
    titleEn: 'Application logs and diagnostics',
    category: '日志与诊断',
    categoryEn: 'Logs & diagnostics',
    description: '常用应用生成的运行日志与诊断记录，只处理超过 7 天的内容。',
    descriptionEn: 'Runtime logs and diagnostics from common applications. Only items older than 7 days are cleaned.',
    pathPatterns: [
      r'%APPDATA%\Code\logs',
      r'%APPDATA%\Microsoft\Teams\logs',
      r'%APPDATA%\Slack\logs',
      r'%APPDATA%\discord\logs',
    ],
    minAge: Duration(days: 7),
    note: 'Windows 事件日志、CBS 日志与系统目录日志受系统保护，不在扫描范围内；应用日志可用于排查问题，清理前请确认不再需要。',
    noteEn: 'Windows Event Logs, CBS logs, and system-folder logs are protected and out of scope. Application logs can help with troubleshooting, so keep them if you still need them.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 VS Code、Teams、Slack 与 Discord 明确声明的 logs 目录，并要求'
          '修改时间超过 7 天；Windows 事件日志与系统日志不在范围内。',
      reviewNotesEn:
          'Covers only the explicitly declared logs folders for VS Code, Teams, '
          'Slack, and Discord, and only files older than 7 days. Windows Event '
          'Logs and system logs are out of scope.',
      reverseEvidence:
          '7 天内的日志必须保留；同应用的缓存、配置与用户数据不在 logs 目录；'
          '相邻的 logsExtra 目录不会被前缀匹配。',
      reverseEvidenceEn:
          'Logs younger than 7 days are kept. Application caches, '
          'configuration, and user data are outside the logs folder, and the '
          'adjacent logsExtra folder does not match by prefix.',
      patterns: [
        r'%APPDATA%\Code\logs',
        r'%APPDATA%\Microsoft\Teams\logs',
        r'%APPDATA%\Slack\logs',
        r'%APPDATA%\discord\logs',
      ],
      positiveRelativePath: r'broom-audit\main.log',
      extraSamples: [
        RuleAuditSample(
          pattern: r'%APPDATA%\Code\logs',
          path: r'%APPDATA%\Code\logs\broom-audit\recent.log',
          inScope: false,
          age: Duration(days: 1),
          reason: '7 天内的诊断日志必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'browser.extension_scripts',
    title: '浏览器扩展脚本缓存',
    titleEn: 'Browser extension script cache',
    category: '浏览器扩展缓存',
    categoryEn: 'Browser extension cache',
    description: 'Chromium 浏览器为网页与扩展预编译的脚本缓存，删除后会重新生成。',
    descriptionEn: 'Precompiled script caches for pages and extensions in Chromium browsers. They are regenerated automatically.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Google\Chrome\User Data\*\ScriptCache',
      r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\ScriptCache',
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\ScriptCache',
    ],
    note: '不会删除已安装扩展、扩展设置或本地扩展数据；仅清除可重新生成的脚本缓存。',
    noteEn: 'Installed extensions, extension settings, and local extension data are untouched. Only rebuildable script caches are removed.',
    audit: _directoryAudit(
      reviewNotes:
          '仅匹配 Chrome、Edge 与 Brave 单个 profile 下的 ScriptCache；已安装'
          '扩展、Extension State、Local Extension Settings 与存储数据不在范围内。',
      reviewNotesEn:
          'Matches only ScriptCache below one profile in Chrome, Edge, and Brave. '
          'Installed extensions, Extension State, Local Extension Settings, and '
          'storage data are out of scope.',
      reverseEvidence:
          '通配符只匹配一个 profile 层级，Extensions、Extension State 与相邻的 '
          'ScriptCacheExtra 均不匹配任何规则根。',
      reverseEvidenceEn:
          'The wildcard matches exactly one profile segment. Extensions, '
          'Extension State, and the adjacent ScriptCacheExtra folder do not '
          'match any rule root.',
      patterns: [
        r'%LOCALAPPDATA%\Google\Chrome\User Data\*\ScriptCache',
        r'%LOCALAPPDATA%\Microsoft\Edge\User Data\*\ScriptCache',
        r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\*\ScriptCache',
      ],
    ),
  ),
  CleanerRule(
    id: 'app.teams',
    title: 'Microsoft Teams 缓存',
    titleEn: 'Microsoft Teams cache',
    category: '应用缓存',
    categoryEn: 'App cache',
    description: 'Teams 的网页、代码、GPU 与 Service Worker 缓存，不会影响聊天记录、文件或登录状态。',
    descriptionEn: 'Teams web, code, GPU, and Service Worker caches. Chats, files, and sign-in state are untouched.',
    pathPatterns: [
      r'%APPDATA%\Microsoft\Teams\Cache',
      r'%APPDATA%\Microsoft\Teams\Code Cache',
      r'%APPDATA%\Microsoft\Teams\GPUCache',
      r'%APPDATA%\Microsoft\Teams\Service Worker\CacheStorage',
      r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache',
      r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Code Cache',
      r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\GPUCache',
      r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Service Worker\CacheStorage',
    ],
    note: '请关闭 Teams 后清理；被占用的缓存会自动跳过。聊天记录与已下载文件不在规则范围内。',
    noteEn: 'Close Teams before cleaning; caches in use are skipped. Chats and downloaded files are out of scope.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 Teams 经典版与新版的网页、代码、GPU 与 Service Worker 缓存子目录；'
          '聊天数据库、文件、登录信息、设置与扩展数据不在范围内。',
      reviewNotesEn:
          'Covers only web, code, GPU, and Service Worker cache folders for '
          'classic and new Teams. Chat databases, files, sign-in data, settings, '
          'and extension data are out of scope.',
      reverseEvidence:
          '通配或固定目录都指向明确的缓存子目录；同级的 Local Storage、IndexedDB、'
          'CacheExtra 等目录不会被任何规则根命中。',
      reverseEvidenceEn:
          'Every root points to an explicit cache folder. Sibling Local Storage, '
          'IndexedDB, CacheExtra, and similar folders do not match any rule root.',
      patterns: [
        r'%APPDATA%\Microsoft\Teams\Cache',
        r'%APPDATA%\Microsoft\Teams\Code Cache',
        r'%APPDATA%\Microsoft\Teams\GPUCache',
        r'%APPDATA%\Microsoft\Teams\Service Worker\CacheStorage',
        r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache',
        r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Code Cache',
        r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\GPUCache',
        r'%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Service Worker\CacheStorage',
      ],
    ),
  ),
  CleanerRule(
    id: 'app.slack',
    title: 'Slack 缓存',
    titleEn: 'Slack cache',
    category: '应用缓存',
    categoryEn: 'App cache',
    description: 'Slack 的网页、代码、GPU 与 Service Worker 缓存，不会影响消息、文件或登录状态。',
    descriptionEn: 'Slack web, code, GPU, and Service Worker caches. Messages, files, and sign-in state are untouched.',
    pathPatterns: [
      r'%APPDATA%\Slack\Cache',
      r'%APPDATA%\Slack\Code Cache',
      r'%APPDATA%\Slack\GPUCache',
      r'%APPDATA%\Slack\Service Worker\CacheStorage',
    ],
    note: '请关闭 Slack 后清理；被占用的缓存会自动跳过。工作区数据与本地文件不在规则范围内。',
    noteEn: 'Close Slack before cleaning; caches in use are skipped. Workspace data and local files are out of scope.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 Slack 的网页、代码、GPU 与 Service Worker 缓存；消息数据库、工作区设置、文件与登录信息不在范围内。',
      reviewNotesEn:
          'Covers only Slack web, code, GPU, and Service Worker caches. Message '
          'databases, workspace settings, files, and sign-in data are out of '
          'scope.',
      reverseEvidence:
          '规则根只指向缓存子目录；同一应用目录下的 Local Storage、IndexedDB、'
          'logs 与相邻的 CacheExtra 目录不会被命中。',
      reverseEvidenceEn:
          'Rule roots point only to cache folders. Local Storage, IndexedDB, '
          'logs, and adjacent CacheExtra folders in the app directory do not '
          'match.',
      patterns: [
        r'%APPDATA%\Slack\Cache',
        r'%APPDATA%\Slack\Code Cache',
        r'%APPDATA%\Slack\GPUCache',
        r'%APPDATA%\Slack\Service Worker\CacheStorage',
      ],
    ),
  ),
  CleanerRule(
    id: 'app.discord',
    title: 'Discord 缓存',
    titleEn: 'Discord cache',
    category: '应用缓存',
    categoryEn: 'App cache',
    description: 'Discord 的网页、代码、GPU 与 Service Worker 缓存，不会影响消息、设置或登录状态。',
    descriptionEn: 'Discord web, code, GPU, and Service Worker caches. Messages, settings, and sign-in state are untouched.',
    pathPatterns: [
      r'%APPDATA%\discord\Cache',
      r'%APPDATA%\discord\Code Cache',
      r'%APPDATA%\discord\GPUCache',
      r'%APPDATA%\discord\Service Worker\CacheStorage',
    ],
    note: '请关闭 Discord 后清理；被占用的缓存会自动跳过。消息数据库与设置不在规则范围内。',
    noteEn: 'Close Discord before cleaning; caches in use are skipped. Message databases and settings are out of scope.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 Discord 的网页、代码、GPU 与 Service Worker 缓存；消息数据库、设置、扩展与登录信息不在范围内。',
      reviewNotesEn:
          'Covers only Discord web, code, GPU, and Service Worker caches. Message '
          'databases, settings, extensions, and sign-in data are out of scope.',
      reverseEvidence:
          '规则根只指向明确的缓存子目录；Local Storage、IndexedDB、logs 与相邻的 '
          'GPUCacheExtra 目录不会被命中。',
      reverseEvidenceEn:
          'Rule roots point only to explicit cache folders. Local Storage, '
          'IndexedDB, logs, and adjacent GPUCacheExtra folders do not match.',
      patterns: [
        r'%APPDATA%\discord\Cache',
        r'%APPDATA%\discord\Code Cache',
        r'%APPDATA%\discord\GPUCache',
        r'%APPDATA%\discord\Service Worker\CacheStorage',
      ],
    ),
  ),
  CleanerRule(
    id: 'app.spotify',
    title: 'Spotify 缓存',
    titleEn: 'Spotify cache',
    category: '应用缓存',
    categoryEn: 'App cache',
    description: 'Spotify 的浏览器与音频缓存，清理后离线歌曲需要重新下载，播放列表与账号不受影响。',
    descriptionEn: 'Spotify browser and audio caches. Offline songs will be downloaded again; playlists and your account are unaffected.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Spotify\Storage',
      r'%LOCALAPPDATA%\Spotify\Browser\Cache',
    ],
    note: '已下载的离线音乐会需要重新下载；账号、播放列表与设置不会被修改。',
    noteEn: 'Downloaded offline music will need to download again. Your account, playlists, and settings are not modified.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 Spotify 的 Storage 音频缓存与 Browser\\Cache；账号、播放列表、'
          '离线下载状态和其他应用数据不在范围内。',
      reviewNotesEn:
          'Covers only Spotify Storage audio cache and Browser\\Cache. Your '
          'account, playlists, offline download state, and other app data are '
          'out of scope.',
      reverseEvidence:
          'Spotify 目录中的 Browser\\Data、配置与相邻的 StorageExtra 不会匹配；'
          '清理后只是需要重新下载离线音乐。',
      reverseEvidenceEn:
          'Browser\\Data, configuration, and the adjacent StorageExtra folder '
          'under Spotify do not match. Cleaning only requires offline music to '
          'be downloaded again.',
      patterns: [
        r'%LOCALAPPDATA%\Spotify\Storage',
        r'%LOCALAPPDATA%\Spotify\Browser\Cache',
      ],
    ),
  ),
  CleanerRule(
    id: 'app.vscode',
    title: 'Visual Studio Code 缓存',
    titleEn: 'Visual Studio Code cache',
    category: '应用缓存',
    categoryEn: 'App cache',
    description: 'VS Code 的网页、代码、GPU、Service Worker、编译数据与扩展安装包缓存。',
    descriptionEn: 'VS Code web, code, GPU, Service Worker, compiled data, and extension package caches.',
    pathPatterns: [
      r'%APPDATA%\Code\Cache',
      r'%APPDATA%\Code\Code Cache',
      r'%APPDATA%\Code\GPUCache',
      r'%APPDATA%\Code\Service Worker\CacheStorage',
      r'%APPDATA%\Code\CachedData',
      r'%APPDATA%\Code\CachedExtensionVSIXs',
    ],
    note: '不会删除扩展代码、用户设置、工作区或未保存的内容；请关闭 VS Code 后清理。',
    noteEn: 'Extension code, user settings, workspaces, and unsaved content are untouched. Close VS Code before cleaning.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 VS Code 的 Cache、Code Cache、GPUCache、Service Worker、'
          'CachedData 与 CachedExtensionVSIXs；扩展目录、用户设置、'
          'workspaceStorage 与日志不在范围内。',
      reviewNotesEn:
          'Covers only VS Code Cache, Code Cache, GPUCache, Service Worker, '
          'CachedData, and CachedExtensionVSIXs. Extensions, user settings, '
          'workspaceStorage, and logs are out of scope.',
      reverseEvidence:
          'User、Backups、extensions 与 workspaceStorage 等相邻目录不会被命中；'
          'logs 由独立的日志规则按 7 天保留期处理。',
      reverseEvidenceEn:
          'Sibling folders such as User, Backups, extensions, and '
          'workspaceStorage do not match. logs is handled separately by the '
          'log rule with a 7-day retention.',
      patterns: [
        r'%APPDATA%\Code\Cache',
        r'%APPDATA%\Code\Code Cache',
        r'%APPDATA%\Code\GPUCache',
        r'%APPDATA%\Code\Service Worker\CacheStorage',
        r'%APPDATA%\Code\CachedData',
        r'%APPDATA%\Code\CachedExtensionVSIXs',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.yarn',
    title: 'Yarn 缓存',
    titleEn: 'Yarn cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Yarn Classic 与 Yarn Berry 的包下载缓存，清理后下次安装依赖需要重新下载。',
    descriptionEn: 'Package download caches for Yarn Classic and Yarn Berry. Dependencies will be downloaded again next time.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Yarn\Cache',
      r'%LOCALAPPDATA%\Yarn\Berry\cache',
    ],
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 Yarn 全局下载缓存；项目中的 .yarn、node_modules、Yarn 配置与可执行文件不在范围内。',
      reviewNotesEn:
          'Covers only the global Yarn download caches. Project .yarn folders, '
          'node_modules, Yarn configuration, and executables are out of scope.',
      reverseEvidence: 'Yarn\\Berry 下只扫描 cache，同级的 plugins、releases 与相邻的 CacheExtra 目录不会被命中。',
      reverseEvidenceEn:
          'Only cache below Yarn\\Berry is scanned. Sibling plugins and releases '
          'folders and the adjacent CacheExtra folder do not match.',
      patterns: [
        r'%LOCALAPPDATA%\Yarn\Cache',
        r'%LOCALAPPDATA%\Yarn\Berry\cache',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.pnpm',
    title: 'pnpm 缓存',
    titleEn: 'pnpm cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'pnpm 的全局内容寻址存储与下载缓存，清理后下次安装依赖需要重新下载。',
    descriptionEn: 'pnpm global content-addressed store and download cache. Dependencies will be downloaded again next time.',
    pathPatterns: [
      r'%LOCALAPPDATA%\pnpm\store',
      r'%LOCALAPPDATA%\pnpm\cache',
      r'%LOCALAPPDATA%\pnpm-cache',
    ],
    audit: _directoryAudit(
      reviewNotes: '仅覆盖 pnpm 的 store、cache 与旧版 pnpm-cache；项目 node_modules、pnpm 配置与可执行文件不在范围内。',
      reviewNotesEn:
          'Covers only pnpm store, cache, and the legacy pnpm-cache folder. '
          'Project node_modules, pnpm configuration, and executables are out of '
          'scope.',
      reverseEvidence: '项目目录与 pnpm 配置不在任何规则根下；pnpm\\storeExtra 等相邻目录不会被前缀匹配。',
      reverseEvidenceEn:
          'Project folders and pnpm configuration are outside every rule root. '
          'Adjacent folders such as pnpm\\storeExtra do not match by prefix.',
      patterns: [
        r'%LOCALAPPDATA%\pnpm\store',
        r'%LOCALAPPDATA%\pnpm\cache',
        r'%LOCALAPPDATA%\pnpm-cache',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.bun',
    title: 'Bun 缓存',
    titleEn: 'Bun cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Bun 安装依赖时使用的包缓存，清理后下次安装需要重新下载。',
    descriptionEn: 'Package cache used when Bun installs dependencies. Packages will be downloaded again next time.',
    pathPatterns: [r'%USERPROFILE%\.bun\install\cache'],
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖用户目录下 .bun\\install\\cache；Bun 可执行文件、全局工具与项目 node_modules 不在范围内。',
      reviewNotesEn:
          'Covers only .bun\\install\\cache under the user profile. The Bun '
          'executable, global tools, and project node_modules are out of scope.',
      reverseEvidence: '.bun\\bin、install 下的其他文件与相邻的 cacheExtra 目录均不匹配规则根。',
      reverseEvidenceEn:
          '.bun\\bin, other files under install, and the adjacent cacheExtra '
          'folder do not match the rule root.',
      patterns: [r'%USERPROFILE%\.bun\install\cache'],
    ),
  ),
  CleanerRule(
    id: 'dev.composer',
    title: 'Composer 缓存',
    titleEn: 'Composer cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'PHP Composer 的包下载与解压缓存，清理后下次安装依赖需要重新下载。',
    descriptionEn: 'PHP Composer download and extraction caches. Dependencies will be downloaded again next time.',
    pathPatterns: [
      r'%LOCALAPPDATA%\Composer\cache',
      r'%LOCALAPPDATA%\Composer\files',
    ],
    note: '项目中的 vendor 目录不受影响；只会重新下载全局 Composer 缓存。',
    noteEn: 'Project vendor folders are unaffected. Only the global Composer cache is downloaded again.',
    audit: _directoryAudit(
      reviewNotes: '仅覆盖 Composer 的 cache 与 files 下载缓存；全局 Composer 配置、可执行文件与项目 vendor 目录不在范围内。',
      reviewNotesEn:
          'Covers only Composer cache and files download caches. Global '
          'Composer configuration, executables, and project vendor folders are '
          'out of scope.',
      reverseEvidence:
          'Composer\\config.json、Composer\\bin 与相邻的 cacheExtra 不会匹配；'
          '项目 vendor 位于项目目录中。',
      reverseEvidenceEn:
          'Composer\\config.json, Composer\\bin, and adjacent cacheExtra '
          'folders do not match. Project vendor folders live inside projects.',
      patterns: [
        r'%LOCALAPPDATA%\Composer\cache',
        r'%LOCALAPPDATA%\Composer\files',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.docker',
    title: 'Docker Desktop 日志',
    titleEn: 'Docker Desktop logs',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description:
        'Docker Desktop 在 Windows 侧生成的诊断日志；镜像、容器和构建缓存位于 WSL 虚拟磁盘中，不由 Broom 删除。',
    descriptionEn: 'Docker Desktop diagnostic logs on the Windows side. Images, containers, and build caches live in the WSL virtual disk and are not removed by Broom.',
    pathPatterns: [r'%LOCALAPPDATA%\Docker\log'],
    minAge: Duration(days: 7),
    note: '请使用 Docker Desktop 或 docker system prune / builder prune 清理镜像、容器与构建缓存；Broom 不直接修改 WSL 虚拟磁盘。',
    noteEn: 'Use Docker Desktop or docker system prune / builder prune for images, containers, and build caches. Broom never modifies the WSL virtual disk directly.',
    audit: _directoryAudit(
      reviewNotes:
          '仅清理 Docker Desktop 的 Windows 侧 log 目录中超过 7 天的日志；'
          'WSL 虚拟磁盘、镜像、容器、卷与构建缓存不在范围内。',
      reviewNotesEn:
          'Cleans only logs older than 7 days under Docker Desktop log on the '
          'Windows side. The WSL virtual disk, images, containers, volumes, and '
          'build caches are out of scope.',
      reverseEvidence:
          'Docker\\wsl 与其他同级目录不会被命中；Docker 数据必须通过 Docker 自身'
          '的清理命令管理，Broom 不删除 ext4.vhdx。',
      reverseEvidenceEn:
          'Docker\\wsl and other sibling folders do not match. Docker data must '
          "be managed with Docker's own cleanup commands; Broom never deletes "
          'ext4.vhdx.',
      patterns: [r'%LOCALAPPDATA%\Docker\log'],
      positiveRelativePath: r'broom-audit\vm.log',
      extraSamples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Docker\log',
          path: r'%LOCALAPPDATA%\Docker\log\broom-audit\recent.log',
          inScope: false,
          age: Duration(days: 2),
          reason: '7 天内的 Docker 诊断日志必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.wsl',
    title: 'WSL 崩溃转储',
    titleEn: 'WSL crash dumps',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'WSL 在 Windows 临时目录生成的崩溃转储；Linux 发行版数据与虚拟磁盘不会被触碰。',
    descriptionEn: 'Crash dumps generated by WSL in the Windows temporary folder. Linux distributions and virtual disks are untouched.',
    pathPatterns: [r'%LOCALAPPDATA%\Temp\wsl-crashes'],
    minAge: Duration(days: 7),
    note: '发行版文件系统、ext4.vhdx 与 Linux 内缓存不在 Broom 范围内；如需回收空间，请在 WSL 中清理并使用官方虚拟磁盘压缩方式。',
    noteEn: 'Distribution filesystems, ext4.vhdx, and in-Linux caches are outside Broom. Clean inside WSL and use the official virtual disk compaction method to reclaim space.',
    audit: _directoryAudit(
      reviewNotes:
          '仅清理 WSL 崩溃转储目录中超过 7 天的 .dmp / 转储文件；发行版'
          ' ext4.vhdx、用户文件和 Linux 内部缓存不在范围内。',
      reviewNotesEn:
          'Cleans only .dmp / crash dump files older than 7 days in the WSL '
          'crash dump folder. Distribution ext4.vhdx files, user files, and '
          'caches inside Linux are out of scope.',
      reverseEvidence:
          'WSL 发行版虚拟磁盘位于 Packages 目录，不在本规则根下；相邻的 '
          'wsl-crashes-extra 目录不会被前缀匹配。',
      reverseEvidenceEn:
          'WSL distribution virtual disks live under Packages and are outside '
          'this rule root. The adjacent wsl-crashes-extra folder does not match '
          'by prefix.',
      patterns: [r'%LOCALAPPDATA%\Temp\wsl-crashes'],
      positiveRelativePath: r'broom-audit\crash.dmp',
      extraSamples: [
        RuleAuditSample(
          pattern: r'%LOCALAPPDATA%\Temp\wsl-crashes',
          path: r'%LOCALAPPDATA%\Temp\wsl-crashes\broom-audit\recent.dmp',
          inScope: false,
          age: Duration(days: 1),
          reason: '7 天内的 WSL 崩溃转储必须保留',
        ),
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.electron',
    title: 'Electron 下载缓存',
    titleEn: 'Electron download cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description:
        'Electron 与 electron-builder 在打包时下载的运行时二进制与构建工具缓存；'
        '清理后下次打包会重新下载。',
    descriptionEn:
        'Electron runtime binaries and build tooling downloaded while '
        'packaging with Electron or electron-builder. They are downloaded again '
        'on the next build.',
    pathPatterns: [
      r'%LOCALAPPDATA%\electron\Cache',
      r'%LOCALAPPDATA%\electron-builder\Cache',
    ],
    note: '项目中的 node_modules 与打包产物不受影响。',
    noteEn: 'Project node_modules and packaged output are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 electron 与 electron-builder 下的 Cache 目录；'
          '同级的 dist、项目 node_modules 与打包产物不在范围内。',
      reviewNotesEn:
          'Covers only the Cache folders under electron and electron-builder. '
          'Sibling dist folders, project node_modules, and packaged output are '
          'out of scope.',
      reverseEvidence: 'electron\\dist、electron\\CacheExtra 与 electron-builder\\CacheExtra 不会被命中。',
      reverseEvidenceEn:
          'electron\\dist, electron\\CacheExtra, and electron-builder\\CacheExtra '
          'do not match.',
      patterns: [
        r'%LOCALAPPDATA%\electron\Cache',
        r'%LOCALAPPDATA%\electron-builder\Cache',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.scoop',
    title: 'Scoop 安装包缓存',
    titleEn: 'Scoop package cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Scoop 下载的安装包缓存；清理后重新安装应用时需要重新下载。',
    descriptionEn:
        'Installer packages downloaded by Scoop. Reinstalling an application '
        'downloads the package again.',
    pathPatterns: [r'%USERPROFILE%\scoop\cache'],
    note: '已安装的应用、persist 数据与 scoop\\apps 不受影响。',
    noteEn:
        'Installed applications, persist data, and scoop\\apps are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 scoop\\cache 中的安装包；scoop\\apps、scoop\\persist 与 '
          'scoop\\buckets 不在范围内。',
      reviewNotesEn:
          'Covers only installer packages in scoop\\cache. scoop\\apps, '
          'scoop\\persist, and scoop\\buckets are out of scope.',
      reverseEvidence:
          'scoop\\apps 中的已安装程序、scoop\\persist 中的用户数据与相邻的 '
          'cacheExtra 目录都不会被命中。',
      reverseEvidenceEn:
          'Programs in scoop\\apps, user data in scoop\\persist, and the '
          'adjacent cacheExtra folder do not match.',
      patterns: [r'%USERPROFILE%\scoop\cache'],
    ),
  ),
  CleanerRule(
    id: 'dev.uv',
    title: 'uv 缓存',
    titleEn: 'uv cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'uv 的包下载与解压缓存；清理后下次同步依赖需要重新下载。',
    descriptionEn:
        'Package download and extraction cache used by uv. Dependencies are '
        'downloaded again on the next sync.',
    pathPatterns: [r'%LOCALAPPDATA%\uv\cache'],
    note: 'uv 管理的 Python 解释器（uv\\python）与工具环境（uv\\tools）不受影响。',
    noteEn:
        'Python interpreters managed by uv (uv\\python) and tool environments '
        '(uv\\tools) are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 uv\\cache；uv\\python 中由 uv 管理的解释器、uv\\tools 中的'
          '工具环境与项目虚拟环境不在范围内。',
      reviewNotesEn:
          'Covers only uv\\cache. Interpreters managed under uv\\python, tool '
          'environments under uv\\tools, and project virtual environments are '
          'out of scope.',
      reverseEvidence:
          'uv\\python 与 uv\\tools 是安装而非缓存，必须保留；相邻的 '
          'cacheExtra 目录不会被命中。',
      reverseEvidenceEn:
          'uv\\python and uv\\tools are installations rather than caches and '
          'must be kept. The adjacent cacheExtra folder does not match.',
      patterns: [r'%LOCALAPPDATA%\uv\cache'],
    ),
  ),
  CleanerRule(
    id: 'dev.poetry',
    title: 'Poetry 缓存',
    titleEn: 'Poetry cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Poetry 的包下载与元数据缓存；清理后下次安装依赖需要重新下载。',
    descriptionEn:
        'Poetry package download and metadata caches. Dependencies are '
        'downloaded again on the next install.',
    pathPatterns: [r'%LOCALAPPDATA%\pypoetry\Cache'],
    note: 'Poetry 创建的虚拟环境（pypoetry\\virtualenvs）不受影响。',
    noteEn: 'Virtual environments created by Poetry (pypoetry\\virtualenvs) are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 pypoetry\\Cache；pypoetry\\virtualenvs 中的虚拟环境与 '
          'Poetry 配置不在范围内。',
      reviewNotesEn:
          'Covers only pypoetry\\Cache. Virtual environments under '
          'pypoetry\\virtualenvs and Poetry configuration are out of scope.',
      reverseEvidence:
          'pypoetry\\virtualenvs 保存的是可运行环境而非缓存，必须保留；'
          '相邻的 CacheExtra 目录不会被命中。',
      reverseEvidenceEn:
          'pypoetry\\virtualenvs holds runnable environments rather than '
          'caches and must be kept. The adjacent CacheExtra folder does not '
          'match.',
      patterns: [r'%LOCALAPPDATA%\pypoetry\Cache'],
    ),
  ),
  CleanerRule(
    id: 'dev.node_gyp',
    title: 'node-gyp 头文件缓存',
    titleEn: 'node-gyp header cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'node-gyp 下载的 Node 头文件与库缓存；清理后编译原生模块时会重新下载。',
    descriptionEn:
        'Node headers and libraries downloaded by node-gyp. Building native '
        'modules downloads them again.',
    pathPatterns: [r'%LOCALAPPDATA%\node-gyp\Cache'],
    note: '已构建的原生模块与项目中的 build 目录不受影响。',
    noteEn: 'Built native modules and project build folders are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 node-gyp\\Cache 中的头文件与库归档；项目 build 目录与已编译的 '
          '.node 文件不在范围内。',
      reviewNotesEn:
          'Covers only header and library archives in node-gyp\\Cache. Project '
          'build folders and compiled .node files are out of scope.',
      reverseEvidence: 'node-gyp\\CacheExtra 与项目中的 build 目录不会被命中。',
      reverseEvidenceEn:
          'node-gyp\\CacheExtra and project build folders do not match.',
      patterns: [r'%LOCALAPPDATA%\node-gyp\Cache'],
    ),
  ),
  CleanerRule(
    id: 'dev.vcpkg',
    title: 'vcpkg 缓存',
    titleEn: 'vcpkg cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'vcpkg 的二进制缓存与源码下载缓存；清理后下次安装依赖需要重新编译或下载。',
    descriptionEn:
        'vcpkg binary and source download caches. Dependencies are rebuilt or '
        'downloaded again on the next install.',
    pathPatterns: [
      r'%LOCALAPPDATA%\vcpkg\archives',
      r'%LOCALAPPDATA%\vcpkg\downloads',
    ],
    note: 'vcpkg\\installed 中已构建的库、triplet 与项目清单不受影响。',
    noteEn:
        'Built libraries under vcpkg\\installed, triplets, and project manifests '
        'are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 vcpkg 的 archives 与 downloads 缓存；vcpkg\\installed、'
          'vcpkg\\buildtrees 与 vcpkg\\ports 不在范围内。',
      reviewNotesEn:
          'Covers only the archives and downloads caches. vcpkg\\installed, '
          'vcpkg\\buildtrees, and vcpkg\\ports are out of scope.',
      reverseEvidence:
          'vcpkg\\installed 中的已构建库与 vcpkg\\ports 中的端口定义必须保留；'
          '相邻的 archivesExtra 目录不会被命中。',
      reverseEvidenceEn:
          'Built libraries in vcpkg\\installed and port definitions in '
          'vcpkg\\ports must be kept. The adjacent archivesExtra folder does '
          'not match.',
      patterns: [
        r'%LOCALAPPDATA%\vcpkg\archives',
        r'%LOCALAPPDATA%\vcpkg\downloads',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.deno',
    title: 'Deno 缓存',
    titleEn: 'Deno cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Deno 的远程依赖与编译缓存（DENO_DIR）；清理后下次运行会重新下载与编译。',
    descriptionEn:
        'Deno remote dependency and compilation caches (DENO_DIR). They are '
        'downloaded and compiled again on the next run.',
    pathPatterns: [r'%LOCALAPPDATA%\deno\cache', r'%LOCALAPPDATA%\deno\gen'],
    note: 'DENO_DIR 位于其他位置时不在 Broom 范围内；Deno 可执行文件不受影响。',
    noteEn:
        'A DENO_DIR pointing elsewhere is outside Broom. The Deno executable is '
        'unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖默认 DENO_DIR（%LOCALAPPDATA%\\deno）下的 cache 与 gen；'
          'registries 元数据与自定义 DENO_DIR 不在范围内。',
      reviewNotesEn:
          'Covers only cache and gen under the default DENO_DIR '
          '(%LOCALAPPDATA%\\deno). Registry metadata and a custom DENO_DIR are '
          'out of scope.',
      reverseEvidence: 'deno\\registries 与相邻的 cacheExtra 目录不会被命中。',
      reverseEvidenceEn:
          'deno\\registries and the adjacent cacheExtra folder do not match.',
      patterns: [r'%LOCALAPPDATA%\deno\cache', r'%LOCALAPPDATA%\deno\gen'],
    ),
  ),
  CleanerRule(
    id: 'dev.corepack',
    title: 'Corepack 缓存',
    titleEn: 'Corepack cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Corepack 下载的 pnpm / Yarn 分发包缓存；清理后下次使用会重新下载。',
    descriptionEn:
        'pnpm and Yarn distributions downloaded by Corepack. They are '
        'downloaded again on the next use.',
    pathPatterns: [r'%LOCALAPPDATA%\node\corepack'],
    note: 'Node 本身、项目 lockfile 与已安装的依赖不受影响。',
    noteEn: 'Node itself, project lockfiles, and installed dependencies are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 node\\corepack 中 Corepack 下载的分发包；Node 安装目录、'
          '全局 npm 目录与项目依赖不在范围内。',
      reviewNotesEn:
          'Covers only distributions downloaded by Corepack under '
          'node\\corepack. The Node installation, global npm folder, and '
          'project dependencies are out of scope.',
      reverseEvidence: 'node\\corepackExtra 与其他 node 子目录不会被命中。',
      reverseEvidenceEn:
          'node\\corepackExtra and other node subfolders do not match.',
      patterns: [r'%LOCALAPPDATA%\node\corepack'],
    ),
  ),
];

final windowsReviewRules = <CleanerRule>[
  CleanerRule(
    id: 'dev.cargo',
    title: 'Cargo 注册表缓存',
    titleEn: 'Cargo registry cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'Rust Cargo 下载的 crate 归档与解压源码；清理后下次构建需要重新下载依赖。',
    descriptionEn: 'Crate archives and extracted sources downloaded by Cargo. Dependencies will be downloaded again on the next build.',
    risk: CleanRisk.review,
    pathPatterns: [
      r'%USERPROFILE%\.cargo\registry\cache',
      r'%USERPROFILE%\.cargo\registry\src',
    ],
    note: 'Review：依赖体积可能很大，重新下载耗时；项目 target、Cargo 配置与工具链不受影响。',
    noteEn: 'Review: dependencies can be large and take time to download again. Project targets, Cargo configuration, and toolchains are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 .cargo\\registry 下的 cache 与 src；.cargo\\bin、config.toml、'
          'git 仓库与项目文件不在范围内。',
      reviewNotesEn:
          'Covers only cache and src below .cargo\\registry. .cargo\\bin, '
          'config.toml, git checkouts, and project files are out of scope.',
      reverseEvidence:
          '.cargo\\git、.cargo\\registry\\index 与相邻的 cacheExtra 目录不会命中；'
          '项目 target 与工具链不受影响。',
      reverseEvidenceEn:
          '.cargo\\git, .cargo\\registry\\index, and adjacent cacheExtra folders '
          'do not match. Project targets and toolchains are unaffected.',
      patterns: [
        r'%USERPROFILE%\.cargo\registry\cache',
        r'%USERPROFILE%\.cargo\registry\src',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.go',
    title: 'Go 模块与构建缓存',
    titleEn: 'Go module and build cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    risk: CleanRisk.review,
    description: '默认 GOPATH 下的 Go 模块缓存与用户构建缓存；清理后首次构建需要重新下载与编译。',
    descriptionEn: 'Go module cache under the default GOPATH and the user build cache. The first build afterwards will download and compile again.',
    pathPatterns: [r'%USERPROFILE%\go\pkg\mod', r'%LOCALAPPDATA%\go-build'],
    note: 'Review：模块缓存可能很大，首次构建会明显变慢；项目源码与 GOPATH 中的 bin 不受影响。',
    noteEn: 'Review: the module cache can be large and the first build will be slower. Project sources and bin folders under GOPATH are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖默认位置的 USERPROFILE\\go\\pkg\\mod 与 LOCALAPPDATA\\go-build；'
          '项目源码、GOPATH\\bin、工具链与自定义 GOPATH 不在范围内。',
      reviewNotesEn:
          'Covers only the default USERPROFILE\\go\\pkg\\mod and '
          'LOCALAPPDATA\\go-build. Project sources, GOPATH\\bin, toolchains, and '
          'custom GOPATH locations are out of scope.',
      reverseEvidence: 'go\\bin 与相邻的 go-build-cache 不会命中；自定义 GOPATH 不会被猜测或扫描。',
      reverseEvidenceEn:
          'go\\bin and the adjacent go-build-cache folder do not match. Custom '
          'GOPATH locations are never guessed or scanned.',
      patterns: [r'%USERPROFILE%\go\pkg\mod', r'%LOCALAPPDATA%\go-build'],
    ),
  ),
  CleanerRule(
    id: 'dev.nuget',
    title: 'NuGet 包与 HTTP 缓存',
    titleEn: 'NuGet packages and HTTP cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'NuGet 全局包目录与 HTTP / 插件缓存；清理后还原项目时需要重新下载包。',
    descriptionEn: 'NuGet global packages plus HTTP and plugin caches. Projects will download packages again when restored.',
    risk: CleanRisk.review,
    pathPatterns: [
      r'%USERPROFILE%\.nuget\packages',
      r'%LOCALAPPDATA%\NuGet\Cache',
      r'%LOCALAPPDATA%\NuGet\v3-cache',
      r'%LOCALAPPDATA%\NuGet\plugins-cache',
    ],
    note: 'Review：全局包目录被多个项目共享，清理后首次还原会重新下载；NuGet 配置与项目文件不受影响。',
    noteEn: 'Review: the global package folder is shared by multiple projects and will be downloaded again on the next restore. NuGet configuration and project files are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 .nuget\\packages 与 NuGet 的 Cache、v3-cache、plugins-cache；'
          'NuGet.Config、项目文件与 Visual Studio 配置不在范围内。',
      reviewNotesEn:
          'Covers only .nuget\\packages and NuGet Cache, v3-cache, and '
          'plugins-cache. NuGet.Config, project files, and Visual Studio '
          'configuration are out of scope.',
      reverseEvidence:
          '.nuget\\NuGet.Config 与其他同级文件不会命中；Visual Studio 缓存和项目目录'
          ' 不在规则根下。',
      reverseEvidenceEn:
          '.nuget\\NuGet.Config and other sibling files do not match. Visual '
          'Studio caches and project folders are outside the rule roots.',
      patterns: [
        r'%USERPROFILE%\.nuget\packages',
        r'%LOCALAPPDATA%\NuGet\Cache',
        r'%LOCALAPPDATA%\NuGet\v3-cache',
        r'%LOCALAPPDATA%\NuGet\plugins-cache',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.maven',
    title: 'Maven 本地仓库',
    titleEn: 'Maven local repository',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: '用户目录下 Maven 下载的依赖与插件；清理后首次构建需要重新下载。',
    descriptionEn: 'Dependencies and plugins downloaded into the user Maven repository. The first build afterwards will download them again.',
    risk: CleanRisk.review,
    pathPatterns: [r'%USERPROFILE%\.m2\repository'],
    note: 'Review：本地仓库可能包含离线构建所需依赖；settings.xml 与 wrapper 不受影响。',
    noteEn: 'Review: the local repository may contain dependencies needed for offline builds. settings.xml and wrappers are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 .m2\\repository；.m2\\settings.xml、wrapper、Maven 安装目录与'
          '项目 pom.xml 不在范围内。',
      reviewNotesEn:
          'Covers only .m2\\repository. .m2\\settings.xml, wrappers, Maven '
          'installations, and project pom.xml files are out of scope.',
      reverseEvidence:
          '.m2\\settings.xml 与相邻的 repositoryExtra 目录不会命中；项目 target 与'
          '本地源码不在规则根下。',
      reverseEvidenceEn:
          '.m2\\settings.xml and the adjacent repositoryExtra folder do not '
          'match. Project targets and local sources are outside the rule root.',
      patterns: [r'%USERPROFILE%\.m2\repository'],
    ),
  ),
  CleanerRule(
    id: 'dev.jetbrains',
    title: 'JetBrains IDE 缓存',
    titleEn: 'JetBrains IDE caches',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'IntelliJ IDEA 等 JetBrains IDE 的索引与本地缓存；清理后首次打开项目需要重新索引。',
    descriptionEn: 'Indexes and local caches for JetBrains IDEs such as IntelliJ IDEA. Projects will be re-indexed the next time they open.',
    risk: CleanRisk.review,
    pathPatterns: [r'%LOCALAPPDATA%\JetBrains\*\caches'],
    note: 'Review：重新索引可能耗时；IDE 设置、插件、项目文件与本地历史不受影响。请关闭 IDE 后清理。',
    noteEn: 'Review: re-indexing can take time. IDE settings, plugins, project files, and local history are unaffected. Close the IDE before cleaning.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 JetBrains 产品版本目录下的 caches；设置、插件、日志、'
          '项目与本地历史目录不在范围内。',
      reviewNotesEn:
          'Covers only caches under each JetBrains product version folder. '
          'Settings, plugins, logs, projects, and local history are out of '
          'scope.',
      reverseEvidence:
          '通配符只匹配一个产品版本层级；同一产品下的 config、plugins、log 与'
          '相邻的 cachesExtra 均不匹配。',
      reverseEvidenceEn:
          'The wildcard matches exactly one product version segment. config, '
          'plugins, log, and adjacent cachesExtra folders under the same '
          'product do not match.',
      patterns: [r'%LOCALAPPDATA%\JetBrains\*\caches'],
    ),
  ),
  CleanerRule(
    id: 'dev.playwright',
    title: 'Playwright 浏览器缓存',
    titleEn: 'Playwright browser cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description:
        'Playwright 下载的浏览器与驱动二进制；清理后需要重新运行 '
        'playwright install 才能继续执行端到端测试。',
    descriptionEn:
        'Browser and driver binaries downloaded by Playwright. End-to-end '
        'tests fail until playwright install runs again.',
    risk: CleanRisk.review,
    pathPatterns: [r'%LOCALAPPDATA%\ms-playwright'],
    note:
        'Review：单个浏览器通常数百 MB，重新下载耗时；项目代码、测试配置、'
        'node_modules 与已安装的系统浏览器不受影响。',
    noteEn:
        'Review: a single browser is often hundreds of MB and slow to '
        're-download. Project code, test configuration, node_modules, and '
        'installed system browsers are unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 ms-playwright 中的浏览器与驱动二进制；项目代码、测试配置、'
          'node_modules 与系统浏览器不在范围内。',
      reviewNotesEn:
          'Covers only browser and driver binaries under ms-playwright. '
          'Project code, test configuration, node_modules, and system browsers '
          'are out of scope.',
      reverseEvidence:
          '系统安装的 Chrome / Edge 位于 Program Files，不在本规则根下；'
          '相邻的 ms-playwrightExtra 目录不会被命中。',
      reverseEvidenceEn:
          'System Chrome and Edge live under Program Files and are outside this '
          'rule root. The adjacent ms-playwrightExtra folder does not match.',
      patterns: [r'%LOCALAPPDATA%\ms-playwright'],
    ),
  ),
  CleanerRule(
    id: 'dev.huggingface',
    title: 'Hugging Face 模型缓存',
    titleEn: 'Hugging Face model cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description:
        'Hugging Face Hub 下载的模型、数据集与 Xet 传输缓存；'
        '清理后再次加载模型需要重新下载，体积可能达到数十 GB。',
    descriptionEn:
        'Models, datasets, and Xet transfer caches downloaded from Hugging '
        'Face Hub. Loading a model again downloads it once more and can reach '
        'tens of GB.',
    risk: CleanRisk.review,
    pathPatterns: [
      r'%USERPROFILE%\.cache\huggingface\hub',
      r'%USERPROFILE%\.cache\huggingface\xet',
    ],
    note:
        'Review：模型与数据集通常很大，重新下载耗时且依赖网络；'
        '登录凭据（.cache\\huggingface\\token）与项目代码不受影响。'
        '自定义 HF_HOME 不在 Broom 范围内。',
    noteEn:
        'Review: models and datasets are usually large, so re-downloading is '
        'slow and network-bound. The sign-in token '
        '(.cache\\huggingface\\token) and project code are unaffected. A custom '
        'HF_HOME is outside Broom.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 .cache\\huggingface 下的 hub 与 xet 缓存；token 登录凭据、'
          'assets 目录与自定义 HF_HOME 不在范围内。',
      reviewNotesEn:
          'Covers only hub and xet under .cache\\huggingface. The token file, '
          'the assets folder, and a custom HF_HOME are out of scope.',
      reverseEvidence:
          '.cache\\huggingface\\token 保存登录凭据，必须保留；assets 与相邻的'
          ' hubExtra、xetExtra 目录不会被命中。',
      reverseEvidenceEn:
          '.cache\\huggingface\\token holds the sign-in credential and must be '
          'kept. assets and the adjacent hubExtra / xetExtra folders do not '
          'match.',
      patterns: [
        r'%USERPROFILE%\.cache\huggingface\hub',
        r'%USERPROFILE%\.cache\huggingface\xet',
      ],
    ),
  ),
  CleanerRule(
    id: 'dev.conda',
    title: 'conda 包缓存',
    titleEn: 'conda package cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description: 'conda 下载与解压的包缓存（pkgs）；清理后安装或更新环境需要重新下载。',
    descriptionEn:
        'Package cache downloaded and extracted by conda (pkgs). Installing or '
        'updating environments downloads packages again.',
    risk: CleanRisk.review,
    pathPatterns: [r'%USERPROFILE%\.conda\pkgs'],
    note:
        'Review：环境通过硬链接引用缓存文件，删除后环境仍可运行；'
        '可用 conda clean --packages 达到同样效果。'
        '.conda\\environments.txt 与环境目录不受影响。',
    noteEn:
        'Review: environments reference cached files through hard links, so '
        'they keep working after cleaning. conda clean --packages achieves the '
        'same result. .conda\\environments.txt and environment folders are '
        'unaffected.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 ~/.conda/pkgs；.conda\\environments.txt 中的环境清单、'
          'envs 目录与 conda 安装目录不在范围内。',
      reviewNotesEn:
          'Covers only ~/.conda/pkgs. The environment list in '
          '.conda\\environments.txt, envs folders, and the conda installation '
          'are out of scope.',
      reverseEvidence:
          '.conda\\environments.txt 记录已创建的环境，必须保留；'
          '相邻的 pkgsExtra 目录不会被命中。',
      reverseEvidenceEn:
          '.conda\\environments.txt records created environments and must be '
          'kept. The adjacent pkgsExtra folder does not match.',
      patterns: [r'%USERPROFILE%\.conda\pkgs'],
    ),
  ),
  CleanerRule(
    id: 'dev.coursier',
    title: 'Coursier 缓存',
    titleEn: 'Coursier cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description:
        'Coursier 下载的 JVM 依赖与元数据缓存；'
        '清理后下次构建或启动 Scala / JVM 工具需要重新下载。',
    descriptionEn:
        'JVM dependency and metadata caches downloaded by Coursier. The next '
        'build or Scala / JVM tool start downloads them again.',
    risk: CleanRisk.review,
    pathPatterns: [r'%LOCALAPPDATA%\Coursier\cache'],
    note: 'Review：依赖体积可能较大；Coursier 配置与凭据（Coursier\\data）不在清理范围。',
    noteEn:
        'Review: dependencies can be large. Coursier configuration and '
        'credentials (Coursier\\data) are out of scope.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 Coursier\\cache；Coursier\\data 中的配置与凭据、'
          '项目构建产物与 sbt / Mill / Gradle 缓存不在范围内。',
      reviewNotesEn:
          'Covers only Coursier\\cache. Configuration and credentials under '
          'Coursier\\data, project build output, and sbt / Mill / Gradle caches '
          'are out of scope.',
      reverseEvidence:
          'Coursier\\data 保存配置与凭据，必须保留；相邻的 cacheExtra 目录'
          '不会被命中。',
      reverseEvidenceEn:
          'Coursier\\data holds configuration and credentials and must be kept. '
          'The adjacent cacheExtra folder does not match.',
      patterns: [r'%LOCALAPPDATA%\Coursier\cache'],
    ),
  ),
  CleanerRule(
    id: 'dev.konan',
    title: 'Kotlin/Native 工具链缓存',
    titleEn: 'Kotlin/Native toolchain cache',
    category: '开发工具缓存',
    categoryEn: 'Developer tool cache',
    description:
        'Kotlin/Native 为编译原生目标下载的 LLVM 等工具链依赖；'
        '清理后编译原生目标需要重新下载。',
    descriptionEn:
        'LLVM and other toolchain dependencies downloaded by Kotlin/Native to '
        'build native targets. The next native build downloads them again.',
    risk: CleanRisk.review,
    pathPatterns: [r'%USERPROFILE%\.konan\dependencies'],
    note:
        'Review：重新下载通常 1 GB 量级；项目代码、Gradle 缓存与已编译产物'
        '不受影响。预编译编译器分发目录不在清理范围。',
    noteEn:
        'Review: re-downloading is usually around 1 GB. Project code, Gradle '
        'caches, and compiled output are unaffected. Prebuilt compiler '
        'distribution folders are out of scope.',
    audit: _directoryAudit(
      reviewNotes:
          '仅覆盖 .konan\\dependencies 中下载的工具链依赖；'
          'kotlin-native-prebuilt-* 分发、.konan 下的其他文件、项目代码与 '
          'Gradle 缓存不在范围内。',
      reviewNotesEn:
          'Covers only the toolchain dependencies under .konan\\dependencies. '
          'kotlin-native-prebuilt-* distributions, other files under .konan, '
          'project code, and Gradle caches are out of scope.',
      reverseEvidence:
          'kotlin-native-prebuilt-* 目录保存编译器分发，不纳入清理；'
          '相邻的 dependenciesExtra 目录不会被命中。',
      reverseEvidenceEn:
          'kotlin-native-prebuilt-* folders hold the compiler distribution and '
          'are not cleaned. The adjacent dependenciesExtra folder does not '
          'match.',
      patterns: [r'%USERPROFILE%\.konan\dependencies'],
    ),
  ),
];

final windowsCleanupRules = <CleanerRule>[
  ...windowsSafeRules,
  ...windowsReviewRules,
];

RuleAudit _directoryAudit({
  required String reviewNotes,
  required String reviewNotesEn,
  required String reverseEvidence,
  required String reverseEvidenceEn,
  required List<String> patterns,
  String positiveRelativePath = r'broom-audit\cache.bin',
  List<RuleAuditSample> extraSamples = const [],
}) {
  final samples = <RuleAuditSample>[];
  for (final pattern in patterns) {
    final concrete = pattern.replaceAll('*', 'broom-audit-profile');
    samples.add(
      RuleAuditSample(
        pattern: pattern,
        path: '$concrete\\$positiveRelativePath',
        inScope: true,
      ),
    );
    samples.add(
      RuleAuditSample(
        pattern: pattern,
        path: '${concrete}Extra\\broom-audit\\cache.bin',
        inScope: false,
        reason: '相邻或前缀相似的目录必须保留',
      ),
    );
  }
  samples.addAll(extraSamples);
  return RuleAudit(
    reviewNotes: reviewNotes,
    reviewNotesEn: reviewNotesEn,
    reverseEvidence: reverseEvidence,
    reverseEvidenceEn: reverseEvidenceEn,
    samples: samples,
  );
}
