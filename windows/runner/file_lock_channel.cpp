#include "file_lock_channel.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <string>
#include <vector>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/file_lock";

// A sharing or lock violation means an existing handle does not allow the
// delete access Broom needs for move/restore, so report it as possibly in use.
// Access-denied and missing-file errors are not lock indicators.
bool PossiblyLocked(const std::wstring& path) {
  HANDLE handle = ::CreateFileW(
      ToExtendedWindowsPath(path).c_str(), DELETE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    const DWORD error = ::GetLastError();
    return error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION;
  }
  ::CloseHandle(handle);
  return false;
}

}  // namespace

FileLockChannel::FileLockChannel(flutter::BinaryMessenger* messenger) {
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

FileLockChannel::~FileLockChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void FileLockChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "probe") {
    result->NotImplemented();
    return;
  }

  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_arguments", "A path list is required.");
    return;
  }
  const auto paths_it = arguments->find(flutter::EncodableValue("paths"));
  if (paths_it == arguments->end()) {
    result->Error("invalid_arguments", "A path list is required.");
    return;
  }
  const auto* paths = std::get_if<flutter::EncodableList>(&paths_it->second);
  if (paths == nullptr) {
    result->Error("invalid_arguments", "The path list is malformed.");
    return;
  }

  flutter::EncodableList results;
  results.reserve(paths->size());
  for (const auto& value : *paths) {
    const auto* path = std::get_if<std::string>(&value);
    if (path == nullptr || path->empty()) {
      results.emplace_back(false);
      continue;
    }
    const std::wstring wide_path = Utf16FromUtf8(*path);
    results.emplace_back(!wide_path.empty() && PossiblyLocked(wide_path));
  }

  result->Success(flutter::EncodableValue(results));
}
