#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "native_channels.h"
#include "trash.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <gtk/gtk.h>

#ifndef BROOM_VERSION
#define BROOM_VERSION "0.0.0"
#endif

// statx arrived in glibc 2.28. Everything else falls back to lstat, which
// reports the same fields except the birth time.
#if defined(__linux__) && defined(__GLIBC__) && \
    (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 28))
#define BROOM_HAVE_STATX 1
#endif
#ifndef STATX_BASIC_STATS
#define STATX_BASIC_STATS 0x000007ffU
#endif
#ifndef STATX_BTIME
#define STATX_BTIME 0x00000800U
#endif
#ifndef AT_STATX_DONT_SYNC
#define AT_STATX_DONT_SYNC 0x4000
#endif

// ioprio syscalls are exposed by the kernel but not by every libc header.
constexpr int kIoprioWhoProcess = 1;
constexpr int kIoprioClassShift = 13;
constexpr int kIoprioClassIdle = 3;
constexpr int kIoprioPrioValue(int priority_class, int data) {
  return (priority_class << kIoprioClassShift) | data;
}

constexpr ssize_t kMaxXattrValueBytes = 64 * 1024;
constexpr int kMaxXattrCount = 64;

namespace {

constexpr char kShellChannelName[] = "broom/shell";
constexpr char kScanPriorityChannelName[] = "broom/scan_priority";
constexpr char kFileMetadataChannelName[] = "broom/file_metadata";
constexpr char kFileLockChannelName[] = "broom/file_lock";
constexpr char kDirectoryEnumChannelName[] = "broom/directory_enum";
constexpr char kSystemChannelName[] = "broom/system";
constexpr char kWindowChannelName[] = "broom/window";
constexpr char kWindowStateChannelName[] = "broom/window_state";

// Shared state for the channels. Owned by the FlView and kept alive for as
// long as the engine can dispatch method calls.
struct BroomChannels {
  GtkWindow* window;
  int original_nice;
  gboolean priority_lowered;
  long original_ioprio;
  gboolean ioprio_lowered;
  FlEventChannel* window_state_channel;
  gboolean window_state_listening;
};

struct PendingDialog {
  FlMethodCall* method_call;
  GtkFileChooserNative* dialog;
};

void FreeBroomChannels(gpointer data) {
  auto* channels = static_cast<BroomChannels*>(data);
  if (channels->window_state_channel != nullptr) {
    g_object_unref(channels->window_state_channel);
  }
  g_free(channels);
}

void RespondSuccess(FlMethodCall* method_call, FlValue* result) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(method_call, result, &error)) {
    g_warning("broom: failed to respond to %s: %s",
              fl_method_call_get_name(method_call), error->message);
  }
}

void RespondError(FlMethodCall* method_call,
                  const char* code,
                  const std::string& message,
                  int error_number) {
  g_autoptr(FlValue) details =
      error_number > 0 ? fl_value_new_int(error_number) : nullptr;
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_error(method_call, code, message.c_str(),
                                    details, &error)) {
    g_warning("broom: failed to respond to %s: %s",
              fl_method_call_get_name(method_call), error->message);
  }
}

void RespondNotImplemented(FlMethodCall* method_call) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_not_implemented(method_call, &error)) {
    g_warning("broom: failed to respond to %s: %s",
              fl_method_call_get_name(method_call), error->message);
  }
}

