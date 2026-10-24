#ifndef BROOM_SYSTEM_HELPER_RUNNER_H_
#define BROOM_SYSTEM_HELPER_RUNNER_H_

#include <memory>
#include <string>

#include "operations.h"

namespace broom {

enum class OperationStatus {
  kOk,
  kFailed,
  kBusy,
  kSkipped,
  kUnavailable,
};

const char* OperationStatusName(OperationStatus status);

struct OperationRunResult {
  OperationStatus status = OperationStatus::kFailed;
  int exit_code = -1;
  long long freed_bytes = -1;
  std::string message;
};

// Executes fixed operations. The interface keeps the process, lock and
// filesystem details out of RunHelper so unit tests can exercise the JSON and
// status mapping without starting a package manager.
class OperationRunner {
 public:
  virtual ~OperationRunner() = default;

  // Takes the helper's own serialization lock without waiting. Returns false
  // and fills `reason` when another Broom cleanup is already running.
  virtual bool TryAcquire(std::string* reason) = 0;

  virtual void Release() = 0;

  // Runs one operation whose tool has already passed CheckTool.
  virtual OperationRunResult Run(const OperationSpec& operation) = 0;
};

std::unique_ptr<OperationRunner> CreateSystemOperationRunner();

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_RUNNER_H_
