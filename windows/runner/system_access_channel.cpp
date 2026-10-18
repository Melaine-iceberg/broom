#include "system_access_channel.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shellapi.h>

#include <string>
#include <vector>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/system";

bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation = {};
  DWORD returned = 0;
  const BOOL ok =
      ::GetTokenInformation(token, TokenElevation, &elevation,
                            sizeof(elevation), &returned);
  ::CloseHandle(token);
  return ok != FALSE && elevation.TokenIsElevated != 0;
}

std::wstring ExecutablePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  while (true) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < buffer.size()) {
      buffer.resize(length);
      return buffer;
    }
    buffer.resize(buffer.size() * 2);
  }
}

std::wstring DirectoryOf(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  return path.substr(0, separator);
}

std::wstring WindowsDirectory() {
  const UINT required = ::GetWindowsDirectoryW(nullptr, 0);
  if (required == 0) {
    return std::wstring();
  }
  std::vector<wchar_t> buffer(static_cast<size_t>(required) + 1, L'\0');
  const UINT length = ::GetWindowsDirectoryW(
      buffer.data(), static_cast<UINT>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    return std::wstring();
  }
  return std::wstring(buffer.data(), length);
}

std::wstring KnownFolderPath(REFKNOWNFOLDERID folder_id) {
  PWSTR path = nullptr;
  const HRESULT hr =
      ::SHGetKnownFolderPath(folder_id, KF_FLAG_DEFAULT, nullptr, &path);
  if (FAILED(hr) || path == nullptr) {
    if (path != nullptr) {
      ::CoTaskMemFree(path);
    }
    return std::wstring();
  }
  std::wstring result(path);
  ::CoTaskMemFree(path);
  return result;
}

std::string DescriptionForError(DWORD error) {
  wchar_t* buffer = nullptr;
  const DWORD length = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  if (length == 0 || buffer == nullptr) {
    return std::string();
  }
  std::string description = Utf8FromUtf16(buffer);
  ::LocalFree(buffer);
  while (!description.empty() &&
         (description.back() == '\r' || description.back() == '\n' ||
          description.back() == ' ')) {
    description.pop_back();
  }
  return description;
}

void SendWindowsError(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    const std::string& code, DWORD error) {
  const std::string description = DescriptionForError(error);
  result->Error(code,
                description.empty() ? "Windows API call failed."
                                    : description,
                flutter::EncodableValue(static_cast<int64_t>(error)));
}

void SendSystemCacheRoots(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::wstring windows_dir = WindowsDirectory();
  if (windows_dir.empty()) {
    SendWindowsError(std::move(result), "system_cache_roots_failed",
                     ::GetLastError());
    return;
  }

  const std::wstring program_data =
      KnownFolderPath(FOLDERID_ProgramData);
  if (program_data.empty()) {
    SendWindowsError(std::move(result), "system_cache_roots_failed",
                     ERROR_PATH_NOT_FOUND);
    return;
  }

  const std::wstring update_cache =
      windows_dir + L"\\SoftwareDistribution\\Download";
  const std::wstring delivery_cache =
      program_data + L"\\Microsoft\\Windows\\DeliveryOptimization\\Cache";

  flutter::EncodableMap map;
  map[flutter::EncodableValue("windowsUpdate")] =
      flutter::EncodableValue(Utf8FromUtf16(update_cache.c_str()));
  map[flutter::EncodableValue("deliveryOptimization")] =
      flutter::EncodableValue(Utf8FromUtf16(delivery_cache.c_str()));
  result->Success(flutter::EncodableValue(map));
}

}  // namespace

SystemAccessChannel::SystemAccessChannel(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) { HandleMethodCall(call, std::move(result)); });
}

SystemAccessChannel::~SystemAccessChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void SystemAccessChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "isElevated") {
    result->Success(flutter::EncodableValue(IsProcessElevated()));
    return;
  }

  if (method == "relaunchElevated") {
    if (IsProcessElevated()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }

    const std::wstring executable = ExecutablePath();
    if (executable.empty()) {
      SendWindowsError(std::move(result), "elevation_failed",
                       ::GetLastError());
      return;
    }

    const std::wstring directory = DirectoryOf(executable);
    SHELLEXECUTEINFOW info = {};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
    info.lpVerb = L"runas";
    info.lpFile = executable.c_str();
    info.lpParameters = L"--system-cache";
    info.lpDirectory = directory.empty() ? nullptr : directory.c_str();
    info.nShow = SW_SHOWNORMAL;

    if (!::ShellExecuteExW(&info)) {
      const DWORD error = ::GetLastError();
      if (error == ERROR_CANCELLED) {
        result->Error("elevation_cancelled",
                      "The user cancelled the UAC prompt.",
                      flutter::EncodableValue(static_cast<int64_t>(error)));
      } else {
        SendWindowsError(std::move(result), "elevation_failed", error);
      }
      return;
    }

    if (info.hProcess != nullptr) {
      ::CloseHandle(info.hProcess);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "systemCacheRoots") {
    SendSystemCacheRoots(std::move(result));
    return;
  }

  result->NotImplemented();
}