FlValue* LookupArgument(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

std::string StringArgument(FlValue* args, const char* key) {
  FlValue* value = LookupArgument(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return {};
  }
  return fl_value_get_string(value);
}

int64_t IntArgument(FlValue* args, const char* key, bool* present) {
  FlValue* value = LookupArgument(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    if (present != nullptr) *present = false;
    return 0;
  }
  if (present != nullptr) *present = true;
  return fl_value_get_int(value);
}

int64_t TimespecToMicros(const struct timespec& value) {
  return static_cast<int64_t>(value.tv_sec) * 1000000 +
         static_cast<int64_t>(value.tv_nsec) / 1000;
}

// Reads a path without following links. `birth_micros` is zero when the
// filesystem cannot report a birth time.
bool ReadStat(const std::string& path,
              struct stat* info,
              int64_t* birth_micros) {
  if (birth_micros != nullptr) *birth_micros = 0;
#ifdef BROOM_HAVE_STATX
  struct statx extended;
  std::memset(&extended, 0, sizeof(extended));
  if (statx(AT_FDCWD, path.c_str(), AT_SYMLINK_NOFOLLOW | AT_STATX_DONT_SYNC,
            STATX_BASIC_STATS | STATX_BTIME, &extended) == 0) {
    if (info != nullptr) {
      std::memset(info, 0, sizeof(*info));
      info->st_mode = extended.stx_mode;
      info->st_uid = extended.stx_uid;
      info->st_gid = extended.stx_gid;
      info->st_size = extended.stx_size;
      info->st_ino = extended.stx_ino;
      info->st_dev =
          makedev(extended.stx_dev_major, extended.stx_dev_minor);
      info->st_mtim.tv_sec = extended.stx_mtime.tv_sec;
      info->st_mtim.tv_nsec = extended.stx_mtime.tv_nsec;
    }
    if (birth_micros != nullptr && (extended.stx_mask & STATX_BTIME) != 0) {
      *birth_micros =
          static_cast<int64_t>(extended.stx_btime.tv_sec) * 1000000 +
          static_cast<int64_t>(extended.stx_btime.tv_nsec) / 1000;
    }
    return true;
  }
  // ENOSYS on older kernels: keep going through lstat below.
#endif
  return lstat(path.c_str(), info) == 0;
}

std::string LockKey(unsigned int major_number,
                    unsigned int minor_number,
                    unsigned long long inode) {
  char buffer[96];
  std::snprintf(buffer, sizeof(buffer), "%x:%x:%llu", major_number,
                minor_number, inode);
  return buffer;
}

// `/proc/locks` lists POSIX, OFD and flock locks. Only WRITE locks are a
// useful preview signal: a read lock does not prevent a rename or delete.
void LoadWriteLocks(std::set<std::string>* keys) {
  FILE* file = std::fopen("/proc/locks", "r");
  if (file == nullptr) return;
  char line[512];
  while (std::fgets(line, sizeof(line), file) != nullptr) {
    char type[32] = {};
    char mode[32] = {};
    char access[32] = {};
    unsigned int major_number = 0;
    unsigned int minor_number = 0;
    unsigned long long inode = 0;
    const int fields =
        std::sscanf(line, "%*d: %31s %31s %31s %*d %x:%x:%llu", type, mode,
                    access, &major_number, &minor_number, &inode);
    if (fields != 6 || std::strcmp(access, "WRITE") != 0) continue;
    keys->insert(LockKey(major_number, minor_number, inode));
  }
  std::fclose(file);
}

bool IsDecimalName(const char* name) {
  if (name[0] == '\0') return false;
  for (const char* character = name; *character != '\0'; character++) {
    if (*character < '0' || *character > '9') return false;
  }
  return true;
}

// Advisory locks are optional, so desktop applications that keep a cache file
// open for writing never show up in /proc/locks. Collect those files as well:
// a writable descriptor means the file is actively in use, which is the same
// "skip this while cleaning" signal Broom exposes on Windows. The scan only
// records device/inode pairs, never file paths or process names, and it is
// capped so a pathological process table cannot stall a scan.
void LoadOpenWritableFiles(std::set<std::string>* keys) {
  constexpr size_t kMaxProcesses = 20000;
  constexpr size_t kMaxFileDescriptors = 200000;
  constexpr unsigned long kOPathFlag = 010000000UL;

  DIR* processes = opendir("/proc");
  if (processes == nullptr) return;
  size_t scanned_processes = 0;
  size_t scanned_descriptors = 0;
  while (scanned_processes < kMaxProcesses) {
    struct dirent* process = readdir(processes);
    if (process == nullptr) break;
    if (!IsDecimalName(process->d_name)) continue;
    scanned_processes++;

    const std::string process_root =
        std::string("/proc/") + process->d_name;
    DIR* descriptors = opendir((process_root + "/fd").c_str());
    if (descriptors == nullptr) continue;
    while (true) {
      errno = 0;
      struct dirent* descriptor = readdir(descriptors);
      if (descriptor == nullptr) break;
      if (!IsDecimalName(descriptor->d_name)) continue;
      if (++scanned_descriptors > kMaxFileDescriptors) break;

      const std::string descriptor_path =
          process_root + "/fd/" + descriptor->d_name;
      struct stat target;
      if (stat(descriptor_path.c_str(), &target) != 0 ||
          !S_ISREG(target.st_mode)) {
        continue;
      }

      const std::string info_path =
          process_root + "/fdinfo/" + descriptor->d_name;
      FILE* info = std::fopen(info_path.c_str(), "r");
      if (info == nullptr) continue;
      unsigned long flags = 0;
      char line[256];
      while (std::fgets(line, sizeof(line), info) != nullptr) {
        if (std::strncmp(line, "flags:", 6) != 0) continue;
        const char* value = line + 6;
        while (*value == ' ' || *value == '\t') value++;
        flags = std::strtoul(value, nullptr, 8);
        break;
      }
      std::fclose(info);
      // O_PATH descriptors do not reference file content for I/O.
      if (flags == 0 || (flags & kOPathFlag) != 0) continue;
      if ((flags & O_ACCMODE) == O_RDONLY) continue;
      keys->insert(LockKey(
          static_cast<unsigned int>(major(target.st_dev)),
          static_cast<unsigned int>(minor(target.st_dev)),
          static_cast<unsigned long long>(target.st_ino)));
    }
    closedir(descriptors);
    if (scanned_descriptors > kMaxFileDescriptors) break;
  }
  closedir(processes);
}

// The Dart probe walks large candidates in batches of a few hundred files.
// Reuse one /proc snapshot for consecutive batches instead of rescanning the
// process table for every call.
const std::set<std::string>& OccupiedFileSnapshot() {
  constexpr gint64 kSnapshotTtlMicroseconds = 2 * G_USEC_PER_SEC;
  static std::set<std::string> keys;
  static gint64 loaded_at = 0;
  const gint64 now = g_get_monotonic_time();
  if (loaded_at == 0 || now < loaded_at ||
      now - loaded_at >= kSnapshotTtlMicroseconds) {
    keys.clear();
    LoadWriteLocks(&keys);
    LoadOpenWritableFiles(&keys);
    loaded_at = now;
  }
  return keys;
}

bool PossiblyLocked(const std::string& path,
                    const std::set<std::string>& occupied_files) {
  if (occupied_files.empty()) return false;
  struct stat info;
  if (lstat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) return false;
  const std::string key = LockKey(
      static_cast<unsigned int>(major(info.st_dev)),
      static_cast<unsigned int>(minor(info.st_dev)),
      static_cast<unsigned long long>(info.st_ino));
  return occupied_files.find(key) != occupied_files.end();
}

bool IsDotEntry(const char* name) {
  return name[0] == '.' &&
         (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}

struct DirectoryListing {
  std::vector<std::string> names;
  std::vector<int64_t> sizes;
  std::vector<int64_t> modified;
  // 0 regular file, 1 directory, 2 symbolic link.
  std::vector<int64_t> types;
  int error = 0;
};

void EnumerateDirectory(const std::string& path, DirectoryListing* listing) {
  DIR* directory = opendir(path.c_str());
  if (directory == nullptr) {
    listing->error = errno;
    return;
  }
  const bool needs_separator =
      path.empty() || path.back() != '/';
  while (true) {
    errno = 0;
    struct dirent* entry = readdir(directory);
    if (entry == nullptr) {
      if (errno != 0) listing->error = errno;
      break;
    }
    if (IsDotEntry(entry->d_name)) continue;

    std::string child = path;
    if (needs_separator) child.push_back('/');
    child += entry->d_name;

    int64_t type = 0;
    bool known_type = true;
    switch (entry->d_type) {
      case DT_DIR:
        type = 1;
        break;
      case DT_LNK:
        type = 2;
        break;
      case DT_REG:
        type = 0;
        break;
      case DT_UNKNOWN:
        known_type = false;
        break;
      default:
        // Sockets, FIFOs and devices cannot be cleaned as regular files, but
        // the scanner still sees them so it can classify them consistently.
        type = 0;
        break;
    }

    int64_t size = 0;
    int64_t modified = 0;
    if (type == 0 || !known_type) {
      struct stat info;
      if (!ReadStat(child, &info, nullptr)) continue;
      if (S_ISDIR(info.st_mode)) {
        type = 1;
      } else if (S_ISLNK(info.st_mode)) {
        type = 2;
      } else if (!S_ISREG(info.st_mode) && !known_type) {
        type = 0;
      }
      if (type == 0 && S_ISREG(info.st_mode)) {
        size = static_cast<int64_t>(info.st_size);
        modified = TimespecToMicros(info.st_mtim);
      }
    }

    listing->names.push_back(entry->d_name);
    listing->types.push_back(type);
    listing->sizes.push_back(size);
    listing->modified.push_back(modified);
  }
  closedir(directory);
}

void AppendXattrs(const std::string& path,
                  FlValue* target,
                  bool* unavailable) {
  ssize_t length = llistxattr(path.c_str(), nullptr, 0);
  if (length < 0) {
    *unavailable = true;
    return;
  }
  if (length == 0) return;
  std::vector<char> names(static_cast<size_t>(length));
  length = llistxattr(path.c_str(), names.data(), names.size());
  if (length < 0) {
    *unavailable = true;
    return;
  }

  size_t offset = 0;
  int count = 0;
  while (offset < static_cast<size_t>(length) && count < kMaxXattrCount) {
    const char* name = names.data() + offset;
    const size_t remaining = static_cast<size_t>(length) - offset;
    size_t name_length = 0;
    while (name_length < remaining && name[name_length] != '\0') {
      name_length++;
    }
    if (name_length == 0 || name_length == remaining) break;
    offset += name_length + 1;

    ssize_t value_length = lgetxattr(path.c_str(), name, nullptr, 0);
    if (value_length < 0) {
      if (errno == ENODATA) continue;
      *unavailable = true;
      continue;
    }
    if (value_length == 0 || value_length > kMaxXattrValueBytes) continue;
    std::vector<uint8_t> value(static_cast<size_t>(value_length));
    value_length =
        lgetxattr(path.c_str(), name, value.data(), value.size());
    if (value_length < 0) {
      *unavailable = true;
      continue;
    }
    value.resize(static_cast<size_t>(value_length));
    fl_value_set_string_take(
        target, name,
        fl_value_new_uint8_list(value.data(), value.size()));
    count++;
  }
}

// --- broom/shell -----------------------------------------------------------

void HandleQueryDiskSpace(FlMethodCall* method_call, FlValue* args) {
  const std::string path = StringArgument(args, "path");
  if (path.empty()) {
    RespondError(method_call, "invalid_arguments", "缺少磁盘路径。", EINVAL);
    return;
  }

  struct statvfs info;
  if (statvfs(path.c_str(), &info) != 0) {
    const int error_number = errno;
    RespondError(method_call, "statvfs_failed",
                 std::string("无法读取磁盘空间：") + std::strerror(error_number),
                 error_number);
    return;
  }

  const auto free_bytes = static_cast<int64_t>(info.f_bavail) *
                          static_cast<int64_t>(info.f_frsize);
  const auto total_bytes = static_cast<int64_t>(info.f_blocks) *
                           static_cast<int64_t>(info.f_frsize);
  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "freeBytes", fl_value_new_int(free_bytes));
  fl_value_set_string_take(result, "totalBytes", fl_value_new_int(total_bytes));
  RespondSuccess(method_call, result);
}

void OnDialogResponse(GtkNativeDialog* dialog,
                      gint response_id,
                      gpointer user_data) {
  auto* pending = static_cast<PendingDialog*>(user_data);
  g_autoptr(FlValue) result = nullptr;
  if (response_id == GTK_RESPONSE_ACCEPT) {
    g_autofree gchar* filename =
        gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
    if (filename != nullptr && filename[0] != '\0') {
      result = fl_value_new_string(filename);
    }
  }
  if (result == nullptr) {
    result = fl_value_new_null();
  }
  RespondSuccess(pending->method_call, result);

  g_object_unref(pending->dialog);
  g_object_unref(pending->method_call);
  g_free(pending);
}

// Takes over the caller's reference to `dialog` once shown.
void ShowFileDialog(GtkFileChooserNative* dialog,
                    FlMethodCall* method_call,
                    const std::string& initial_directory,
                    const std::string& suggested_name) {
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);
  if (!initial_directory.empty()) {
    gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog),
                                        initial_directory.c_str());
  }
  if (!suggested_name.empty()) {
    gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(dialog),
                                      suggested_name.c_str());
  }

  auto* pending = g_new0(PendingDialog, 1);
  pending->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  pending->dialog = GTK_FILE_CHOOSER_NATIVE(g_object_ref(dialog));
  g_signal_connect(dialog, "response", G_CALLBACK(OnDialogResponse), pending);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
  g_object_unref(dialog);
}

