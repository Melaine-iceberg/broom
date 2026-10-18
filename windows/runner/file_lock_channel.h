#ifndef RUNNER_FILE_LOCK_CHANNEL_H_
#define RUNNER_FILE_LOCK_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Best-effort detection of files that another process is using in a way that
// blocks a move or delete. The probe opens each file with DELETE access and
// share-read/write/delete, then closes it; it never writes to or unlocks files.
class FileLockChannel {
 public:
  explicit FileLockChannel(flutter::BinaryMessenger* messenger);
  ~FileLockChannel();

  FileLockChannel(const FileLockChannel&) = delete;
  FileLockChannel& operator=(const FileLockChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_FILE_LOCK_CHANNEL_H_
