#ifndef BROOM_SYSTEM_HELPER_OPERATIONS_H_
#define BROOM_SYSTEM_HELPER_OPERATIONS_H_

#include <string>
#include <string_view>
#include <vector>

#include "probe.h"

namespace broom {

enum class OperationKind {
  // Runs the fixed command once.
  kSingleCommand,
  // Lists disabled snap revisions with the fixed command and removes each one
  // through `snap remove`. Revision names and numbers come from snap itself and
  // are validated before use; nothing from the UI reaches the arguments.
  kSnapRevisions,
};

// A fixed operation. Paths, arguments and additional environment entries are
// compile-time constants: no value from the command line or the UI may be
// substituted here.
struct OperationSpec {
  const char* id;
  const char* binary_path;
  std::vector<const char*> arguments;
  // Extra environment entries appended to the minimal helper environment.
  std::vector<const char*> environment;
  // Used only to measure freed space around the operation. Never passed to the
  // tool and never writable by the caller.
  const char* storage_path;
  unsigned int timeout_seconds;
  OperationKind kind = OperationKind::kSingleCommand;
};

const std::vector<OperationSpec>& AllOperations();

const OperationSpec* FindOperation(std::string_view id);

// Returns the requested operations in their canonical execution order,
// deduplicated. Unknown ids are ignored; callers validate them first.
std::vector<const OperationSpec*> SelectOperations(
    const std::vector<std::string>& ids);

struct ToolAvailability {
  bool available = false;
  std::string reason;
};

// Requires a regular file with an execute bit, owned by root, and not writable
// by group or other users. The helper never runs a tool that fails this test.
ToolAvailability CheckTool(const Environment& environment,
                           const std::string& path);

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_OPERATIONS_H_
