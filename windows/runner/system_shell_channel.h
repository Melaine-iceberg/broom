#ifndef RUNNER_SYSTEM_SHELL_CHANNEL_H_
#define RUNNER_SYSTEM_SHELL_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Exposes the small set of Windows shell features used by the Review/Info
// tools: recycle bin stats/emptying, folder selection and Explorer reveal.
class SystemShellChannel {
 public:
  SystemShellChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~SystemShellChannel();

  SystemShellChannel(const SystemShellChannel&) = delete;
  SystemShellChannel& operator=(const SystemShellChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SYSTEM_SHELL_CHANNEL_H_