void AddJsonFilter(GtkFileChooserNative* dialog) {
  GtkFileFilter* filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, "JSON 配置 (*.json)");
  gtk_file_filter_add_pattern(filter, "*.json");
  gtk_file_filter_add_pattern(filter, "*.JSON");
  gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);
}

void HandlePickFolder(BroomChannels* channels,
                      FlMethodCall* method_call,
                      FlValue* args) {
  GtkFileChooserNative* dialog = gtk_file_chooser_native_new(
      "选择文件夹", channels->window, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
      "选择", "取消");
  ShowFileDialog(dialog, method_call, StringArgument(args, "initialDirectory"),
                 {});
}

void HandlePickJsonFile(BroomChannels* channels,
                        FlMethodCall* method_call,
                        FlValue* args) {
  const std::string title = StringArgument(args, "title");
  GtkFileChooserNative* dialog = gtk_file_chooser_native_new(
      title.empty() ? "选择配置文件" : title.c_str(), channels->window,
      GTK_FILE_CHOOSER_ACTION_OPEN, "选择", "取消");
  AddJsonFilter(dialog);
  ShowFileDialog(dialog, method_call, StringArgument(args, "initialDirectory"),
                 {});
}

void HandleSaveJsonFile(BroomChannels* channels,
                        FlMethodCall* method_call,
                        FlValue* args) {
  const std::string title = StringArgument(args, "title");
  std::string suggested_name = StringArgument(args, "suggestedName");
  if (suggested_name.empty()) {
    suggested_name = "broom-config.json";
  }
  GtkFileChooserNative* dialog = gtk_file_chooser_native_new(
      title.empty() ? "保存配置文件" : title.c_str(), channels->window,
      GTK_FILE_CHOOSER_ACTION_SAVE, "保存", "取消");
  AddJsonFilter(dialog);
  gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(dialog),
                                                 TRUE);
  ShowFileDialog(dialog, method_call, StringArgument(args, "initialDirectory"),
                 suggested_name);
}

