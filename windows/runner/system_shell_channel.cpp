#include "system_shell_channel.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <optional>
#include <string>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/shell";

std::wstring WideFromUtf8(const std::string& input) {
  if (input.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
      static_cast<int>(input.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring output(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                        static_cast<int>(input.size()), output.data(), length);
  return output;
}

std::string DescriptionForHResult(HRESULT hr) {
  wchar_t* buffer = nullptr;
  const DWORD length = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, static_cast<DWORD>(hr),
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
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

void SendShellError(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    const std::string& code,
    HRESULT hr) {
  const std::string description = DescriptionForHResult(hr);
  result->Error(code,
                description.empty() ? "Windows shell call failed."
                                    : description,
                flutter::EncodableValue(static_cast<int64_t>(hr)));
}

std::optional<std::string> StringArgument(const flutter::EncodableValue* args,
                                          const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (map == nullptr) {
    return std::nullopt;
  }
  const auto iterator = map->find(flutter::EncodableValue(key));
  if (iterator == map->end()) {
    return std::nullopt;
  }
  const auto* value = std::get_if<std::string>(&iterator->second);
  if (value == nullptr) {
    return std::nullopt;
  }
  return *value;
}

}  // namespace

SystemShellChannel::SystemShellChannel(flutter::BinaryMessenger* messenger,
                                       HWND window)
    : window_(window) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) { HandleMethodCall(call, std::move(result)); });
}

SystemShellChannel::~SystemShellChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void SystemShellChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "queryRecycleBin") {
    SHQUERYRBINFO info = {};
    info.cbSize = sizeof(info);
    const HRESULT hr = ::SHQueryRecycleBinW(nullptr, &info);
    if (FAILED(hr)) {
      SendShellError(std::move(result), "recycle_bin_query_failed", hr);
      return;
    }
    flutter::EncodableMap map;
    map[flutter::EncodableValue("itemCount")] =
        flutter::EncodableValue(static_cast<int64_t>(info.i64NumItems));
    map[flutter::EncodableValue("totalBytes")] =
        flutter::EncodableValue(static_cast<int64_t>(info.i64Size));
    result->Success(flutter::EncodableValue(map));
    return;
  }

  if (method == "emptyRecycleBin") {
    const HRESULT hr = ::SHEmptyRecycleBinW(
        window_, nullptr,
        SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
    if (FAILED(hr)) {
      SendShellError(std::move(result), "recycle_bin_empty_failed", hr);
      return;
    }
    result->Success();
    return;
  }

  if (method == "pickFolder") {
    Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
    HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(dialog.GetAddressOf()));
    if (FAILED(hr)) {
      SendShellError(std::move(result), "folder_picker_failed", hr);
      return;
    }

    FILEOPENDIALOGOPTIONS options = 0;
    if (SUCCEEDED(dialog->GetOptions(&options))) {
      dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                         FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
    }
    dialog->SetTitle(L"选择要分析的文件夹");

    const auto initial_directory = StringArgument(call.arguments(),
                                                  "initialDirectory");
    if (initial_directory.has_value() && !initial_directory->empty()) {
      Microsoft::WRL::ComPtr<IShellItem> folder;
      const std::wstring initial = WideFromUtf8(*initial_directory);
      if (!initial.empty() &&
          SUCCEEDED(::SHCreateItemFromParsingName(
              initial.c_str(), nullptr, IID_PPV_ARGS(folder.GetAddressOf())))) {
        dialog->SetFolder(folder.Get());
      }
    }

    hr = dialog->Show(window_);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      result->Success();
      return;
    }
    if (FAILED(hr)) {
      SendShellError(std::move(result), "folder_picker_failed", hr);
      return;
    }

    Microsoft::WRL::ComPtr<IShellItem> selected;
    hr = dialog->GetResult(selected.GetAddressOf());
    if (FAILED(hr)) {
      SendShellError(std::move(result), "folder_picker_failed", hr);
      return;
    }

    PWSTR path = nullptr;
    hr = selected->GetDisplayName(SIGDN_FILESYSPATH, &path);
    if (FAILED(hr) || path == nullptr) {
      if (path != nullptr) {
        ::CoTaskMemFree(path);
      }
      SendShellError(std::move(result), "folder_picker_failed", hr);
      return;
    }
    const std::string utf8_path = Utf8FromUtf16(path);
    ::CoTaskMemFree(path);
    result->Success(flutter::EncodableValue(utf8_path));
    return;
  }

  if (method == "revealPath") {
    const auto path = StringArgument(call.arguments(), "path");
    if (!path.has_value() || path->empty()) {
      result->Error("invalid_path", "A file path is required.");
      return;
    }
    const std::wstring wide_path = WideFromUtf8(*path);
    if (wide_path.empty()) {
      result->Error("invalid_path", "The file path is not valid UTF-8.");
      return;
    }
    PIDLIST_ABSOLUTE item = ::ILCreateFromPathW(wide_path.c_str());
    if (item == nullptr) {
      result->Error("path_not_found", "The file no longer exists.");
      return;
    }
    const HRESULT hr = ::SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    ::ILFree(item);
    if (FAILED(hr)) {
      SendShellError(std::move(result), "reveal_failed", hr);
      return;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}
