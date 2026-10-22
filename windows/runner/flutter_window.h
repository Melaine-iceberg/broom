#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

class WindowStateEmitter;
class DirectoryEnumChannel;
class SystemShellChannel;
class SystemAccessChannel;
class FileMetadataChannel;
class FileLockChannel;
class NtfsIndexChannel;
class ScanPriorityChannel;
class InstalledAppsChannel;

namespace flutter {
class EncodableValue;
template <typename T>
class EventChannel;
template <typename T>
class MethodChannel;
}  // namespace flutter

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Lets the parent window handle edge resize hit tests that fall outside the
  // Flutter view's content.
  static LRESULT CALLBACK FlutterViewProc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam,
                                          UINT_PTR subclass_id,
                                          DWORD_PTR ref_data);

  void SetUpWindowChannels();

  // Pushes the maximize button's non-client hover state to Flutter.
  void SetMaximizeHover(bool hovered);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  HWND flutter_view_ = nullptr;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      window_state_channel_;
  // Owned by |window_state_channel_| once its stream handler is installed.
  WindowStateEmitter* window_state_emitter_ = nullptr;

  bool maximize_hovered_ = false;

  std::unique_ptr<SystemShellChannel> system_shell_channel_;
  std::unique_ptr<SystemAccessChannel> system_access_channel_;
  std::unique_ptr<FileMetadataChannel> file_metadata_channel_;
  std::unique_ptr<FileLockChannel> file_lock_channel_;
  std::unique_ptr<NtfsIndexChannel> ntfs_index_channel_;
  std::unique_ptr<DirectoryEnumChannel> directory_enum_channel_;
  std::unique_ptr<ScanPriorityChannel> scan_priority_channel_;
  std::unique_ptr<InstalledAppsChannel> installed_apps_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
