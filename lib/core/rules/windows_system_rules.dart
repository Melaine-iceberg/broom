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
  ),
];
