#include "ntfs_index_channel.h"

#include <flutter/standard_method_codec.h>
#include <winioctl.h>

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <deque>
#include <exception>
#include <system_error>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/ntfs_index";
constexpr size_t kEnumBufferBytes = 1 << 20;
constexpr size_t kBatchSize = 512;
constexpr size_t kMaxIndexedRecords = 2000000;
constexpr auto kVolumeCacheAge = std::chrono::minutes(5);
constexpr auto kProbeCacheAge = std::chrono::minutes(1);

#ifndef ERROR_JOURNAL_NOT_ACTIVE
#define ERROR_JOURNAL_NOT_ACTIVE 1179L
#endif

std::wstring ToLowerW(std::wstring value) {
  if (!value.empty()) {
    ::CharLowerBuffW(value.data(), static_cast<DWORD>(value.size()));
  }
  return value;
}

std::string ErrorMessage(DWORD error) {
  wchar_t* buffer = nullptr;
  const DWORD length = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  if (length == 0 || buffer == nullptr) {
    return "Win32 error " + std::to_string(error);
  }
  std::string message = Utf8FromUtf16(buffer);
  ::LocalFree(buffer);
  while (!message.empty() &&
         (message.back() == '\r' || message.back() == '\n' ||
          message.back() == ' ')) {
    message.pop_back();
  }
  return message;
}

std::wstring StripExtendedPrefix(std::wstring path) {
  if (path.rfind(L"\\\\?\\UNC\\", 0) == 0) {
    return L"\\\\" + path.substr(8);
  }
  if (path.rfind(L"\\\\?\\", 0) == 0) {
    return path.substr(4);
  }
  return path;
}

bool VolumeRootFor(const std::wstring& path, std::wstring* volume_root) {
  std::vector<wchar_t> buffer(MAX_PATH);
  DWORD length = ::GetVolumePathNameW(
      path.c_str(), buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0) {
    const std::wstring extended = ToExtendedWindowsPath(path);
    length = ::GetVolumePathNameW(
        extended.c_str(), buffer.data(), static_cast<DWORD>(buffer.size()));
  }
  if (length == 0) return false;
  *volume_root = StripExtendedPrefix(std::wstring(buffer.data(), length));
  return true;
}

bool DevicePathForVolume(const std::wstring& volume_root,
                         std::wstring* device_path) {
  // USN enumeration is only implemented for local drive-letter volumes. UNC
  // shares and mounted-folder volumes fall back to directory traversal.
  if (volume_root.size() < 3 || volume_root[1] != L':' ||
      (volume_root[2] != L'\\' && volume_root[2] != L'/')) {
    return false;
  }
  *device_path =
      std::wstring(L"\\\\.\\") + volume_root.substr(0, 2);
  return true;
}

bool IsNtfsVolume(const std::wstring& volume_root) {
  wchar_t filesystem[MAX_PATH] = {};
  if (!::GetVolumeInformationW(volume_root.c_str(), nullptr, 0, nullptr,
                               nullptr, nullptr, filesystem, MAX_PATH)) {
    return false;
  }
  return _wcsicmp(filesystem, L"NTFS") == 0;
}

HANDLE OpenVolume(const std::wstring& device_path, DWORD* error) {
  HANDLE handle = ::CreateFileW(
      device_path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, 0, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    *error = ::GetLastError();
    return INVALID_HANDLE_VALUE;
  }
  return handle;
}

bool QueryJournal(HANDLE volume, USN_JOURNAL_DATA_V0* journal, DWORD* error) {
  DWORD returned = 0;
  const BOOL ok = ::DeviceIoControl(
      volume, FSCTL_QUERY_USN_JOURNAL, nullptr, 0, journal, sizeof(*journal),
      &returned, nullptr);
  if (!ok) {
    *error = ::GetLastError();
    return false;
  }
  return true;
}