void HandleRevealPath(FlMethodCall* method_call, FlValue* args) {
  const std::string path = StringArgument(args, "path");
  if (path.empty()) {
    RespondError(method_call, "invalid_arguments", "缺少文件路径。", EINVAL);
    return;
  }

  struct stat info;
  if (stat(path.c_str(), &info) != 0) {
    const int error_number = errno;
    RespondError(method_call, "stat_failed",
                 std::string("无法读取文件信息：") + std::strerror(error_number),
                 error_number);
    return;
  }

  std::string directory = path;
  if (!S_ISDIR(info.st_mode)) {
    const auto slash = path.find_last_of('/');
    if (slash == std::string::npos) {
      directory = ".";
    } else if (slash == 0) {
      directory = "/";
    } else {
      directory = path.substr(0, slash);
    }
  }

  g_autoptr(GFile) file = g_file_new_for_path(directory.c_str());
  g_autofree gchar* uri = g_file_get_uri(file);
  GError* error = nullptr;
  if (!g_app_info_launch_default_for_uri(uri, nullptr, &error)) {
    const std::string message =
        error != nullptr ? error->message : "无法打开文件位置。";
    g_clear_error(&error);
    RespondError(method_call, "launch_failed", message, 0);
    return;
  }
  RespondSuccess(method_call, nullptr);
}

void HandleQueryRecycleBin(FlMethodCall* method_call) {
  TrashSummary summary;
  int error_number = 0;
  if (!QueryUserTrash(&summary, &error_number)) {
    RespondError(method_call, "recycle_bin_query_failed",
                 std::string("无法读取回收站：") +
                     std::strerror(error_number),
                 error_number);
    return;
  }

  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "itemCount",
                           fl_value_new_int(summary.item_count));
  fl_value_set_string_take(result, "totalBytes",
                           fl_value_new_int(summary.total_bytes));
  RespondSuccess(method_call, result);
}

void HandleEmptyRecycleBin(FlMethodCall* method_call) {
  int error_number = 0;
  if (!EmptyUserTrash(&error_number)) {
    RespondError(method_call, "recycle_bin_empty_failed",
                 std::string("无法清空回收站：") +
                     std::strerror(error_number),
                 error_number);
    return;
  }
  RespondSuccess(method_call, nullptr);
}

void ShellMethodCallHandler(FlMethodChannel*,
                            FlMethodCall* method_call,
                            gpointer user_data) {
  auto* channels = static_cast<BroomChannels*>(user_data);
  FlValue* args = fl_method_call_get_args(method_call);
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "queryDiskSpace") == 0) {
    HandleQueryDiskSpace(method_call, args);
  } else if (g_strcmp0(method, "pickFolder") == 0) {
    HandlePickFolder(channels, method_call, args);
  } else if (g_strcmp0(method, "pickJsonFile") == 0) {
    HandlePickJsonFile(channels, method_call, args);
  } else if (g_strcmp0(method, "saveJsonFile") == 0) {
    HandleSaveJsonFile(channels, method_call, args);
  } else if (g_strcmp0(method, "revealPath") == 0) {
    HandleRevealPath(method_call, args);
  } else if (g_strcmp0(method, "queryRecycleBin") == 0) {
    HandleQueryRecycleBin(method_call);
  } else if (g_strcmp0(method, "emptyRecycleBin") == 0) {
    HandleEmptyRecycleBin(method_call);
  } else {
    RespondNotImplemented(method_call);
  }
}

// --- broom/scan_priority ---------------------------------------------------

long ReadIoprio() {
#ifdef SYS_ioprio_get
  return static_cast<long>(
      syscall(SYS_ioprio_get, kIoprioWhoProcess, 0));
#else
  return -1;
#endif
}

bool WriteIoprio(long value) {
#ifdef SYS_ioprio_set
  return syscall(SYS_ioprio_set, kIoprioWhoProcess, 0,
                 static_cast<int>(value)) == 0;
#else
  (void)value;
  return false;
#endif
}

void HandlePriorityBegin(BroomChannels* channels, FlMethodCall* method_call) {
  bool cpu_lowered = false;
  bool io_lowered = false;

  errno = 0;
  const int current = getpriority(PRIO_PROCESS, 0);
  if (errno == 0) {
    if (!channels->priority_lowered) {
      channels->original_nice = current;
    }
    // Only ever lower the priority; raising it would need privileges and would
    // make the UI less responsive.
    const int target = current < 10 ? 10 : current;
    if (setpriority(PRIO_PROCESS, 0, target) == 0) {
      channels->priority_lowered = TRUE;
      cpu_lowered = true;
    }
  }

  const long current_ioprio = ReadIoprio();
  if (current_ioprio >= 0) {
    if (!channels->ioprio_lowered) {
      channels->original_ioprio = current_ioprio;
    }
    // Idle class is lower than every best-effort level, including the scan's
    // own reads. It is best effort: unprivileged processes may still set it.
    if (WriteIoprio(kIoprioPrioValue(kIoprioClassIdle, 0))) {
      channels->ioprio_lowered = TRUE;
      io_lowered = true;
    }
  }

  if (!cpu_lowered && !io_lowered) {
    // Priority is an optimization; a scan must still start.
    RespondSuccess(method_call, nullptr);
    return;
  }

  std::string message = "扫描期间已降低进程优先级";
  if (cpu_lowered && io_lowered) {
    message += "（nice 10，I/O idle）";
  } else if (cpu_lowered) {
    message += "（nice 10）";
  } else {
    message += "（I/O idle）";
  }
  RespondSuccess(method_call, fl_value_new_string(message.c_str()));
}

void HandlePriorityEnd(BroomChannels* channels, FlMethodCall* method_call) {
  if (channels->priority_lowered) {
    const int ignored =
        setpriority(PRIO_PROCESS, 0, channels->original_nice);
    (void)ignored;
    channels->priority_lowered = FALSE;
  }
  if (channels->ioprio_lowered) {
    WriteIoprio(channels->original_ioprio);
    channels->ioprio_lowered = FALSE;
  }
  RespondSuccess(method_call, nullptr);
}

