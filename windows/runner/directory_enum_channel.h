#ifndef RUNNER_DIRECTORY_ENUM_CHANNEL_H_
#define RUNNER_DIRECTORY_ENUM_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Enumerates one directory with FindFirstFileW and returns names, sizes,
// timestamps and attributes together.
//
// dart:io's `Directory.list` only yields names, so a scanner that needs sizes
// has to issue one `stat` per child — two system calls per file, the second one
// being pure latency. WIN32_FIND_DATAW already carries that metadata, so a
// single enumeration replaces the listing plus every stat.
//
// The loop runs on a small worker pool: a cold or networked directory can take
// several milliseconds, and the platform thread also owns the window message
// loop. Results are marshalled back with PostMessage so the MethodChannel reply
// happens on the platform thread.
class DirectoryEnumChannel {
 public:
  static constexpr UINT kPostedMessage = WM_APP + 0x43;

  DirectoryEnumChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~DirectoryEnumChannel();

  DirectoryEnumChannel(const DirectoryEnumChannel&) = delete;
  DirectoryEnumChannel& operator=(const DirectoryEnumChannel&) = delete;

  // Invoked on the platform thread when kPostedMessage is received.
  void HandlePostedMessages();

 private:
  // Parallel listings. The scan itself runs one directory walk per worker, so a
  // deeper pool would only queue behind the same disk anyway.
  static constexpr size_t kWorkerCount = 4;

  // Column-oriented result: three typed vectors cross the channel as
  // Int64List / Int32List instead of one EncodableMap per entry.
  struct Listing {
    std::vector<std::string> names;
    std::vector<int64_t> sizes;
    std::vector<int64_t> modified_micros;
    std::vector<int32_t> attributes;
    DWORD error = 0;
  };

  struct Job {
    std::wstring path;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Enqueue(std::wstring path,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result);
  void WorkerLoop();
  void PostToUi(std::function<void()> callback);
  static void Enumerate(const std::wstring& path, Listing* listing);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;

  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<Job> queue_;
  bool shutting_down_ = false;
  std::vector<std::thread> workers_;

  std::mutex pending_mutex_;
  std::vector<std::function<void()>> pending_;
};

#endif  // RUNNER_DIRECTORY_ENUM_CHANNEL_H_