bool FileIdForPath(const std::wstring& path, uint64_t* file_id) {
  HANDLE handle = ::CreateFileW(
      ToExtendedWindowsPath(path).c_str(), 0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  const BOOL ok = ::GetFileInformationByHandle(handle, &info);
  ::CloseHandle(handle);
  if (!ok) return false;
  *file_id = (static_cast<uint64_t>(info.nFileIndexHigh) << 32) |
             static_cast<uint64_t>(info.nFileIndexLow);
  return true;
}

std::wstring JoinPath(const std::wstring& parent, const std::wstring& name) {
  if (parent.empty()) return name;
  if (parent.back() == L'\\' || parent.back() == L'/') {
    return parent + name;
  }
  return parent + L"\\" + name;
}

std::wstring ExtensionOf(const std::wstring& name) {
  const size_t separator = name.find_last_of(L"\\/");
  const size_t dot = name.find_last_of(L'.');
  if (dot == std::wstring::npos ||
      (separator != std::wstring::npos && dot < separator)) {
    return std::wstring();
  }
  return ToLowerW(name.substr(dot + 1));
}

bool ReadIntegral(const flutter::EncodableMap& arguments, const char* key,
                  int64_t* value) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) return false;
  if (const auto* int32_value = std::get_if<int32_t>(&it->second)) {
    *value = *int32_value;
    return true;
  }
  if (const auto* int64_value = std::get_if<int64_t>(&it->second)) {
    *value = *int64_value;
    return true;
  }
  return false;
}

}  // namespace

NtfsIndexChannel::NtfsIndexChannel(flutter::BinaryMessenger* messenger,
                                   HWND window)
    : window_(window) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

NtfsIndexChannel::~NtfsIndexChannel() {
  shutting_down_.store(true);
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  {
    std::lock_guard<std::mutex> lock(requests_mutex_);
    for (auto& entry : requests_) {
      entry.second->cancelled.store(true);
    }
  }
  std::vector<std::pair<std::thread, std::shared_ptr<RequestState>>> workers;
  {
    std::lock_guard<std::mutex> lock(requests_mutex_);
    workers.swap(workers_);
  }
  for (auto& worker : workers) {
    if (worker.first.joinable()) worker.first.join();
  }
}

void NtfsIndexChannel::HandlePostedMessages() {
  std::vector<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending.swap(pending_);
  }
  for (auto& callback : pending) {
    callback();
  }
}

void NtfsIndexChannel::PostToUi(std::function<void()> callback) {
  if (window_ == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_.push_back(std::move(callback));
  }
  ::PostMessageW(window_, kPostedMessage, 0, 0);
}

void NtfsIndexChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_arguments", "Arguments are required.");
    return;
  }

  if (call.method_name() == "probe") {
    const auto root_it = arguments->find(flutter::EncodableValue("root"));
    if (root_it == arguments->end()) {
      result->Error("invalid_arguments", "A root path is required.");
      return;
    }
    const auto* root = std::get_if<std::string>(&root_it->second);
    if (root == nullptr || root->empty()) {
      result->Error("invalid_arguments", "A root path is required.");
      return;
    }
    const std::wstring wide_root = Utf16FromUtf8(*root);
    std::wstring volume_root;
    std::string status;
    std::string message;
    std::wstring cache_key;
    if (!VolumeRootFor(wide_root, &volume_root)) {
      status = "unsupported";
      message = "无法确定根目录所在卷";
    } else {
      cache_key = ToLowerW(volume_root);
      {
        std::lock_guard<std::mutex> lock(probe_mutex_);
        const auto cached = probes_.find(cache_key);
        if (cached != probes_.end() &&
            std::chrono::steady_clock::now() - cached->second.checked_at <
                kProbeCacheAge) {
          status = cached->second.status;
          message = cached->second.message;
        }
      }
      if (status.empty()) {
        status = Probe(wide_root, &message);
        std::lock_guard<std::mutex> lock(probe_mutex_);
        probes_[cache_key] = ProbeCacheEntry{
            status, message, std::chrono::steady_clock::now()};
      }
    }
    flutter::EncodableMap response;
    response[flutter::EncodableValue("status")] =
        flutter::EncodableValue(status);
    if (!message.empty()) {
      response[flutter::EncodableValue("message")] =
          flutter::EncodableValue(message);
    }
    result->Success(flutter::EncodableValue(response));
    return;
  }

  if (call.method_name() == "start") {
    int64_t request_id = 0;
    if (!ReadIntegral(*arguments, "requestId", &request_id) ||
        request_id <= 0 || request_id > 0x7fffffff) {
      result->Error("invalid_arguments", "A request id is required.");
      return;
    }
    const auto roots_it = arguments->find(flutter::EncodableValue("roots"));
    if (roots_it == arguments->end()) {
      result->Error("invalid_arguments", "A root list is required.");
      return;
    }
    const auto* roots = std::get_if<flutter::EncodableList>(&roots_it->second);
    if (roots == nullptr || roots->empty()) {
      result->Error("invalid_arguments", "A root list is required.");
      return;
    }
    std::vector<std::wstring> wide_roots;
    for (const auto& value : *roots) {
      const auto* path = std::get_if<std::string>(&value);
      if (path == nullptr || path->empty()) continue;
      const std::wstring wide = Utf16FromUtf8(*path);
      if (!wide.empty()) wide_roots.push_back(wide);
    }
    if (wide_roots.empty()) {
      result->Error("invalid_arguments", "No usable roots were provided.");
      return;
    }

    std::unordered_set<std::wstring> extensions;
    bool filter_extensions = false;
    const auto extensions_it =
        arguments->find(flutter::EncodableValue("extensions"));
    if (extensions_it != arguments->end() &&
        std::get_if<std::monostate>(&extensions_it->second) == nullptr) {
      const auto* extension_list =
          std::get_if<flutter::EncodableList>(&extensions_it->second);
      if (extension_list != nullptr) {
        filter_extensions = true;
        for (const auto& value : *extension_list) {
          const auto* extension = std::get_if<std::string>(&value);
          if (extension == nullptr) continue;
          std::wstring wide = ToLowerW(Utf16FromUtf8(*extension));
          if (!wide.empty() && wide.front() == L'.') wide.erase(0, 1);
          if (!wide.empty()) extensions.insert(wide);
        }
      }
    }

    int64_t max_items = -1;
    ReadIntegral(*arguments, "maxItems", &max_items);
    if (max_items < 0) max_items = -1;

    StartRequest(static_cast<int>(request_id), wide_roots, extensions,
                 filter_extensions, max_items);
    result->Success();
    return;
  }

  if (call.method_name() == "cancel") {
    int64_t request_id = 0;
    if (ReadIntegral(*arguments, "requestId", &request_id)) {
      std::lock_guard<std::mutex> lock(requests_mutex_);
      const auto it = requests_.find(static_cast<int>(request_id));
      if (it != requests_.end()) {
        it->second->cancelled.store(true);
      }
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

void NtfsIndexChannel::StartRequest(
    int request_id, const std::vector<std::wstring>& roots,
    const std::unordered_set<std::wstring>& extensions,
    bool filter_extensions, int64_t max_items) {
  if (shutting_down_.load()) return;
  ReapWorkers();
  auto state = std::make_shared<RequestState>();
  state->id = request_id;
  {
    std::lock_guard<std::mutex> lock(requests_mutex_);
    requests_[request_id] = state;
  }
  try {
    std::lock_guard<std::mutex> lock(requests_mutex_);
    workers_.emplace_back(
        std::thread([this, state, roots, extensions, filter_extensions,
                     max_items]() {
          RunRequest(state, roots, extensions, filter_extensions, max_items);
        }),
        state);
  } catch (const std::system_error& error) {
    SendDone(request_id, std::string("无法启动索引线程：") + error.what(),
             false);
    state->finished.store(true);
  }
}

void NtfsIndexChannel::ReapWorkers() {
  std::lock_guard<std::mutex> lock(requests_mutex_);
  for (auto it = workers_.begin(); it != workers_.end();) {
    if (it->second->finished.load()) {
      if (it->first.joinable()) it->first.join();
      it = workers_.erase(it);
    } else {
      ++it;
    }
  }
}

std::string NtfsIndexChannel::Probe(const std::wstring& root,
                                    std::string* message) {
  std::wstring volume_root;
  if (!VolumeRootFor(root, &volume_root)) {
    *message = "无法确定根目录所在卷";
    return "unsupported";
  }
  std::wstring device_path;
  if (!DevicePathForVolume(volume_root, &device_path)) {
    *message = "暂不支持 UNC 或挂载点卷的 NTFS 索引";
    return "unsupported";
  }
  if (!IsNtfsVolume(volume_root)) {
    *message = "卷文件系统不是 NTFS";
    return "not_ntfs";
  }
  DWORD error = 0;
  HANDLE volume = OpenVolume(device_path, &error);
  if (volume == INVALID_HANDLE_VALUE) {
    if (error == ERROR_ACCESS_DENIED || error == ERROR_PRIVILEGE_NOT_HELD) {
      *message = "读取 USN 日志需要管理员权限";
      return "unprivileged";
    }
    *message = ErrorMessage(error);
    return "error";
  }
  USN_JOURNAL_DATA_V0 journal = {};
  const bool ok = QueryJournal(volume, &journal, &error);
  ::CloseHandle(volume);
  if (!ok) {
    if (error == ERROR_ACCESS_DENIED || error == ERROR_PRIVILEGE_NOT_HELD) {
      *message = "读取 USN 日志需要管理员权限";
      return "unprivileged";
    }
    if (error == ERROR_JOURNAL_NOT_ACTIVE) {
      *message = "此卷的 USN 日志未启用";
      return "journal_inactive";
    }
    if (error == ERROR_INVALID_FUNCTION || error == ERROR_NOT_SUPPORTED) {
      *message = "此卷不支持 USN 枚举";
      return "unsupported";
    }
    *message = ErrorMessage(error);
    return "error";
  }
  return "available";
}

std::shared_ptr<NtfsIndexChannel::VolumeIndex>
NtfsIndexChannel::GetVolumeIndex(const std::wstring& volume_root) {
  const std::wstring cache_key = ToLowerW(volume_root);
  std::lock_guard<std::mutex> lock(volume_mutex_);
  const auto cached = volumes_.find(cache_key);
  if (cached != volumes_.end() &&
      std::chrono::steady_clock::now() - cached->second->built_at <
          kVolumeCacheAge) {
    return cached->second;
  }

  auto index = std::make_shared<VolumeIndex>();
  index->built_at = std::chrono::steady_clock::now();
  std::wstring device_path;
  if (!DevicePathForVolume(volume_root, &device_path)) {
    index->error = "暂不支持 UNC 或挂载点卷的 NTFS 索引";
    volumes_[cache_key] = index;
    return index;
  }
  DWORD error = 0;
  HANDLE volume = OpenVolume(device_path, &error);
  if (volume == INVALID_HANDLE_VALUE) {
    index->error = error == ERROR_ACCESS_DENIED ||
                           error == ERROR_PRIVILEGE_NOT_HELD
                       ? "读取 USN 日志需要管理员权限"
                       : ErrorMessage(error);
    volumes_[cache_key] = index;
    return index;
  }

  USN_JOURNAL_DATA_V0 journal = {};
  if (!QueryJournal(volume, &journal, &error)) {
    index->error = ErrorMessage(error);
    ::CloseHandle(volume);
    volumes_[cache_key] = index;
    return index;
  }

  std::vector<char> buffer(kEnumBufferBytes);
  MFT_ENUM_DATA_V0 enumeration = {};
  enumeration.StartFileReferenceNumber = 0;
  enumeration.LowUsn = 0;
  enumeration.HighUsn = journal.NextUsn;

  while (!shutting_down_.load()) {
    DWORD returned = 0;
    const BOOL ok = ::DeviceIoControl(
        volume, FSCTL_ENUM_USN_DATA, &enumeration, sizeof(enumeration),
        buffer.data(), static_cast<DWORD>(buffer.size()), &returned, nullptr);
    if (!ok) {
      error = ::GetLastError();
      if (error == ERROR_HANDLE_EOF) break;
      index->error = ErrorMessage(error);
      break;
    }
    if (returned <= sizeof(USN)) break;
    enumeration.StartFileReferenceNumber =
        *reinterpret_cast<const USN*>(buffer.data());

    size_t offset = sizeof(USN);
    while (offset + sizeof(USN_RECORD_V2) <= returned) {
      const auto* record =
          reinterpret_cast<const USN_RECORD_V2*>(buffer.data() + offset);
      if (record->RecordLength == 0 ||
          record->RecordLength < offsetof(USN_RECORD_V2, FileName) ||
          offset + record->RecordLength > returned) {
        break;
      }
      if (record->MajorVersion == 2) {
        const size_t name_end =
            static_cast<size_t>(record->FileNameOffset) + record->FileNameLength;
        if (name_end <= record->RecordLength && record->FileNameLength >= 2) {
          const wchar_t* name = reinterpret_cast<const wchar_t*>(
              reinterpret_cast<const char*>(record) + record->FileNameOffset);
          const size_t name_length = record->FileNameLength / sizeof(wchar_t);
          if (name_length > 0) {
            IndexedEntry entry;
            entry.parent = record->ParentFileReferenceNumber;
            entry.name.assign(name, name_length);
            entry.attributes = record->FileAttributes;
            index->entries[record->FileReferenceNumber] = std::move(entry);
            index->children[record->ParentFileReferenceNumber].push_back(
                record->FileReferenceNumber);
            if (index->entries.size() > kMaxIndexedRecords) {
              index->error =
                  "卷上的索引记录超过 200 万条，已放弃 NTFS 索引";
              break;
            }
          }
        }
      }
      offset += record->RecordLength;
    }
    if (!index->error.empty()) break;
  }

  ::CloseHandle(volume);
  if (index->error.empty()) {
    index->available = true;
  } else {
    index->entries.clear();
    index->children.clear();
  }
  volumes_[cache_key] = index;
  return index;
}

void NtfsIndexChannel::RunRequest(
    std::shared_ptr<RequestState> state, std::vector<std::wstring> roots,
    std::unordered_set<std::wstring> extensions, bool filter_extensions,
    int64_t max_items) {
  std::string error;
  bool truncated = false;
  int64_t emitted = 0;
  std::vector<std::string> batch;
  batch.reserve(kBatchSize);

  auto flush = [&]() {
    if (batch.empty()) return;
    SendBatch(state->id, std::move(batch));
    batch = std::vector<std::string>();
    batch.reserve(kBatchSize);
  };

  try {
    for (const auto& root : roots) {
      if (state->cancelled.load() || shutting_down_.load()) break;
      std::wstring volume_root;
      if (!VolumeRootFor(root, &volume_root)) {
        error = "无法确定根目录所在卷";
        break;
      }
      auto index = GetVolumeIndex(volume_root);
      if (!index->available) {
        error = index->error.empty() ? "NTFS 索引不可用" : index->error;
        break;
      }
      uint64_t root_id = 0;
      if (!FileIdForPath(root, &root_id)) {
        error = "无法读取根目录的文件索引";
        break;
      }
      if (index->entries.find(root_id) == index->entries.end()) {
        error = "根目录不在 USN 索引中";
        break;
      }

      std::deque<std::pair<uint64_t, std::wstring>> pending;
      pending.emplace_back(root_id, root);
      bool stop = false;
      while (!pending.empty() && !stop) {
        if (state->cancelled.load() || shutting_down_.load()) {
          stop = true;
          break;
        }
        auto current = std::move(pending.front());
        pending.pop_front();
        const auto children = index->children.find(current.first);
        if (children == index->children.end()) continue;
        for (const uint64_t child : children->second) {
          if (state->cancelled.load() || shutting_down_.load()) {
            stop = true;
            break;
          }
          const auto entry = index->entries.find(child);
          if (entry == index->entries.end()) continue;
          const IndexedEntry& metadata = entry->second;
          if ((metadata.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            continue;
          }
          std::wstring child_path = JoinPath(current.second, metadata.name);
          if ((metadata.attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            pending.emplace_back(child, std::move(child_path));
            continue;
          }
          if (filter_extensions &&
              extensions.find(ExtensionOf(metadata.name)) ==
                  extensions.end()) {
            continue;
          }
          if (max_items >= 0 && emitted >= max_items) {
            truncated = true;
            stop = true;
            break;
          }
          batch.push_back(Utf8FromUtf16(child_path.c_str()));
          emitted++;
          if (batch.size() >= kBatchSize) {
            flush();
            if (state->cancelled.load()) {
              stop = true;
              break;
            }
          }
        }
      }
      flush();
      if (state->cancelled.load() || truncated) break;
    }
  } catch (const std::exception& exception) {
    error = exception.what();
  } catch (...) {
    error = "NTFS 索引发生未知错误";
  }

  flush();
  SendDone(state->id, error, truncated);
  state->finished.store(true);
}

void NtfsIndexChannel::SendBatch(int request_id,
                                 std::vector<std::string> paths) {
  if (paths.empty()) return;
  PostToUi([this, request_id, paths = std::move(paths)]() mutable {
    flutter::EncodableList list;
    list.reserve(paths.size());
    for (auto& path : paths) {
      list.emplace_back(flutter::EncodableValue(std::move(path)));
    }
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("requestId")] =
        flutter::EncodableValue(request_id);
    arguments[flutter::EncodableValue("paths")] =
        flutter::EncodableValue(std::move(list));
    if (channel_) {
      channel_->InvokeMethod(
          "batch",
          std::make_unique<flutter::EncodableValue>(std::move(arguments)));
    }
  });
}

void NtfsIndexChannel::SendDone(int request_id, const std::string& error,
                                bool truncated) {
  PostToUi([this, request_id, error, truncated]() {
    flutter::EncodableMap arguments;
    arguments[flutter::EncodableValue("requestId")] =
        flutter::EncodableValue(request_id);
    arguments[flutter::EncodableValue("error")] =
        flutter::EncodableValue(error);
    arguments[flutter::EncodableValue("truncated")] =
        flutter::EncodableValue(truncated);
    if (channel_) {
      channel_->InvokeMethod(
          "done",
          std::make_unique<flutter::EncodableValue>(std::move(arguments)));
    }
  });
}
