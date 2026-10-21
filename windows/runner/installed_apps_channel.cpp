#include "installed_apps_channel.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <cwchar>
#include <cwctype>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/apps";
constexpr DWORD kMaxApps = 10000;
constexpr DWORD kMaxKeyNameLength = 256;

struct RegistrySource {
  HKEY hive;
  const wchar_t* hive_label;
  const wchar_t* path;
  const char* scope;
  REGSAM view;
};

const RegistrySource kSources[] = {
    {HKEY_CURRENT_USER, L"HKCU",
     L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "user",
     KEY_WOW64_64KEY},
    {HKEY_CURRENT_USER, L"HKCU",
     L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "user",
     KEY_WOW64_32KEY},
    {HKEY_LOCAL_MACHINE, L"HKLM",
     L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "machine",
     KEY_WOW64_64KEY},
    {HKEY_LOCAL_MACHINE, L"HKLM",
     L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", "machine",
     KEY_WOW64_32KEY},
};

class ScopedRegKey {
 public:
  explicit ScopedRegKey(HKEY key) : key_(key) {}

  ~ScopedRegKey() {
    if (key_ != nullptr) {
      ::RegCloseKey(key_);
    }
  }

  ScopedRegKey(const ScopedRegKey&) = delete;
  ScopedRegKey& operator=(const ScopedRegKey&) = delete;

  HKEY get() const { return key_; }

 private:
  HKEY key_;
};

struct StringValue {
  std::wstring value;
  LSTATUS status = ERROR_SUCCESS;
};

struct CaseInsensitiveLess {
  bool operator()(const std::wstring& left, const std::wstring& right) const {
    return _wcsicmp(left.c_str(), right.c_str()) < 0;
  }
};

struct InventoryResult {
  std::vector<flutter::EncodableValue> apps;
  std::set<std::wstring, CaseInsensitiveLess> seen;
  bool complete = true;
  std::string error;
};

bool IsMissingKey(LSTATUS status) {
  return status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND;
}

std::string Utf8(const std::wstring& value) {
  return Utf8FromUtf16(value.c_str());
}

std::string ErrorFor(const RegistrySource& source, LSTATUS status) {
  return "Failed to read " + Utf8(source.hive_label) + "\\" +
         Utf8(source.path) + " (Windows error " +
         std::to_string(static_cast<int>(status)) + ")";
}

StringValue ReadStringValue(HKEY key, const wchar_t* name) {
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status =
      ::RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (status != ERROR_SUCCESS) {
    return {std::wstring(), status};
  }
  if (type != REG_SZ && type != REG_EXPAND_SZ) {
    return {std::wstring(), ERROR_SUCCESS};
  }

  std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
  DWORD read = size;
  status = ::RegQueryValueExW(
      key, name, nullptr, &type,
      reinterpret_cast<LPBYTE>(buffer.data()), &read);
  if (status != ERROR_SUCCESS) {
    return {std::wstring(), status};
  }

  size_t length = read / sizeof(wchar_t);
  while (length > 0 && buffer[length - 1] == L'\0') {
    --length;
  }
  return {std::wstring(buffer.data(), length), ERROR_SUCCESS};
}

std::wstring Trim(std::wstring value) {
  const auto first = std::find_if_not(
      value.begin(), value.end(),
      [](wchar_t character) { return std::iswspace(character) != 0; });
  if (first == value.end()) {
    return std::wstring();
  }
  const auto last = std::find_if_not(
                        value.rbegin(), value.rend(),
                        [](wchar_t character) {
                          return std::iswspace(character) != 0;
                        })
                        .base();
  return std::wstring(first, last);
}

std::optional<std::wstring> ReadTrimmed(HKEY key, const wchar_t* name) {
  const StringValue value = ReadStringValue(key, name);
  if (value.status != ERROR_SUCCESS) {
    return std::nullopt;
  }
  std::wstring trimmed = Trim(value.value);
  if (trimmed.empty()) {
    return std::nullopt;
  }
  return trimmed;
}

