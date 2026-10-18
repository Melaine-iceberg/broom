import '../models/system_models.dart';

/// System-level caches live under protected Windows directories. Their roots
/// are resolved by native Windows APIs instead of environment variables.
const windowsSystemCacheRules = <SystemCacheRule>[
  SystemCacheRule(
    id: 'windows.update_cache',
    title: 'Windows 更新缓存',
    category: 'Windows 更新',
    description: '已下载的更新安装包与临时下载内容，删除后 Windows 会在需要时重新下载。',
    location: SystemCacheLocation.windowsUpdate,
    displayPath: r'%WINDIR%\SoftwareDistribution\Download',
    services: [
      SystemServiceSpec(name: 'wuauserv', label: 'Windows Update'),
      SystemServiceSpec(name: 'bits', label: '后台智能传输服务 (BITS)'),
    ],
    note: '清理期间会临时停止 Windows Update 与 BITS，完成或中止后自动恢复；不会删除更新历史、系统设置或 Windows.old。',
  ),
  SystemCacheRule(
    id: 'windows.delivery_optimization',
    title: '传递优化缓存',
    category: '传递优化',
    description: 'Windows 用于在设备之间共享更新与商店内容的下载缓存，删除后会重新下载。',
    location: SystemCacheLocation.deliveryOptimization,
    displayPath: r'%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache',
    services: [SystemServiceSpec(name: 'dosvc', label: '传递优化 (DoSvc)')],
    note: '清理期间会临时停止传递优化服务，完成或中止后自动恢复。',
  ),
];