void ScanPriorityMethodCallHandler(FlMethodChannel*,
                                   FlMethodCall* method_call,
                                   gpointer user_data) {
  auto* channels = static_cast<BroomChannels*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "begin") == 0) {
    HandlePriorityBegin(channels, method_call);
  } else if (g_strcmp0(method, "end") == 0) {
    HandlePriorityEnd(channels, method_call);
  } else {
    RespondNotImplemented(method_call);
  }
}

// --- broom/file_metadata ---------------------------------------------------

void SetTimeSpec(struct timespec* spec, int64_t micros) {
  int64_t seconds = micros / 1000000;
  int64_t remainder = micros % 1000000;
  if (remainder < 0) {
    remainder += 1000000;
    seconds -= 1;
  }
  spec->tv_sec = static_cast<time_t>(seconds);
  spec->tv_nsec = static_cast<long>(remainder * 1000);
}

void HandleReadPosixMetadata(FlMethodCall* method_call, FlValue* args) {
  const std::string path = StringArgument(args, "path");
  if (path.empty()) {
    RespondError(method_call, "invalid_arguments", "缺少文件路径。", EINVAL);
    return;
  }

  struct stat info;
  int64_t birth_micros = 0;
  if (!ReadStat(path, &info, &birth_micros)) {
    const int error_number = errno;
    RespondError(method_call, "stat_failed",
                 std::string("无法读取文件元数据：") +
                     std::strerror(error_number),
                 error_number);
    return;
  }

  bool xattrs_unavailable = false;
  g_autoptr(FlValue) xattrs = fl_value_new_map();
  AppendXattrs(path, xattrs, &xattrs_unavailable);

  g_autoptr(FlValue) result = fl_value_new_map();
  if (birth_micros > 0) {
    fl_value_set_string_take(result, "createdMicros",
                             fl_value_new_int(birth_micros));
  }
  fl_value_set_string_take(result, "uid",
                           fl_value_new_int(static_cast<int64_t>(info.st_uid)));
  fl_value_set_string_take(result, "gid",
                           fl_value_new_int(static_cast<int64_t>(info.st_gid)));
  fl_value_set_string_take(result, "xattrs", g_steal_pointer(&xattrs));
  if (xattrs_unavailable) {
    fl_value_set_string_take(result, "xattrsUnavailable",
                             fl_value_new_bool(TRUE));
  }
  RespondSuccess(method_call, result);
}

void HandleApplyPosixMetadata(FlMethodCall* method_call, FlValue* args) {
  const std::string path = StringArgument(args, "path");
  if (path.empty()) {
    RespondError(method_call, "invalid_arguments", "缺少文件路径。", EINVAL);
    return;
  }

  int first_error = 0;

  // Ownership first: chown clears setuid/setgid bits and may change ACL
  // evaluation, so the mode and extended attributes are restored afterwards.
  bool has_uid = false;
  bool has_gid = false;
  const int64_t uid = IntArgument(args, "uid", &has_uid);
  const int64_t gid = IntArgument(args, "gid", &has_gid);
  if (has_uid || has_gid) {
    struct stat current;
    const bool known = lstat(path.c_str(), &current) == 0;
    const bool unchanged =
        known && (!has_uid || static_cast<int64_t>(current.st_uid) == uid) &&
        (!has_gid || static_cast<int64_t>(current.st_gid) == gid);
    if (!unchanged) {
      const uid_t target_uid =
          has_uid ? static_cast<uid_t>(uid) : static_cast<uid_t>(-1);
      const gid_t target_gid =
          has_gid ? static_cast<gid_t>(gid) : static_cast<gid_t>(-1);
      if (lchown(path.c_str(), target_uid, target_gid) != 0) {
        first_error = errno;
      }
    }
  }

  bool has_mode = false;
  const int64_t mode = IntArgument(args, "mode", &has_mode);
  if (has_mode) {
    if (chmod(path.c_str(), static_cast<mode_t>(mode)) != 0 &&
        first_error == 0) {
      first_error = errno;
    }
  }

  FlValue* xattrs = LookupArgument(args, "xattrs");
  if (xattrs != nullptr && fl_value_get_type(xattrs) == FL_VALUE_TYPE_MAP) {
    const size_t count = fl_value_get_length(xattrs);
    for (size_t index = 0; index < count; index++) {
      FlValue* name = fl_value_get_map_key(xattrs, index);
      FlValue* value = fl_value_get_map_value(xattrs, index);
      if (name == nullptr || value == nullptr ||
          fl_value_get_type(name) != FL_VALUE_TYPE_STRING ||
          fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST) {
        continue;
      }
      const char* key = fl_value_get_string(name);
      const uint8_t* bytes = fl_value_get_uint8_list(value);
      const size_t length = fl_value_get_length(value);
      if (key == nullptr || key[0] == '\0' || length > kMaxXattrValueBytes) {
        continue;
      }
      if (lsetxattr(path.c_str(), key, bytes, length, 0) != 0) {
        // Capabilities, SELinux labels and POSIX ACLs commonly require
        // privileges the cleaner does not have. The remaining values still
        // restore; only unexpected errors reach the report.
        const int error_number = errno;
        const bool restricted =
            error_number == EPERM || error_number == EACCES ||
            error_number == ENOTSUP || error_number == EOPNOTSUPP;
        if (!restricted && first_error == 0) first_error = error_number;
      }
    }
  }

  // Timestamps last: chown/chmod/xattr updates change ctime and would
  // otherwise overwrite the restored mtime.
  bool has_modified = false;
  const int64_t modified_micros =
      IntArgument(args, "modifiedMicros", &has_modified);
  bool has_accessed = false;
  const int64_t accessed_micros =
      IntArgument(args, "accessedMicros", &has_accessed);

  if (has_modified || has_accessed) {
    struct timespec times[2];
    times[0].tv_sec = 0;
    times[0].tv_nsec = UTIME_OMIT;
    times[1].tv_sec = 0;
    times[1].tv_nsec = UTIME_OMIT;
    if (has_accessed) {
      SetTimeSpec(&times[0], accessed_micros);
    }
    if (has_modified) {
      SetTimeSpec(&times[1], modified_micros);
    }
    if (utimensat(AT_FDCWD, path.c_str(), times, 0) != 0 &&
        first_error == 0) {
      first_error = errno;
    }
  }

  if (first_error != 0) {
    RespondError(method_call, "metadata_apply_failed",
                 std::string("无法恢复文件元数据：") +
                     std::strerror(first_error),
                 first_error);
    return;
  }

  RespondSuccess(method_call, nullptr);
}