flutter::EncodableMap BuildApp(
    const std::wstring& display_name,
    const std::optional<std::wstring>& publisher,
    const std::optional<std::wstring>& install_location,
    const std::wstring& uninstall_key,
    const std::string& scope) {
  flutter::EncodableMap app;
  app[flutter::EncodableValue("displayName")] =
      flutter::EncodableValue(Utf8(display_name));
  if (publisher) {
    app[flutter::EncodableValue("publisher")] =
        flutter::EncodableValue(Utf8(*publisher));
  }
  if (install_location) {
    app[flutter::EncodableValue("installLocation")] =
        flutter::EncodableValue(Utf8(*install_location));
  }
  app[flutter::EncodableValue("uninstallKey")] =
      flutter::EncodableValue(Utf8(uninstall_key));
  app[flutter::EncodableValue("scope")] =
      flutter::EncodableValue(std::string(scope));
  return app;
}

void RecordError(InventoryResult* result,
                 const RegistrySource& source,
                 LSTATUS status) {
  result->complete = false;
  if (result->error.empty()) {
    result->error = ErrorFor(source, status);
  }
}

// Uninstall keys are small and bounded, so this stays on the platform thread.
// The entry cap protects against pathological or corrupt registries.
void CollectSource(const RegistrySource& source, InventoryResult* result) {
  HKEY raw_key = nullptr;
  const LSTATUS open_status = ::RegOpenKeyExW(
      source.hive, source.path, 0, KEY_READ | source.view, &raw_key);
  if (open_status != ERROR_SUCCESS) {
    if (!IsMissingKey(open_status)) {
      RecordError(result, source, open_status);
    }
    return;
  }
  ScopedRegKey key(raw_key);

  DWORD index = 0;
  while (true) {
    wchar_t name[kMaxKeyNameLength] = {};
    DWORD name_length = kMaxKeyNameLength;
    const LSTATUS status = ::RegEnumKeyExW(
        key.get(), index++, name, &name_length, nullptr, nullptr, nullptr,
        nullptr);
    if (status == ERROR_NO_MORE_ITEMS) {
      break;
    }
    if (status != ERROR_SUCCESS) {
      RecordError(result, source, status);
      break;
    }

    const std::wstring key_name(name, name_length);
    const std::wstring dedupe_key =
        std::wstring(source.hive_label) + L"\\" + key_name;
    if (result->seen.find(dedupe_key) != result->seen.end()) {
      continue;
    }

    HKEY raw_subkey = nullptr;
    const LSTATUS subkey_status = ::RegOpenKeyExW(
        key.get(), key_name.c_str(), 0, KEY_READ | source.view, &raw_subkey);
    if (subkey_status != ERROR_SUCCESS) {
      if (!IsMissingKey(subkey_status)) {
        RecordError(result, source, subkey_status);
      }
      continue;
    }
    ScopedRegKey subkey(raw_subkey);

    const StringValue display_name =
        ReadStringValue(subkey.get(), L"DisplayName");
    if (display_name.status != ERROR_SUCCESS) {
      if (!IsMissingKey(display_name.status)) {
        RecordError(result, source, display_name.status);
      }
      continue;
    }
    const std::wstring display = Trim(display_name.value);
    if (display.empty()) {
      continue;
    }

    if (result->apps.size() >= kMaxApps) {
      result->complete = false;
      if (result->error.empty()) {
        result->error =
            "Installed application inventory exceeded the safety limit.";
      }
      return;
    }

    result->seen.insert(dedupe_key);
    const auto publisher = ReadTrimmed(subkey.get(), L"Publisher");
    const auto install_location =
        ReadTrimmed(subkey.get(), L"InstallLocation");
    const std::wstring uninstall_key = std::wstring(source.hive_label) +
                                       L"\\" + source.path + L"\\" + key_name;
    result->apps.push_back(flutter::EncodableValue(
        BuildApp(display, publisher, install_location, uninstall_key,
                 source.scope)));
  }
}

}  // namespace

InstalledAppsChannel::InstalledAppsChannel(
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

InstalledAppsChannel::~InstalledAppsChannel() {
  channel_->SetMethodCallHandler(nullptr);
}

void InstalledAppsChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "list") {
    result->NotImplemented();
    return;
  }

  InventoryResult inventory;
  inventory.apps.reserve(128);
  for (const auto& source : kSources) {
    CollectSource(source, &inventory);
    if (inventory.apps.size() >= kMaxApps) {
      break;
    }
  }

  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("complete")] =
      flutter::EncodableValue(inventory.complete);
  payload[flutter::EncodableValue("apps")] =
      flutter::EncodableValue(inventory.apps);
  if (!inventory.error.empty()) {
    payload[flutter::EncodableValue("error")] =
        flutter::EncodableValue(inventory.error);
  }
  result->Success(flutter::EncodableValue(payload));
}
