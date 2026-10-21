#ifndef RUNNER_INSTALLED_APPS_CHANNEL_H_
#define RUNNER_INSTALLED_APPS_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Exposes a read-only inventory of applications registered with Windows.
// The channel never writes to or deletes registry data.
class InstalledAppsChannel {
 public:
  explicit InstalledAppsChannel(flutter::BinaryMessenger* messenger);
  ~InstalledAppsChannel();

  InstalledAppsChannel(const InstalledAppsChannel&) = delete;
  InstalledAppsChannel& operator=(const InstalledAppsChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_INSTALLED_APPS_CHANNEL_H_