void HandleDeviceIds(FlMethodCall* method_call, FlValue* args) {
  FlValue* paths = LookupArgument(args, "paths");
  if (paths == nullptr || fl_value_get_type(paths) != FL_VALUE_TYPE_LIST) {
    RespondError(method_call, "invalid_arguments", "缺少路径列表。", EINVAL);
    return;
  }

  g_autoptr(FlValue) result = fl_value_new_list();
  const size_t count = fl_value_get_length(paths);
  for (size_t index = 0; index < count; index++) {
    FlValue* item = fl_value_get_list_value(paths, index);
    if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_STRING) {
      fl_value_append_take(result, fl_value_new_null());
      continue;
    }
    struct stat info;
    if (stat(fl_value_get_string(item), &info) != 0) {
      fl_value_append_take(result, fl_value_new_null());
      continue;
    }
    fl_value_append_take(
        result, fl_value_new_int(static_cast<int64_t>(info.st_dev)));
  }
  RespondSuccess(method_call, result);
}

void FileMetadataMethodCallHandler(FlMethodChannel*,
                                   FlMethodCall* method_call,
                                   gpointer) {
  FlValue* args = fl_method_call_get_args(method_call);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "applyPosixMetadata") == 0) {
    HandleApplyPosixMetadata(method_call, args);
  } else if (g_strcmp0(method, "readPosixMetadata") == 0) {
    HandleReadPosixMetadata(method_call, args);
  } else if (g_strcmp0(method, "deviceIds") == 0) {
    HandleDeviceIds(method_call, args);
  } else {
    RespondNotImplemented(method_call);
  }
}

// --- broom/file_lock -------------------------------------------------------

void FileLockMethodCallHandler(FlMethodChannel*,
                               FlMethodCall* method_call,
                               gpointer) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "probe") != 0) {
    RespondNotImplemented(method_call);
    return;
  }
  FlValue* paths = LookupArgument(fl_method_call_get_args(method_call), "paths");
  if (paths == nullptr || fl_value_get_type(paths) != FL_VALUE_TYPE_LIST) {
    RespondError(method_call, "invalid_arguments", "缺少路径列表。", EINVAL);
    return;
  }

  const std::set<std::string>& occupied_files = OccupiedFileSnapshot();

  g_autoptr(FlValue) result = fl_value_new_list();
  const size_t count = fl_value_get_length(paths);
  for (size_t index = 0; index < count; index++) {
    FlValue* item = fl_value_get_list_value(paths, index);
    bool locked = false;
    if (item != nullptr && fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
      locked = PossiblyLocked(fl_value_get_string(item), occupied_files);
    }
    fl_value_append_take(result, fl_value_new_bool(locked));
  }
  RespondSuccess(method_call, result);
}

// --- broom/directory_enum --------------------------------------------------

struct EnumerateTask {
  FlMethodCall* method_call;
  std::string path;
  DirectoryListing listing;
};

void FreeEnumerateTask(gpointer data) {
  auto* task = static_cast<EnumerateTask*>(data);
  if (task->method_call != nullptr) g_object_unref(task->method_call);
  delete task;
}

void EnumerateInThread(GTask* task,
                       gpointer,
                       gpointer task_data,
                       GCancellable*) {
  auto* data = static_cast<EnumerateTask*>(task_data);
  EnumerateDirectory(data->path, &data->listing);
  g_task_return_boolean(task, TRUE);
}

void OnEnumerateFinished(GObject*, GAsyncResult* result, gpointer) {
  GTask* task = G_TASK(result);
  auto* data = static_cast<EnumerateTask*>(g_task_get_task_data(task));
  g_autoptr(GError) error = nullptr;
  g_task_propagate_boolean(task, &error);
  if (data == nullptr || data->method_call == nullptr) return;

  if (data->listing.error != 0) {
    const int error_number = data->listing.error;
    RespondError(data->method_call, "posix",
                 std::string("无法读取目录：") +
                     std::strerror(error_number),
                 error_number);
    return;
  }

  g_autoptr(FlValue) names = fl_value_new_list();
  g_autoptr(FlValue) sizes = fl_value_new_list();
  g_autoptr(FlValue) modified = fl_value_new_list();
  g_autoptr(FlValue) types = fl_value_new_list();
  const size_t count = data->listing.names.size();
  for (size_t index = 0; index < count; index++) {
    fl_value_append_take(names,
                         fl_value_new_string(data->listing.names[index].c_str()));
    fl_value_append_take(sizes,
                         fl_value_new_int(data->listing.sizes[index]));
    fl_value_append_take(modified,
                         fl_value_new_int(data->listing.modified[index]));
    fl_value_append_take(types,
                         fl_value_new_int(data->listing.types[index]));
  }

  g_autoptr(FlValue) response = fl_value_new_map();
  fl_value_set_string_take(response, "names", g_steal_pointer(&names));
  fl_value_set_string_take(response, "sizes", g_steal_pointer(&sizes));
  fl_value_set_string_take(response, "modified", g_steal_pointer(&modified));
  fl_value_set_string_take(response, "types", g_steal_pointer(&types));
  RespondSuccess(data->method_call, response);
}

void DirectoryEnumMethodCallHandler(FlMethodChannel*,
                                    FlMethodCall* method_call,
                                    gpointer) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "ping") == 0) {
    RespondSuccess(method_call, fl_value_new_bool(TRUE));
    return;
  }
  if (g_strcmp0(method, "listDirectory") != 0) {
    RespondNotImplemented(method_call);
    return;
  }

  const std::string path =
      StringArgument(fl_method_call_get_args(method_call), "path");
  if (path.empty()) {
    RespondError(method_call, "invalid_arguments", "缺少目录路径。", EINVAL);
    return;
  }

  auto* data = new EnumerateTask{};
  data->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  data->path = path;

  GTask* task = g_task_new(nullptr, nullptr, OnEnumerateFinished, nullptr);
  g_task_set_task_data(task, data, FreeEnumerateTask);
  g_task_run_in_thread(task, EnumerateInThread);
  g_object_unref(task);
}

// --- broom/system ----------------------------------------------------------

