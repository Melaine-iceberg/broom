#include "scan_priority_channel.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

namespace {

constexpr char kChannelName[] = "broom/scan_priority";

}  // namespace

ScanPriorityChannel::ScanPriorityChannel(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

ScanPriorityChannel::~ScanPriorityChannel() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
}

void ScanPriorityChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "begin") {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_) {
      result->Success(flutter::EncodableValue("already_active"));
      return;
    }
    const HANDLE process = ::GetCurrentProcess();
    previous_priority_class_ = ::GetPriorityClass(process);
    if (previous_priority_class_ == 0) {
      previous_priority_class_ = NORMAL_PRIORITY_CLASS;
    }

    // Only CPU scheduling is lowered. `PROCESS_MODE_BACKGROUND_BEGIN` would
    // additionally drop the process I/O priority to "very low" and start
    // trimming the working set: the scan's own reads would queue behind every
    // other process, and the UI and raster threads would lose the pages they
    // need to composite a frame, so the window visibly stutters for the whole
    // scan. Background I/O priority is therefore never requested; below-normal
    // CPU priority still yields to foreground work.
    std::string mode;
    if (::SetPriorityClass(process, BELOW_NORMAL_PRIORITY_CLASS)) {
      mode = "below_normal";
    } else {
      result->Success(flutter::EncodableValue());
      return;
    }
    active_ = true;
    result->Success(flutter::EncodableValue(mode));
    return;
  }

  if (call.method_name() == "end") {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_) {
      ::SetPriorityClass(::GetCurrentProcess(), previous_priority_class_);
      active_ = false;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}
