#include "file_metadata_channel.h"

#include <aclapi.h>
#include <flutter/standard_method_codec.h>
#include <sddl.h>
#include <windows.h>

#include <optional>
#include <string>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/file_metadata";

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
                description.empty() ? "Windows metadata call failed."
                                    : description,
                flutter::EncodableValue(static_cast<int64_t>(error)));
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

std::optional<int64_t> Int64Argument(const flutter::EncodableValue* args,
                                     const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (map == nullptr) {
    return std::nullopt;
  }
  const auto iterator = map->find(flutter::EncodableValue(key));
  if (iterator == map->end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return static_cast<int64_t>(*value);
  }
  return std::nullopt;
}

std::optional<bool> BoolArgument(const flutter::EncodableValue* args,
                                 const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (map == nullptr) {
    return std::nullopt;
  }
  const auto iterator = map->find(flutter::EncodableValue(key));
  if (iterator == map->end()) {
    return std::nullopt;
  }
  const auto* value = std::get_if<bool>(&iterator->second);
  if (value == nullptr) {
    return std::nullopt;
  }
  return *value;
}

bool ToFileTime(int64_t value, FILETIME* out) {
  if (value < 0) {
    return false;
  }
  ULARGE_INTEGER ticks;
  ticks.QuadPart = static_cast<ULONGLONG>(value);
  out->dwLowDateTime = ticks.LowPart;
  out->dwHighDateTime = ticks.HighPart;
  return true;
}

DWORD ApplyFileTimes(const std::wstring& path, const FILETIME* created,
                     const FILETIME* accessed, const FILETIME* modified) {
  if (created == nullptr && accessed == nullptr && modified == nullptr) {
    return ERROR_SUCCESS;
  }
  HANDLE handle = ::CreateFileW(
      path.c_str(), FILE_WRITE_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    return ::GetLastError();
  }
  const BOOL ok = ::SetFileTime(handle, created, accessed, modified);
  const DWORD error = ok ? ERROR_SUCCESS : ::GetLastError();
  ::CloseHandle(handle);
  return error;
}

DWORD ApplyReadOnly(const std::wstring& path, bool read_only) {
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return ::GetLastError();
  }
  const DWORD desired = read_only
                            ? (attributes | FILE_ATTRIBUTE_READONLY)
                            : (attributes & ~FILE_ATTRIBUTE_READONLY);
  if (desired == attributes) {
    return ERROR_SUCCESS;
  }
  return ::SetFileAttributesW(path.c_str(), desired) ? ERROR_SUCCESS
                                                     : ::GetLastError();
}

struct DaclResult {
  bool ok = false;
  bool present = false;
  std::string sddl;
  DWORD error = ERROR_SUCCESS;
};

DaclResult ReadDacl(const std::wstring& path) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  PACL dacl = nullptr;
  std::wstring mutable_path = path;
  const DWORD error = ::GetNamedSecurityInfoW(
      mutable_path.data(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr,
      nullptr, &dacl, nullptr, &descriptor);
  if (error != ERROR_SUCCESS) {
    return DaclResult{false, false, std::string(), error};
  }
  if (dacl == nullptr) {
    ::LocalFree(descriptor);
    return DaclResult{true, false, std::string(), ERROR_SUCCESS};
  }

  LPWSTR sddl = nullptr;
  if (!::ConvertSecurityDescriptorToStringSecurityDescriptorW(
          descriptor, SDDL_REVISION_1, DACL_SECURITY_INFORMATION, &sddl,
          nullptr)) {
    const DWORD conversion_error = ::GetLastError();
    ::LocalFree(descriptor);
    return DaclResult{false, false, std::string(), conversion_error};
  }
  std::string value = Utf8FromUtf16(sddl);
  ::LocalFree(sddl);
  ::LocalFree(descriptor);
  if (value.empty()) {
    return DaclResult{false, false, std::string(), ERROR_INVALID_DATA};
  }
  return DaclResult{true, true, value, ERROR_SUCCESS};
}

DWORD ApplyDacl(const std::wstring& path, const std::string& sddl) {
  const std::wstring wide_sddl = WideFromUtf8(sddl);
  if (wide_sddl.empty()) {
    return ERROR_INVALID_DATA;
  }

  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
          wide_sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
    return ::GetLastError();
  }

  BOOL present = FALSE;
  PACL dacl = nullptr;
  BOOL defaulted = FALSE;
  if (!::GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) ||
      !present || dacl == nullptr) {
    ::LocalFree(descriptor);
    return ERROR_INVALID_ACL;
  }

  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  ::GetSecurityDescriptorControl(descriptor, &control, &revision);
  SECURITY_INFORMATION information = DACL_SECURITY_INFORMATION;
  information |= (control & SE_DACL_PROTECTED)
                     ? PROTECTED_DACL_SECURITY_INFORMATION
                     : UNPROTECTED_DACL_SECURITY_INFORMATION;

  std::wstring mutable_path = path;
  const DWORD error = ::SetNamedSecurityInfoW(
      mutable_path.data(), SE_FILE_OBJECT, information, nullptr, nullptr, dacl,
      nullptr);
  ::LocalFree(descriptor);
  return error;
}

}  // namespace

FileMetadataChannel::FileMetadataChannel(
    flutter::BinaryMessenger* messenger) {
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

FileMetadataChannel::~FileMetadataChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void FileMetadataChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

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

  if (method == "readAcl") {
    const DaclResult dacl = ReadDacl(wide_path);
    if (!dacl.ok) {
      SendWindowsError(std::move(result), "acl_read_failed", dacl.error);
      return;
    }
    if (!dacl.present) {
      result->Success();
      return;
    }
    result->Success(flutter::EncodableValue(dacl.sddl));
    return;
  }

  if (method == "applyMetadata") {
    DWORD first_error = ERROR_SUCCESS;

    FILETIME created = {};
    FILETIME accessed = {};
    FILETIME modified = {};
    FILETIME* created_ptr = nullptr;
    FILETIME* accessed_ptr = nullptr;
    FILETIME* modified_ptr = nullptr;
    if (const auto value = Int64Argument(call.arguments(), "created")) {
      if (ToFileTime(*value, &created)) {
        created_ptr = &created;
      }
    }
    if (const auto value = Int64Argument(call.arguments(), "accessed")) {
      if (ToFileTime(*value, &accessed)) {
        accessed_ptr = &accessed;
      }
    }
    if (const auto value = Int64Argument(call.arguments(), "modified")) {
      if (ToFileTime(*value, &modified)) {
        modified_ptr = &modified;
      }
    }
    const DWORD times_error =
        ApplyFileTimes(wide_path, created_ptr, accessed_ptr, modified_ptr);
    if (times_error != ERROR_SUCCESS) {
      first_error = times_error;
    }

    const auto acl = StringArgument(call.arguments(), "acl");
    if (acl.has_value() && !acl->empty()) {
      const DWORD acl_error = ApplyDacl(wide_path, *acl);
      if (acl_error != ERROR_SUCCESS && first_error == ERROR_SUCCESS) {
        first_error = acl_error;
      }
    }

    if (const auto read_only = BoolArgument(call.arguments(), "readOnly")) {
      const DWORD attributes_error = ApplyReadOnly(wide_path, *read_only);
      if (attributes_error != ERROR_SUCCESS && first_error == ERROR_SUCCESS) {
        first_error = attributes_error;
      }
    }

    if (first_error != ERROR_SUCCESS) {
      SendWindowsError(std::move(result), "metadata_apply_failed", first_error);
      return;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}