void SystemMethodCallHandler(FlMethodChannel*,
                             FlMethodCall* method_call,
                             gpointer) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "appVersion") == 0) {
    RespondSuccess(method_call, fl_value_new_string(BROOM_VERSION));
    return;
  }
  RespondNotImplemented(method_call);
}

// --- broom/window ----------------------------------------------------------

void SendWindowState(BroomChannels* channels, gboolean maximized) {
  if (channels->window_state_channel == nullptr ||
      !channels->window_state_listening) {
    return;
  }
  g_autoptr(FlValue) value = fl_value_new_bool(maximized);
  g_autoptr(GError) error = nullptr;
  if (!fl_event_channel_send(channels->window_state_channel, value, nullptr,
                             &error)) {
    g_warning("broom: failed to send window state: %s", error->message);
  }
}

gboolean OnWindowStateEvent(GtkWidget*,
                            GdkEventWindowState* event,
                            gpointer user_data) {
  auto* channels = static_cast<BroomChannels*>(user_data);
  SendWindowState(
      channels,
      (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0);
  return FALSE;
}

FlMethodErrorResponse* OnWindowStateListen(FlEventChannel*,
                                           FlValue*,
                                           gpointer user_data) {
  auto* channels = static_cast<BroomChannels*>(user_data);
  channels->window_state_listening = TRUE;
  SendWindowState(channels, gtk_window_is_maximized(channels->window));
  return nullptr;
}

FlMethodErrorResponse* OnWindowStateCancel(FlEventChannel*,
                                           FlValue*,
                                           gpointer user_data) {
  auto* channels = static_cast<BroomChannels*>(user_data);
  channels->window_state_listening = FALSE;
  return nullptr;
}

void HandleWindowStartDrag(BroomChannels* channels,
                           FlMethodCall* method_call) {
  gint root_x = 0;
  gint root_y = 0;
  guint32 timestamp = GDK_CURRENT_TIME;
  const GdkEvent* event = gtk_get_current_event();
  if (event != nullptr) {
    timestamp = gdk_event_get_time(event);
    gdouble event_x = 0;
    gdouble event_y = 0;
    if (gdk_event_get_root_coords(event, &event_x, &event_y)) {
      root_x = static_cast<gint>(event_x);
      root_y = static_cast<gint>(event_y);
    }
  }
  if (root_x == 0 && root_y == 0) {
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(channels->window));
    GdkSeat* seat = display != nullptr ? gdk_display_get_default_seat(display)
                                       : nullptr;
    GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
    if (pointer != nullptr) {
      gdk_device_get_position(pointer, nullptr, &root_x, &root_y);
    }
  }
  gtk_window_begin_move_drag(channels->window, 1, root_x, root_y, timestamp);
  RespondSuccess(method_call, nullptr);
}

void HandleWindowToggleMaximize(BroomChannels* channels,
                                FlMethodCall* method_call) {
  if (gtk_window_is_maximized(channels->window)) {
    gtk_window_unmaximize(channels->window);
  } else {
    gtk_window_maximize(channels->window);
  }
  RespondSuccess(method_call, nullptr);
}

void OnMenuMinimize(GtkMenuItem*, gpointer user_data) {
  gtk_window_iconify(GTK_WINDOW(user_data));
}

void OnMenuToggleMaximize(GtkMenuItem*, gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  if (gtk_window_is_maximized(window)) {
    gtk_window_unmaximize(window);
  } else {
    gtk_window_maximize(window);
  }
}

void OnMenuClose(GtkMenuItem*, gpointer user_data) {
  gtk_window_close(GTK_WINDOW(user_data));
}

void HandleWindowShowSystemMenu(BroomChannels* channels,
                                FlMethodCall* method_call) {
  GtkWidget* menu = gtk_menu_new();
  GtkWidget* minimize = gtk_menu_item_new_with_label("最小化");
  GtkWidget* toggle = gtk_menu_item_new_with_label(
      gtk_window_is_maximized(channels->window) ? "还原" : "最大化");
  GtkWidget* close = gtk_menu_item_new_with_label("关闭");
  g_signal_connect(minimize, "activate", G_CALLBACK(OnMenuMinimize),
                   channels->window);
  g_signal_connect(toggle, "activate", G_CALLBACK(OnMenuToggleMaximize),
                   channels->window);
  g_signal_connect(close, "activate", G_CALLBACK(OnMenuClose),
                   channels->window);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), minimize);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), toggle);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), close);
  gtk_widget_show_all(menu);
  g_object_ref_sink(menu);
  g_signal_connect_swapped(menu, "selection-done", G_CALLBACK(g_object_unref),
                           menu);
  gtk_menu_popup_at_pointer(GTK_MENU(menu), gtk_get_current_event());
  RespondSuccess(method_call, nullptr);
}

void WindowMethodCallHandler(FlMethodChannel*,
                             FlMethodCall* method_call,
                             gpointer user_data) {
  auto* channels = static_cast<BroomChannels*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "startDrag") == 0) {
    HandleWindowStartDrag(channels, method_call);
  } else if (g_strcmp0(method, "minimize") == 0) {
    gtk_window_iconify(channels->window);
    RespondSuccess(method_call, nullptr);
  } else if (g_strcmp0(method, "toggleMaximize") == 0) {
    HandleWindowToggleMaximize(channels, method_call);
  } else if (g_strcmp0(method, "close") == 0) {
    gtk_window_close(channels->window);
    RespondSuccess(method_call, nullptr);
  } else if (g_strcmp0(method, "showSystemMenu") == 0) {
    HandleWindowShowSystemMenu(channels, method_call);
  } else {
    RespondNotImplemented(method_call);
  }
}

// --- resize handles --------------------------------------------------------

struct ResizeHandle {
  GtkWindow* window;
  GdkWindowEdge edge;
};

void FreeResizeHandle(gpointer data, GClosure*) {
  g_free(data);
}

gboolean OnResizeButtonPress(GtkWidget*,
                             GdkEventButton* event,
                             gpointer user_data) {
  if (event->button != 1) return FALSE;
  auto* handle = static_cast<ResizeHandle*>(user_data);
  gtk_window_begin_resize_drag(handle->window, handle->edge, event->button,
                               static_cast<gint>(event->x_root),
                               static_cast<gint>(event->y_root), event->time);
  return TRUE;
}

