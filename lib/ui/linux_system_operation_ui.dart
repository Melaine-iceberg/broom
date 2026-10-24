import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/platform/linux_system_maintenance.dart';
import '../l10n/broom_strings.dart';

/// User-facing metadata for the fixed Linux system operations. Paths and
/// commands are documented here only; they are never sent back to the helper.
String linuxOperationTitle(
  LinuxSystemOperation operation,
  BroomStrings strings,
) {
  return strings.t(switch (operation) {
    LinuxSystemOperation.aptCache => 'APT 包缓存',
    LinuxSystemOperation.dnfPackages => 'DNF 包缓存',
    LinuxSystemOperation.pacmanCache => 'pacman 包缓存',
    LinuxSystemOperation.zypperCache => 'zypper 包缓存',
    LinuxSystemOperation.flatpakUnused => 'Flatpak 系统运行时',
    LinuxSystemOperation.snapRevisions => 'Snap 旧版本修订',
    LinuxSystemOperation.journal7d => 'systemd journal（7 天）',
  });
}

String linuxOperationDescription(
  LinuxSystemOperation operation,
  BroomStrings strings,
) {
  return strings.t(switch (operation) {
    LinuxSystemOperation.aptCache =>
      '清理 /var/cache/apt/archives 中已下载的 .deb 安装包；不会卸载任何已安装软件。',
    LinuxSystemOperation.dnfPackages =>
      '清理 /var/cache/dnf 中已下载的 RPM 包；不会执行 autoremove，也不会卸载软件。',
    LinuxSystemOperation.pacmanCache =>
      '清理 /var/cache/pacman/pkg 中已卸载软件的包文件；已安装版本对应的包会保留。',
    LinuxSystemOperation.zypperCache =>
      '清理 /var/cache/zypp/packages 中已下载的 RPM 包；仓库元数据会保留。',
    LinuxSystemOperation.flatpakUnused =>
      '移除系统安装中不再被任何应用使用的 Flatpak 运行时；使用中的运行时和应用本身不受影响。',
    LinuxSystemOperation.snapRevisions => '移除 Snap 中已禁用的旧修订；当前启用版本与应用数据不受影响。',
    LinuxSystemOperation.journal7d =>
      '删除超过 7 天的归档系统日志；当前 journal 与最近 7 天的日志会保留。',
  });
}

String linuxOperationNote(
  LinuxSystemOperation operation,
  BroomStrings strings,
) {
  return strings.t(switch (operation) {
    LinuxSystemOperation.aptCache ||
    LinuxSystemOperation.dnfPackages ||
    LinuxSystemOperation.pacmanCache ||
    LinuxSystemOperation.zypperCache => '清理后，重新安装或升级需要重新下载这些包。',
    LinuxSystemOperation.flatpakUnused =>
      '未使用的运行时会从系统中删除，之后需要时会重新下载；无法再离线回退到这些运行时。',
    LinuxSystemOperation.snapRevisions => '旧修订删除后无法再回退到该版本；Snap 自身的数据不受影响。',
    LinuxSystemOperation.journal7d =>
      '日志删除后无法恢复，可能影响问题排查；不处理用户 journal 和普通文本日志。',
  });
}

IconData linuxOperationIcon(LinuxSystemOperation operation) {
  return switch (operation) {
    LinuxSystemOperation.aptCache => LucideIcons.package,
    LinuxSystemOperation.dnfPackages => LucideIcons.archive,
    LinuxSystemOperation.pacmanCache => LucideIcons.packageOpen,
    LinuxSystemOperation.zypperCache => LucideIcons.boxes,
    LinuxSystemOperation.flatpakUnused => LucideIcons.container,
    LinuxSystemOperation.snapRevisions => LucideIcons.layers,
    LinuxSystemOperation.journal7d => LucideIcons.scrollText,
  };
}

String linuxOperationStatusLabel(
  LinuxSystemOperationStatus status,
  BroomStrings strings,
) {
  return strings.t(switch (status) {
    LinuxSystemOperationStatus.ok => '完成',
    LinuxSystemOperationStatus.failed => '失败',
    LinuxSystemOperationStatus.busy => '忙碌，未执行',
    LinuxSystemOperationStatus.skipped => '已跳过',
    LinuxSystemOperationStatus.unavailable => '不可用',
  });
}

String linuxUnavailableTitle(
  LinuxSystemUnavailableReason reason,
  BroomStrings strings,
) {
  return strings.t(switch (reason) {
    LinuxSystemUnavailableReason.helperMissing => '未安装系统助手',
    LinuxSystemUnavailableReason.policyMissing => '缺少 Polkit policy',
    LinuxSystemUnavailableReason.pkexecMissing => '缺少 pkexec',
    LinuxSystemUnavailableReason.helperFailed => '系统助手不可用',
  });
}

String linuxUnavailableDescription(
  LinuxSystemUnavailableReason reason,
  BroomStrings strings,
) {
  return strings.t(switch (reason) {
    LinuxSystemUnavailableReason.helperMissing =>
      '系统缓存清理需要由发行版软件包安装 Broom 系统助手。便携版或未安装助手的构建不会显示此入口。',
    LinuxSystemUnavailableReason.policyMissing =>
      '已找到系统助手，但没有安装对应的 Polkit policy。请重新安装 Broom 的系统组件。',
    LinuxSystemUnavailableReason.pkexecMissing =>
      '系统缺少 pkexec，无法发起 Polkit 授权。请安装 polkit 后重试。',
    LinuxSystemUnavailableReason.helperFailed =>
      '系统助手没有返回有效的能力信息。请检查安装状态或查看诊断日志后重试。',
  });
}
