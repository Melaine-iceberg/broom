#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// Window attribute that controls whether DWM rounds the window corners.
/// Ignored by Windows 10.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

constexpr DWORD kDwmWindowCornerRound = 2;
constexpr int kMinimumWindowWidth = 760;
constexpr int kMinimumWindowHeight = 540;

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

UINT DpiOf(HWND window) {
  const UINT dpi = GetDpiForWindow(window);
  return dpi == 0 ? 96 : dpi;
}

int ResizeBorderWidth(HWND window) {
  const UINT dpi = DpiOf(window);
  return GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

int ResizeBorderHeight(HWND window) {
  const UINT dpi = DpiOf(window);
  return GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

// The custom title bar (lib/ui/window_title_bar.dart) ends with three 46x38
// logical-pixel slots; the maximize/restore button is the middle slot. Report
// that area as the native non-client button so Windows 11 renders the Snap
// Layouts flyout on hover.
bool IsPointInMaximizeButton(HWND window, const POINT& point) {
  RECT client = {};
  if (!GetClientRect(window, &client)) {
    return false;
  }

  POINT origin = {0, 0};
  ClientToScreen(window, &origin);

  const UINT dpi = DpiOf(window);
  const LONG left = origin.x + client.right - MulDiv(92, dpi, 96);
  const LONG right = left + MulDiv(46, dpi, 96);
  const LONG top = origin.y + MulDiv(5, dpi, 96);
  const LONG bottom = top + MulDiv(28, dpi, 96);

  return point.x >= left && point.x < right && point.y >= top &&
         point.y < bottom;
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  const DWORD corner_preference = kDwmWindowCornerRound;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE: {
      RECT client = {};
      bool has_client = false;
      if (IsZoomed(hwnd)) {
        MONITORINFO monitor_info = {sizeof(MONITORINFO)};
        const HMONITOR monitor =
            MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (GetMonitorInfo(monitor, &monitor_info)) {
          client = monitor_info.rcWork;
          has_client = true;
        }
      }

      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      if (!has_client) {
        if (wparam) {
          client = params->rgrc[0];
        } else {
          GetWindowRect(hwnd, &client);
        }
      }

      if (wparam) {
        params->rgrc[0] = client;
      } else {
        *reinterpret_cast<RECT*>(lparam) = client;
      }
      return 0;
    }

    case WM_NCHITTEST: {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};

      // Windows 11 keys its Snap Layouts flyout off this hit-test result.
      if (IsPointInMaximizeButton(hwnd, point)) {
        return HTMAXBUTTON;
      }

      if (IsZoomed(hwnd)) {
        return HTCLIENT;
      }

      RECT rect;
      GetWindowRect(hwnd, &rect);

      const int border_x = ResizeBorderWidth(hwnd);
      const int border_y = ResizeBorderHeight(hwnd);
      const bool on_left = point.x >= rect.left && point.x < rect.left + border_x;
      const bool on_right =
          point.x >= rect.right - border_x && point.x < rect.right;
      const bool on_top = point.y >= rect.top && point.y < rect.top + border_y;
      const bool on_bottom =
          point.y >= rect.bottom - border_y && point.y < rect.bottom;

      if (on_top && on_left) return HTTOPLEFT;
      if (on_top && on_right) return HTTOPRIGHT;
      if (on_bottom && on_left) return HTBOTTOMLEFT;
      if (on_bottom && on_right) return HTBOTTOMRIGHT;
      if (on_top) return HTTOP;
      if (on_bottom) return HTBOTTOM;
      if (on_left) return HTLEFT;
      if (on_right) return HTRIGHT;
      return HTCLIENT;
    }

    case WM_NCLBUTTONDOWN:
      if (static_cast<int>(wparam) == HTMAXBUTTON) {
        // The caption lives in the client area, so DefWindowProc does not
        // perform the button's default action for us.
        PostMessage(hwnd, WM_SYSCOMMAND,
                    IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        return 0;
      }
      break;

    case WM_NCLBUTTONUP:
      if (static_cast<int>(wparam) == HTMAXBUTTON) {
        return 0;
      }
      break;

    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = DpiOf(hwnd);
      info->ptMinTrackSize.x = MulDiv(kMinimumWindowWidth, dpi, 96);
      info->ptMinTrackSize.y = MulDiv(kMinimumWindowHeight, dpi, 96);
      return 0;
    }

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

bool Win32Window::IsInResizeBorder(const POINT& screen_point) const {
  if (window_handle_ == nullptr || IsZoomed(window_handle_)) {
    return false;
  }

  RECT rect;
  GetWindowRect(window_handle_, &rect);
  const int border_x = ResizeBorderWidth(window_handle_);
  const int border_y = ResizeBorderHeight(window_handle_);
  const bool on_left = screen_point.x >= rect.left &&
                       screen_point.x < rect.left + border_x;
  const bool on_right = screen_point.x >= rect.right - border_x &&
                        screen_point.x < rect.right;
  const bool on_top = screen_point.y >= rect.top &&
                      screen_point.y < rect.top + border_y;
  const bool on_bottom = screen_point.y >= rect.bottom - border_y &&
                         screen_point.y < rect.bottom;
  return on_left || on_right || on_top || on_bottom;
}

bool Win32Window::IsOverMaximizeButton(const POINT& screen_point) const {
  if (window_handle_ == nullptr) {
    return false;
  }
  return IsPointInMaximizeButton(window_handle_, screen_point);
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
