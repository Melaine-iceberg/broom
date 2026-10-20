#include "directory_enum_channel.h"

#include <flutter/standard_method_codec.h>

#include <exception>
#include <system_error>
#include <utility>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "broom/directory_enum";

// FILETIME counts 100-nanosecond ticks from 1601-01-01; Unix time starts
// 11644473600 seconds later.
constexpr uint64_t kUnixEpochTicks = 116444736000000000ULL;

constexpr DWORD kFileAttributeDirectory = 0x00000010;

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

int64_t FileTimeToUnixMicros(const FILETIME& time) {
  const uint64_t ticks = (static_cast<uint64_t>(time.dwHighDateTime) << 32) |
                         static_cast<uint64_t>(time.dwLowDateTime);
  if (ticks <= kUnixEpochTicks) return 0;
  return static_cast<int64_t>((ticks - kUnixEpochTicks) / 10);
}

bool IsDotEntry(const wchar_t* name) {
  return name[0] == L'.' &&
         (name[1] == L'\0' || (name[1] == L'.' && name[2] == L'\0'));
}

}  // namespace

DirectoryEnumChannel::DirectoryEnumChannel(flutter::BinaryMessenger* messenger,
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

  workers_.reserve(kWorkerCount);
  for (size_t index = 0; index < kWorkerCount; index++) {
    try {
      workers_.emplace_back([this]() { WorkerLoop(); });
    } catch (const std::system_error&) {
      // Fewer workers only reduces parallelism; calls still complete.
      break;
    }
  }
}

DirectoryEnumChannel::~DirectoryEnumChannel() {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    shutting_down_ = true;
  }
  queue_cv_.notify_all();
  for (auto& worker : workers_) {
    if (worker.joinable()) worker.join();
  }
  workers_.clear();

  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }

  // Queued replies that never ran: dropping the MethodResult leaves the Dart
  // future pending, which is the expected outcome while the engine shuts down.
  std::vector<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending.swap(pending_);
  }
}

void DirectoryEnumChannel::HandlePostedMessages() {
  std::vector<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending.swap(pending_);
  }
  for (auto& callback : pending) {
    callback();
  }
}

void DirectoryEnumChannel::PostToUi(std::function<void()> callback) {
  if (window_ == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_.push_back(std::move(callback));
  }
  ::PostMessageW(window_, kPostedMessage, 0, 0);
}

void DirectoryEnumChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "ping") {
    // Lets the scan coordinator prove the channel exists before it allows
    // worker isolates to use it.
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (call.method_name() != "listDirectory") {
    result->NotImplemented();
    return;
  }
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Error("invalid_arguments", "A directory path is required.");
    return;
  }
  const auto path_it = arguments->find(flutter::EncodableValue("path"));
  if (path_it == arguments->end()) {
    result->Error("invalid_arguments", "A directory path is required.");
    return;
  }
  const auto* path = std::get_if<std::string>(&path_it->second);
  if (path == nullptr || path->empty()) {
    result->Error("invalid_arguments", "A directory path is required.");
    return;
  }
  std::wstring wide_path = Utf16FromUtf8(*path);
  if (wide_path.empty()) {
    result->Error("invalid_arguments", "The directory path is not valid UTF-8.");
    return;
  }
  Enqueue(std::move(wide_path), std::move(result));
}

void DirectoryEnumChannel::Enqueue(
    std::wstring path,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (shutting_down_ || workers_.empty()) {
      // Nothing will drain the queue; answer on the platform thread.
      const std::string message = workers_.empty()
                                      ? "无法启动目录枚举线程"
                                      : "目录枚举通道已关闭";
      result->Error("enumeration_unavailable", message);
      return;
    }
    queue_.push_back(Job{std::move(path), std::move(result)});
  }
  queue_cv_.notify_one();
}

void DirectoryEnumChannel::WorkerLoop() {
  for (;;) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      queue_cv_.wait(lock, [this]() { return shutting_down_ || !queue_.empty(); });
      if (queue_.empty()) {
        if (shutting_down_) return;
        continue;
      }
      job = std::move(queue_.front());
      queue_.pop_front();
    }
    if (!job.result) continue;

    auto listing = std::make_shared<Listing>();
    try {
      Enumerate(job.path, listing.get());
    } catch (const std::exception&) {
      listing->error = ERROR_GEN_FAILURE;
    } catch (...) {
      listing->error = ERROR_GEN_FAILURE;
    }

    // std::function requires a copyable target, so the reply handle travels as
    // a shared_ptr. It is still touched by exactly one thread.
    auto result = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(job.result));
    PostToUi([this, listing, result]() {
      if (!result) return;
      if (listing->error != 0) {
        result->Error(
            "win32",
            ErrorMessage(listing->error),
            flutter::EncodableValue(static_cast<int32_t>(listing->error)));
        return;
      }
      flutter::EncodableList names;
      names.reserve(listing->names.size());
      for (auto& name : listing->names) {
        names.emplace_back(flutter::EncodableValue(std::move(name)));
      }
      // A zero-length typed vector does not survive the standard codec round
      // trip (the Dart reader rejects the message), and a column is only empty
      // when the directory itself is empty, so empty columns go out as plain
      // empty lists — the Dart decoder only reads lengths from them.
      auto column = [](auto& values) -> flutter::EncodableValue {
        if (values.empty()) {
          return flutter::EncodableValue(flutter::EncodableList());
        }
        return flutter::EncodableValue(std::move(values));
      };
      flutter::EncodableMap response;
      response[flutter::EncodableValue("names")] =
          flutter::EncodableValue(std::move(names));
      response[flutter::EncodableValue("sizes")] = column(listing->sizes);
      response[flutter::EncodableValue("modified")] =
          column(listing->modified_micros);
      response[flutter::EncodableValue("attributes")] =
          column(listing->attributes);
      result->Success(flutter::EncodableValue(std::move(response)));
    });
  }
}

void DirectoryEnumChannel::Enumerate(const std::wstring& path,
                                     Listing* listing) {
  std::wstring pattern = ToExtendedWindowsPath(path);
  if (pattern.empty()) {
    listing->error = ERROR_INVALID_PARAMETER;
    return;
  }
  if (pattern.back() != L'\\' && pattern.back() != L'/') {
    pattern.push_back(L'\\');
  }
  pattern.push_back(L'*');

  WIN32_FIND_DATAW data = {};
  HANDLE handle = ::FindFirstFileW(pattern.c_str(), &data);
  if (handle == INVALID_HANDLE_VALUE) {
    const DWORD error = ::GetLastError();
    if (error == ERROR_FILE_NOT_FOUND) {
      // An empty directory reports ERROR_FILE_NOT_FOUND for the `*` pattern.
      // Only treat it as empty when the path itself still exists.
      const DWORD attributes =
          ::GetFileAttributesW(ToExtendedWindowsPath(path).c_str());
      if (attributes != INVALID_FILE_ATTRIBUTES &&
          (attributes & kFileAttributeDirectory) != 0) {
        return;
      }
    }
    listing->error = error;
    return;
  }

  do {
    if (IsDotEntry(data.cFileName)) continue;
    listing->names.push_back(Utf8FromUtf16(data.cFileName));
    listing->sizes.push_back((static_cast<int64_t>(data.nFileSizeHigh) << 32) |
                             static_cast<int64_t>(data.nFileSizeLow));
    listing->modified_micros.push_back(FileTimeToUnixMicros(data.ftLastWriteTime));
    listing->attributes.push_back(static_cast<int32_t>(data.dwFileAttributes));
  } while (::FindNextFileW(handle, &data));

  ::FindClose(handle);
}
