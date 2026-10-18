#ifndef RUNNER_NTFS_INDEX_CHANNEL_H_
#define RUNNER_NTFS_INDEX_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// Streams NTFS files under requested roots using FSCTL_ENUM_USN_DATA.
//
// The MFT scan runs on a worker thread. Batches are marshalled back to the
// platform thread with PostMessage so MethodChannel calls stay on the thread
// that owns them. Every failure is reported as a stream error; the Dart
// scanner then falls back to normal directory traversal for that root.
class NtfsIndexChannel {
 public:
  static constexpr UINT kPostedMessage = WM_APP + 0x42;

  NtfsIndexChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~NtfsIndexChannel();

  NtfsIndexChannel(const NtfsIndexChannel&) = delete;
  NtfsIndexChannel& operator=(const NtfsIndexChannel&) = delete;

  // Invoked on the platform thread when kPostedMessage is received.
  void HandlePostedMessages();

 private:
  struct IndexedEntry {
    uint64_t parent = 0;
    std::wstring name;
    DWORD attributes = 0;
  };

  struct VolumeIndex {
    std::chrono::steady_clock::time_point built_at;
    bool available = false;
    std::string error;
    std::unordered_map<uint64_t, IndexedEntry> entries;
    std::unordered_map<uint64_t, std::vector<uint64_t>> children;
  };

  struct RequestState {
    int id = 0;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> finished{false};
  };

  struct ProbeCacheEntry {
    std::string status;
    std::string message;
    std::chrono::steady_clock::time_point checked_at;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartRequest(
      int request_id,
      const std::vector<std::wstring>& roots,
      const std::unordered_set<std::wstring>& extensions,
      bool filter_extensions,
      int64_t max_items);
  void RunRequest(
      std::shared_ptr<RequestState> state,
      std::vector<std::wstring> roots,
      std::unordered_set<std::wstring> extensions,
      bool filter_extensions,
      int64_t max_items);
  std::string Probe(const std::wstring& root, std::string* message);
  std::shared_ptr<VolumeIndex> GetVolumeIndex(const std::wstring& volume_root);
  void SendBatch(int request_id, std::vector<std::string> paths);
  void SendDone(int request_id, const std::string& error, bool truncated);
  void PostToUi(std::function<void()> callback);
  void ReapWorkers();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;

  std::mutex pending_mutex_;
  std::vector<std::function<void()>> pending_;

  std::mutex requests_mutex_;
  std::unordered_map<int, std::shared_ptr<RequestState>> requests_;
  std::vector<std::pair<std::thread, std::shared_ptr<RequestState>>> workers_;

  std::mutex volume_mutex_;
  std::unordered_map<std::wstring, std::shared_ptr<VolumeIndex>> volumes_;

  std::mutex probe_mutex_;
  std::unordered_map<std::wstring, ProbeCacheEntry> probes_;

  std::atomic<bool> shutting_down_{false};
};

#endif  // RUNNER_NTFS_INDEX_CHANNEL_H_
