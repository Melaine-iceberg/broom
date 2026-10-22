#include "native_channels.h"

#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#include <gtk/gtk.h>

namespace {

constexpr char kShellChannelName[] = "broom/shell";
constexpr char kScanPriorityChannelName[] = "broom/scan_priority";
constexpr char kFileMetadataChannelName[] = "broom/file_metadata";

// Shared state for the channels. Owned by the FlView and kept alive for as
// long as the engine can dispatch method calls.
struct BroomChannels {
  GtkWindow* window;
  int original_nice;
  gboolean priority_lowered;
};

struct PendingDialog {
  FlMethodCall* method_call;
  GtkFileChooserNative* dialog;
};

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
  } else if (g_strcmp0(method, "queryRecycleBin") == 0 ||
             g_strcmp0(method, "emptyRecycleBin") == 0) {
    // The UI hides recycle-bin features on Linux; there is no freedesktop
    // equivalent that matches the Windows semantics.
    RespondNotImplemented(method_call);
  } else {
    RespondNotImplemented(method_call);
  }
}

// --- broom/scan_priority ---------------------------------------------------

void HandlePriorityBegin(BroomChannels* channels, FlMethodCall* method_call) {
  errno = 0;
  const int current = getpriority(PRIO_PROCESS, 0);
  if (errno != 0) {
    const int error_number = errno;
    RespondError(method_call, "getpriority_failed",
                 std::string("无法读取进程优先级：") +
                     std::strerror(error_number),
                 error_number);
    return;
  }

  if (!channels->priority_lowered) {
    channels->original_nice = current;
  }
  // Only ever lower the priority; raising it would need privileges and would
  // make the UI less responsive.
  const int target = current < 10 ? 10 : current;
  if (setpriority(PRIO_PROCESS, 0, target) != 0) {
    // Lowering priority is an optimization; a scan must still start.
    RespondSuccess(method_call, nullptr);
    return;
  }

  channels->priority_lowered = TRUE;
  g_autoptr(FlValue) result =
      fl_value_new_string("扫描期间已降低进程优先级（nice 10）");
  RespondSuccess(method_call, result);
}

void HandlePriorityEnd(BroomChannels* channels, FlMethodCall* method_call) {
  if (channels->priority_lowered) {
    const int ignored =
        setpriority(PRIO_PROCESS, 0, channels->original_nice);
    (void)ignored;
    channels->priority_lowered = FALSE;
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

void HandleApplyPosixMetadata(FlMethodCall* method_call, FlValue* args) {
  const std::string path = StringArgument(args, "path");
  if (path.empty()) {
    RespondError(method_call, "invalid_arguments", "缺少文件路径。", EINVAL);
    return;
  }

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
    if (utimensat(AT_FDCWD, path.c_str(), times, 0) != 0) {
      const int error_number = errno;
      RespondError(method_call, "utimensat_failed",
                   std::string("无法恢复文件时间：") +
                       std::strerror(error_number),
                   error_number);
      return;
    }
  }

  bool has_mode = false;
  const int64_t mode = IntArgument(args, "mode", &has_mode);
  if (has_mode) {
    if (chmod(path.c_str(), static_cast<mode_t>(mode)) != 0) {
      const int error_number = errno;
      RespondError(method_call, "chmod_failed",
                   std::string("无法恢复文件权限：") +
                       std::strerror(error_number),
                   error_number);
      return;
    }
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
  } else if (g_strcmp0(method, "deviceIds") == 0) {
    HandleDeviceIds(method_call, args);
  } else {
    RespondNotImplemented(method_call);
  }
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

void broom_register_native_channels(FlView* view, GtkWindow* window) {
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));

  auto* channels = g_new0(BroomChannels, 1);
  channels->window = window;
  channels->original_nice = 0;
  channels->priority_lowered = FALSE;
  // Handlers keep using the context while the view is alive.
  g_object_set_data_full(G_OBJECT(view), "broom-native-channels", channels,
                         g_free);

  RegisterChannel(messenger, kShellChannelName, ShellMethodCallHandler,
                  channels);
  RegisterChannel(messenger, kScanPriorityChannelName,
                  ScanPriorityMethodCallHandler, channels);
  RegisterChannel(messenger, kFileMetadataChannelName,
                  FileMetadataMethodCallHandler, channels);
}
