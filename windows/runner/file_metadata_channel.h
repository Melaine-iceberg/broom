#ifndef RUNNER_FILE_METADATA_CHANNEL_H_
#define RUNNER_FILE_METADATA_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Restores timestamps, the read-only attribute and (best effort) the DACL of
// quarantined files. Owner, group and SACL are intentionally not touched.
class FileMetadataChannel {
 public:
  explicit FileMetadataChannel(flutter::BinaryMessenger* messenger);
  ~FileMetadataChannel();

  FileMetadataChannel(const FileMetadataChannel&) = delete;
  FileMetadataChannel& operator=(const FileMetadataChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_FILE_METADATA_CHANNEL_H_
