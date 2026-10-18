#ifndef RUNNER_SYSTEM_ACCESS_CHANNEL_H_
#define RUNNER_SYSTEM_ACCESS_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Exposes the admin-only system cache capabilities: elevation state, UAC
// self-relaunch and canonical Windows cache locations.
class SystemAccessChannel {
 public:
  explicit SystemAccessChannel(flutter::BinaryMessenger* messenger);
  ~SystemAccessChannel();

  SystemAccessChannel(const SystemAccessChannel&) = delete;
  SystemAccessChannel& operator=(const SystemAccessChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SYSTEM_ACCESS_CHANNEL_H_
