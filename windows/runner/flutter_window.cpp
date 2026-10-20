#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <optional>
#include <string>
#include <utility>

#include "directory_enum_channel.h"
#include "file_lock_channel.h"
#include "file_metadata_channel.h"
#include "flutter/generated_plugin_registrant.h"
#include "ntfs_index_channel.h"
#include "scan_priority_channel.h"
#include "system_access_channel.h"
#include "system_shell_channel.h"

namespace {

constexpr UINT_PTR kFlutterViewSubclassId = 1;
constexpr char kWindowChannelName[] = "broom/window";
constexpr char kWindowStateChannelName[] = "broom/window_state";

}  // namespace

// Tracks whether the window is maximized and pushes changes to Flutter so the
// custom title bar can swap its maximize and restore buttons.
class WindowStateEmitter
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit WindowStateEmitter(HWND window) : window_(window) {}

  void Notify() {
    if (!sink_) {
      return;
    }
    const bool maximized = window_ != nullptr && IsZoomed(window_) != FALSE;
    if (has_state_ && maximized == maximized_) {
      return;
    }
    maximized_ = maximized;
    has_state_ = true;
    sink_->Success(flutter::EncodableValue(maximized));
  }

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    sink_ = std::move(events);
    has_state_ = false;
    Notify();
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    sink_.reset();
    return nullptr;
  }

 private:
  HWND window_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  bool maximized_ = false;
  bool has_state_ = false;
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_view_ = flutter_controller_->view()->GetNativeWindow();
  SetWindowSubclass(flutter_view_, FlutterViewProc, kFlutterViewSubclassId,
                    reinterpret_cast<DWORD_PTR>(this));

  SetUpWindowChannels();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetUpWindowChannels() {
  auto* messenger = flutter_controller_->engine()->messenger();

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto state_emitter = std::make_unique<WindowStateEmitter>(GetHandle());
  window_state_emitter_ = state_emitter.get();
  window_state_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kWindowStateChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_state_channel_->SetStreamHandler(std::move(state_emitter));

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND window = GetHandle();
        if (window == nullptr) {
          result->Error("window_unavailable", "The window is not available.");
          return;
        }

        const std::string& method = call.method_name();
        if (method == "startDrag") {
          ReleaseCapture();
          SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
        } else if (method == "minimize") {
          ShowWindow(window, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(window, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "showSystemMenu") {
          HMENU menu = GetSystemMenu(window, FALSE);
          POINT cursor;
          GetCursorPos(&cursor);
          SetForegroundWindow(window);
          const UINT command = TrackPopupMenu(
              menu,
              TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RIGHTBUTTON,
              cursor.x, cursor.y, 0, window, nullptr);
          PostMessage(window, WM_NULL, 0, 0);
          if (command != 0) {
            PostMessage(window, WM_SYSCOMMAND, command, 0);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  system_shell_channel_ = std::make_unique<SystemShellChannel>(
      messenger, GetHandle());
  system_access_channel_ = std::make_unique<SystemAccessChannel>(messenger);
  file_metadata_channel_ = std::make_unique<FileMetadataChannel>(messenger);
  file_lock_channel_ = std::make_unique<FileLockChannel>(messenger);
  ntfs_index_channel_ =
      std::make_unique<NtfsIndexChannel>(messenger, GetHandle());
  directory_enum_channel_ =
      std::make_unique<DirectoryEnumChannel>(messenger, GetHandle());
  scan_priority_channel_ = std::make_unique<ScanPriorityChannel>(messenger);
}

void FlutterWindow::OnDestroy() {
  if (flutter_view_ != nullptr) {
    RemoveWindowSubclass(flutter_view_, FlutterViewProc,
                         kFlutterViewSubclassId);
    flutter_view_ = nullptr;
  }

  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_.reset();
  }

  if (window_state_channel_) {
    window_state_channel_->SetStreamHandler(nullptr);
    window_state_channel_.reset();
  }
  window_state_emitter_ = nullptr;

  system_access_channel_.reset();
  system_shell_channel_.reset();
  file_metadata_channel_.reset();
  file_lock_channel_.reset();
  ntfs_index_channel_.reset();
  directory_enum_channel_.reset();
  scan_priority_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT CALLBACK FlutterWindow::FlutterViewProc(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam,
                                                UINT_PTR subclass_id,
                                                DWORD_PTR ref_data) {
  if (message == WM_NCHITTEST) {
    const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    auto* self = reinterpret_cast<FlutterWindow*>(ref_data);
    if (self != nullptr && self->IsInResizeBorder(point)) {
      // Let the parent window resize itself at the edges of the client area.
      return HTTRANSPARENT;
    }
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // These messages describe the frame; Flutter should not interpret them as
  // window content messages.
  if (message == WM_NCCALCSIZE || message == WM_NCHITTEST ||
      message == WM_GETMINMAXINFO) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  if (message == WM_SIZE && wparam != SIZE_MINIMIZED &&
      window_state_emitter_ != nullptr) {
    window_state_emitter_->Notify();
  }

  if (message == NtfsIndexChannel::kPostedMessage) {
    if (ntfs_index_channel_ != nullptr) {
      ntfs_index_channel_->HandlePostedMessages();
    }
    return 0;
  }

  if (message == DirectoryEnumChannel::kPostedMessage) {
    if (directory_enum_channel_ != nullptr) {
      directory_enum_channel_->HandlePostedMessages();
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
