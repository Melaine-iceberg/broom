# 长路径与特殊文件系统验证

本文档记录 Broom 在长路径与特殊文件系统上的行为约定、自动化验证方式，以及本机实际执行结果。

## 行为约定

- **长路径**：接近或超过 `MAX_PATH`（260）时，文件操作自动使用 `\\?\`（本地）或 `\\?\UNC\`（UNC）扩展长度前缀；扫描结果、会话记录与界面始终保存不带前缀的规范路径。程序清单已声明 `longPathAware`，原生元数据通道也会自行补上前缀。
- **UNC**：路径守卫按 Windows 大小写不敏感规则比较，`\\server\share\cache` 与 `\\server\share\cache2`、`\\server\share2\cache` 不会互相误判。
- **跨卷 / 网络移动**：同卷优先 `rename`；跨卷或 UNC 与本地卷之间退回“复制 + 删除”。复制成功但删除源失败时，会删除隔离区中的副本并保留源文件，报告失败。
- **只读介质**：清理会先把文件复制进隔离区，再尝试删除源；删除失败（如 `ERROR_WRITE_PROTECT`）时回滚副本、保留源文件，并删除没有可恢复内容的空会话。恢复到只读介质失败时，隔离文件继续保留并报告失败。
- **FAT/exFAT**：不支持 DACL，跨卷清理时会记录“ACL 不可用”并在恢复结果中给出元数据警告；文件内容、时间戳（受 FAT 时间精度限制）与只读属性仍按文件系统能力处理。隐藏 / 系统属性与备用数据流仍依赖文件系统自身的移动 / 复制语义。
- **网络断开**：路径不可用时逐项报告“找不到网络路径 / 网络连接已断开”，不会删除源文件，也不影响其他文件。

## 自动化测试

测试文件：`test/windows_special_filesystem_test.dart`、`test/windows_path_test.dart`、`test/path_guard_test.dart`、`test/filesystem_error_test.dart`。

默认执行（长路径必跑，其余场景缺少环境变量时跳过）：

```bash
flutter test
```

可选场景通过环境变量启用。请在 **PowerShell / cmd** 中设置变量；Git Bash 会对含反斜杠的环境变量做路径转换。

```powershell
# UNC 共享（测试会在共享根下创建并删除唯一的 broom_unc_* 目录）
$env:BROOM_TEST_UNC_ROOT = '\\server\share'
flutter test test/windows_special_filesystem_test.dart --plain-name 'UNC'

# FAT / exFAT 卷（盘符根或卷内目录均可）
$env:BROOM_TEST_FAT_ROOT = 'E:\'
flutter test test/windows_special_filesystem_test.dart --plain-name 'FAT'

# 映射后的网络盘（先由用户或脚本 net use 映射）
$env:BROOM_TEST_NETWORK_ROOT = 'Z:\'
flutter test test/windows_special_filesystem_test.dart --plain-name 'network drive'

# 只读介质上的现有文件（测试会先确认所在目录不可写）
$env:BROOM_TEST_READONLY_FILE = 'D:\fixture\sample.bin'
flutter test test/windows_special_filesystem_test.dart --plain-name 'read-only media'
```

每个场景执行：扫描 → 移入隔离区 → 撤销恢复，并校验内容、路径规范形式与清理后的会话状态。长路径场景使用 3 层 120 字符目录，使文件路径超过 260 字符。FAT/exFAT 场景使用 2 层目录，同时覆盖长路径与无 ACL 文件系统。

只读介质测试的安全措施：

- 先尝试在目标目录创建探针文件；若创建成功，测试直接失败，不会移动任何真实文件；
- 扫描仅统计文件；
- 清理失败后断言源文件仍存在；
- 撤销测试使用一个不存在的目标文件名，并把隔离记录指向只读目录，验证写入失败后隔离副本仍保留。

## 本机执行结果

环境：Windows 10.0.26340，普通用户（非管理员），Flutter 3.47.7。

| 场景 | 介质 / 路径 | 结果 |
| --- | --- | --- |
| 超过 260 字符 | 本地 NTFS / ReFS 临时目录，最长路径超过 400 字符 | 通过（扫描、清理、撤销、分析遍历） |
| UNC | `\\localhost\DevelopmentFiles`，嵌套路径超过 260 字符 | 通过（跨 UNC / 本地卷移动） |
| 网络盘 | 临时映射 `Z:` → `\\localhost\DevelopmentFiles`，验证后已断开 | 通过 |
| 只读失败路径 | 临时目录拒绝写入 ACL（模拟写保护介质） | 通过（清理保留源文件；撤销保留隔离副本） |
| FAT / exFAT | 本机无 FAT / exFAT 卷 | 未执行，测试已提供 |
| 物理只读介质 | 本机无光盘 / 写保护 USB | 未执行，测试已提供 |

说明：

- 只读代理验证的是“无法写入”时的失败与回滚路径，错误码为访问被拒绝；真实写保护介质通常返回 `ERROR_WRITE_PROTECT (19)`，该错误码的提示映射已有单元测试覆盖。
- FAT/exFAT 与物理只读介质需在对应设备上运行上述可选测试。真实 ACL 恢复由原生通道完成，`flutter test` 不加载 Windows 原生插件，因此元数据通道的长路径行为通过代码审查与 Windows Release 构建验证，建议在 UI 中补充一次手工回归。

## 已知边界

- 网络共享离线后，已进入隔离区的文件仍可恢复或永久释放；原路径不可达时逐项失败。
- UNC 服务器的不同别名（`localhost` / `127.0.0.1` / 机器名）被视为不同路径，路径守卫不做网络身份归一化。
- FAT/exFAT 不保存 DACL；恢复结果中的 ACL 不可用警告是预期行为。
- `\\?\` 前缀只由核心文件操作使用，不写入计划、会话记录或界面。
