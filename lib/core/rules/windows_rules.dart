import '../models/cleaner_rule.dart';

const windowsSafeRules = <CleanerRule>[
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
    note: '被占用的文件会自动跳过，不影响正在运行的程序。',
    noteEn: 'Files in use are skipped automatically, so running programs are unaffected.',
    audit: RuleAudit(
      reviewNotes: '仅扫描 %TEMP% 下的普通文件，并要求修改时间超过 24 小时；不进入文档、桌面、下载或应用安装目录。',
      reviewNotesEn:
          'Scans only regular files under %TEMP% that have not changed for '
          '24 hours. Documents, Desktop, Downloads, and application install '
          'directories are out of scope.',
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
          reason: '超过 24 小时的临时文件应被扫描',
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
];
