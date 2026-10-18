import '../models/cleaner_rule.dart';
import '../models/system_models.dart';

/// System-level caches live under protected Windows directories. Their roots
/// are resolved by native Windows APIs instead of environment variables.
const windowsSystemCacheRules = <SystemCacheRule>[
  SystemCacheRule(
    id: 'windows.update_cache',
    title: 'Windows 更新缓存',
    titleEn: 'Windows Update cache',
    category: 'Windows 更新',
    categoryEn: 'Windows Update',
    description: '已下载的更新安装包与临时下载内容，删除后 Windows 会在需要时重新下载。',
    descriptionEn: 'Downloaded update packages and temporary downloads. Windows will download them again when needed.',
    location: SystemCacheLocation.windowsUpdate,
    displayPath: r'%WINDIR%\SoftwareDistribution\Download',
    services: [
      SystemServiceSpec(
        name: 'wuauserv',
        label: 'Windows Update',
        labelEn: 'Windows Update',
      ),
      SystemServiceSpec(
        name: 'bits',
        label: '后台智能传输服务 (BITS)',
        labelEn: 'Background Intelligent Transfer Service (BITS)',
      ),
    ],
    note: '清理期间会临时停止 Windows Update 与 BITS，完成或中止后自动恢复；不会删除更新历史、系统设置；Windows.old 由独立规则处理。',
    noteEn: 'Windows Update and BITS are stopped temporarily and restarted afterwards. Update history and system settings are not removed; Windows.old is handled by a separate rule.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖 Windows Update 的 SoftwareDistribution\\Download；清理时临时停止 '
          'wuauserv 与 bits，不删除更新历史或系统设置；Windows.old 由独立规则处理。',
      reviewNotesEn:
          'Covers only SoftwareDistribution\\Download for Windows Update. '
          'wuauserv and bits are stopped temporarily; update history and system '
          'settings are not removed. Windows.old is handled by a separate rule.',
      reverseEvidence: 'SoftwareDistribution\\DataStore、WinSxS 与 DownloadExtra 等相邻目录不在规则根下；根目录本身永不删除。',
      reverseEvidenceEn:
          'Sibling locations such as SoftwareDistribution\\DataStore, WinSxS, '
          'and DownloadExtra are outside the rule root. The root itself is '
          'never deleted.',
      samples: [
        RuleAuditSample(
          pattern: r'%WINDIR%\SoftwareDistribution\Download',
          path:
              r'%WINDIR%\SoftwareDistribution\Download\broom-audit\update.cab',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%WINDIR%\SoftwareDistribution\Download',
          path: r'%WINDIR%\SoftwareDistribution\DataStore\DataStore.edb',
          inScope: false,
          reason: '更新数据库不属于下载缓存',
        ),
        RuleAuditSample(
          pattern: r'%WINDIR%\SoftwareDistribution\Download',
          path: r'%WINDIR%\SoftwareDistribution\DownloadExtra\update.cab',
          inScope: false,
          reason: '相邻的 DownloadExtra 目录必须保留',
        ),
      ],
    ),
  ),
  SystemCacheRule(
    id: 'windows.delivery_optimization',
    title: '传递优化缓存',
    titleEn: 'Delivery Optimization cache',
    category: '传递优化',
    categoryEn: 'Delivery Optimization',
    description: 'Windows 用于在设备之间共享更新与商店内容的下载缓存，删除后会重新下载。',
    descriptionEn: 'Download cache used to share updates and Store content between devices. It will be downloaded again.',
    location: SystemCacheLocation.deliveryOptimization,
    displayPath: r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache',
    services: [
      SystemServiceSpec(
        name: 'dosvc',
        label: '传递优化 (DoSvc)',
        labelEn: 'Delivery Optimization (DoSvc)',
      ),
    ],
    note: '清理期间会临时停止传递优化服务，完成或中止后自动恢复。',
    noteEn: 'Delivery Optimization is stopped temporarily and restarted afterwards.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖传递优化的 DeliveryOptimization\\Cache；清理时临时停止 dosvc，'
          '不删除传递优化配置、日志或统计。',
      reviewNotesEn:
          'Covers only the Delivery Optimization Cache. dosvc is stopped '
          'temporarily; Delivery Optimization configuration, logs, and '
          'statistics are not removed.',
      reverseEvidence:
          '同级的 Config、Logs 与 CacheExtra 目录不匹配；清理范围由原生 API 解析的固定路径再次校验。',
      reverseEvidenceEn:
          'Sibling Config, Logs, and CacheExtra directories do not match. The '
          'native API resolves a fixed path that is validated again before '
          'cleaning.',
      samples: [
        RuleAuditSample(
          pattern:
              r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache',
          path: r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache\broom-audit\file.cab',
          inScope: true,
        ),
        RuleAuditSample(
          pattern:
              r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache',
          path: r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Config\settings.json',
          inScope: false,
          reason: '传递优化配置不属于下载缓存',
        ),
        RuleAuditSample(
          pattern:
              r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache',
          path: r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\CacheExtra\file.cab',
          inScope: false,
          reason: '相邻的 CacheExtra 目录必须保留',
        ),
      ],
    ),
  ),
  SystemCacheRule(
    id: 'windows.old',
    title: 'Windows.old 旧版安装',
    titleEn: 'Windows.old previous installation',
    category: 'Windows 升级残留',
    categoryEn: 'Windows upgrade leftovers',
    description: '系统升级后保留的上一版 Windows 与可能包含的旧用户配置文件副本。删除后无法回滚，也不能撤销。',
    descriptionEn: 'The previous Windows installation and any old user-profile copies it retains. Deleting it removes rollback and cannot be undone.',
    location: SystemCacheLocation.windowsOld,
    displayPath: r'%SystemDrive%\Windows.old',
    note: '仅在你已确认系统稳定、已备份所需文件且不再需要回滚时使用。删除可能同时移除 Windows.old 中保留的旧用户配置文件副本、旧程序和系统设置；当前系统的个人文件、还原点与更新历史不受影响。',
    noteEn: 'Use only after confirming the system is stable, backing up any needed files, and accepting that rollback is no longer needed. Deleting may also remove old user-profile copies, programs, and system settings retained in Windows.old. Personal files in the current system, restore points, and update history are unaffected.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖系统盘根目录下的 Windows.old；清理会永久删除其中的普通文件。'
          '该目录可能保留上一版用户配置文件副本、旧程序与系统设置，删除后'
          '无法恢复；当前 Windows、当前个人文件、系统还原点与更新历史不受影响。'
          '该操作需要管理员权限，且没有撤销入口。',
      reviewNotesEn:
          'Covers only Windows.old at the system drive root. Cleaning '
          'permanently deletes regular files inside it. The folder may retain '
          'old user-profile copies, programs, and system settings, and deletion '
          'cannot be undone. The current Windows installation, current personal '
          'files, restore points, and update history are unaffected. The '
          'operation requires administrator rights and has no undo.',
      reverseEvidence:
          r'当前 Windows 目录、相邻的 Windows.old.000 目录、$WINDOWS.~BT 与'
          '磁盘根目录本身都不会被命中；符号链接与 junction 会被跳过。',
      reverseEvidenceEn:
          r'The current Windows folder, an adjacent Windows.old.000 folder, '
          r'$WINDOWS.~BT, and the drive root itself do not match. Symbolic links '
          'and junctions are skipped.',
      samples: [
        RuleAuditSample(
          pattern: r'%SystemDrive%\Windows.old',
          path: r'%SystemDrive%\Windows.old\Windows\System32\broom-audit.dll',
          inScope: true,
        ),
        RuleAuditSample(
          pattern: r'%SystemDrive%\Windows.old',
          path:
              r'%SystemDrive%\Windows.old.000\Windows\System32\broom-audit.dll',
          inScope: false,
          reason: '相邻的旧版本目录不能被前缀匹配',
        ),
        RuleAuditSample(
          pattern: r'%SystemDrive%\Windows.old',
          path: r'%SystemDrive%\Windows\System32\broom-audit.dll',
          inScope: false,
          reason: '当前 Windows 目录不属于规则根',
        ),
      ],
    ),
  ),
];