GdkCursorType CursorForEdge(GdkWindowEdge edge) {
  switch (edge) {
    case GDK_WINDOW_EDGE_NORTH:
    case GDK_WINDOW_EDGE_SOUTH:
      return GDK_SB_V_DOUBLE_ARROW;
    case GDK_WINDOW_EDGE_EAST:
    case GDK_WINDOW_EDGE_WEST:
      return GDK_SB_H_DOUBLE_ARROW;
    case GDK_WINDOW_EDGE_NORTH_WEST:
      return GDK_TOP_LEFT_CORNER;
    case GDK_WINDOW_EDGE_SOUTH_EAST:
      return GDK_BOTTOM_RIGHT_CORNER;
    case GDK_WINDOW_EDGE_NORTH_EAST:
      return GDK_TOP_RIGHT_CORNER;
    case GDK_WINDOW_EDGE_SOUTH_WEST:
      return GDK_BOTTOM_LEFT_CORNER;
    default:
      return GDK_LEFT_PTR;
  }
}

gboolean OnResizeHandleEnter(GtkWidget* widget,
                             GdkEventCrossing*,
                             gpointer user_data) {
  auto* handle = static_cast<ResizeHandle*>(user_data);
  GdkWindow* window = gtk_widget_get_window(widget);
  if (window == nullptr) return FALSE;
  GdkCursor* cursor = gdk_cursor_new_for_display(
      gtk_widget_get_display(widget), CursorForEdge(handle->edge));
  gdk_window_set_cursor(window, cursor);
  g_object_unref(cursor);
  return FALSE;
}

gboolean OnResizeHandleLeave(GtkWidget* widget,
                             GdkEventCrossing*,
                             gpointer) {
  GdkWindow* window = gtk_widget_get_window(widget);
  if (window != nullptr) gdk_window_set_cursor(window, nullptr);
  return FALSE;
}

void AddResizeHandle(GtkWidget* overlay,
                     GtkWindow* window,
                     GdkWindowEdge edge,
                     GtkAlign horizontal,
                     GtkAlign vertical,
                     gint width,
                     gint height) {
  // A no-window widget receives events through the window it is allocated in,
  // which is what GtkOverlay requires from overlay children.
  GtkWidget* area = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_add_events(area, GDK_BUTTON_PRESS_MASK |
                                  GDK_POINTER_MOTION_MASK |
                                  GDK_ENTER_NOTIFY_MASK |
                                  GDK_LEAVE_NOTIFY_MASK);
  gtk_widget_set_halign(area, horizontal);
  gtk_widget_set_valign(area, vertical);
  gtk_widget_set_size_request(area, width, height);
  auto* handle = g_new0(ResizeHandle, 1);
  handle->window = window;
  handle->edge = edge;
  g_signal_connect_data(area, "button-press-event",
                        G_CALLBACK(OnResizeButtonPress), handle,
                        FreeResizeHandle, static_cast<GConnectFlags>(0));
  g_signal_connect(area, "enter-notify-event", G_CALLBACK(OnResizeHandleEnter),
                   handle);
  g_signal_connect(area, "leave-notify-event", G_CALLBACK(OnResizeHandleLeave),
                   handle);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), area);
  gtk_widget_show(area);
}

void RegisterChannel(FlBinaryMessenger* messenger,
                     const char* name,
                     FlMethodChannelMethodCallHandler handler,
                     BroomChannels* channels) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, name, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handler, channels, nullptr);
  // The messenger keeps its own reference to the channel.
  g_object_unref(channel);
}

}  // namespace

void broom_install_window_handles(GtkWindow* window, GtkWidget* overlay) {
  if (window == nullptr || overlay == nullptr ||
      !GTK_IS_OVERLAY(overlay)) {
    return;
  }
  constexpr gint edge = 6;
  constexpr gint corner = 14;
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_NORTH, GTK_ALIGN_FILL,
                  GTK_ALIGN_START, -1, edge);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_SOUTH, GTK_ALIGN_FILL,
                  GTK_ALIGN_END, -1, edge);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_WEST, GTK_ALIGN_START,
                  GTK_ALIGN_FILL, edge, -1);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_EAST, GTK_ALIGN_END,
                  GTK_ALIGN_FILL, edge, -1);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_NORTH_WEST, GTK_ALIGN_START,
                  GTK_ALIGN_START, corner, corner);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_NORTH_EAST, GTK_ALIGN_END,
                  GTK_ALIGN_START, corner, corner);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_SOUTH_WEST, GTK_ALIGN_START,
                  GTK_ALIGN_END, corner, corner);
  AddResizeHandle(overlay, window, GDK_WINDOW_EDGE_SOUTH_EAST, GTK_ALIGN_END,
                  GTK_ALIGN_END, corner, corner);
}

void broom_register_native_channels(FlView* view, GtkWindow* window) {
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));

  auto* channels = g_new0(BroomChannels, 1);
  channels->window = window;
  channels->original_nice = 0;
  channels->priority_lowered = FALSE;
  channels->original_ioprio = 0;
  channels->ioprio_lowered = FALSE;
  channels->window_state_channel = nullptr;
  channels->window_state_listening = FALSE;
  // Handlers keep using the context while the view is alive.
  g_object_set_data_full(G_OBJECT(view), "broom-native-channels", channels,
                         FreeBroomChannels);

  RegisterChannel(messenger, kShellChannelName, ShellMethodCallHandler,
                  channels);
  RegisterChannel(messenger, kScanPriorityChannelName,
                  ScanPriorityMethodCallHandler, channels);
  RegisterChannel(messenger, kFileMetadataChannelName,
                  FileMetadataMethodCallHandler, channels);
  RegisterChannel(messenger, kFileLockChannelName, FileLockMethodCallHandler,
                  channels);
  RegisterChannel(messenger, kDirectoryEnumChannelName,
                  DirectoryEnumMethodCallHandler, channels);
  RegisterChannel(messenger, kSystemChannelName, SystemMethodCallHandler,
                  channels);
  RegisterChannel(messenger, kWindowChannelName, WindowMethodCallHandler,
                  channels);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlEventChannel* window_state =
      fl_event_channel_new(messenger, kWindowStateChannelName,
                           FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      window_state, OnWindowStateListen, OnWindowStateCancel, channels,
      nullptr);
  // The channel is released with the per-view channel context.
  channels->window_state_channel = window_state;

  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(OnWindowStateEvent), channels);
}
