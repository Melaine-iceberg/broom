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
    note: '清理期间会临时停止 Windows Update 与 BITS，完成或中止后自动恢复；不会删除更新历史、系统设置或 Windows.old。',
    noteEn: 'Windows Update and BITS are stopped temporarily and restarted afterwards. Update history, system settings, and Windows.old are not removed.',
    audit: RuleAudit(
      reviewNotes:
          '仅覆盖 Windows Update 的 SoftwareDistribution\\Download；清理时临时停止 '
          'wuauserv 与 bits，不删除更新历史、系统设置或 Windows.old。',
      reviewNotesEn:
          'Covers only SoftwareDistribution\\Download for Windows Update. '
          'wuauserv and bits are stopped temporarily; update history, system '
          'settings, and Windows.old are not removed.',
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
];
