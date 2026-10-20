#ifndef RUNNER_SCAN_PRIORITY_CHANNEL_H_
#define RUNNER_SCAN_PRIORITY_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <mutex>
#include <string>

// Lowers the process priority while a scan is running and restores the
// previous priority class afterwards.
class ScanPriorityChannel {
 public:
  explicit ScanPriorityChannel(flutter::BinaryMessenger* messenger);
  ~ScanPriorityChannel();

  ScanPriorityChannel(const ScanPriorityChannel&) = delete;
  ScanPriorityChannel& operator=(const ScanPriorityChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::mutex mutex_;
  bool active_ = false;
  DWORD previous_priority_class_ = NORMAL_PRIORITY_CLASS;
};

#endif  // RUNNER_SCAN_PRIORITY_CHANNEL_H_
