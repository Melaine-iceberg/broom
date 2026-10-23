#ifndef BROOM_SYSTEM_HELPER_OPERATIONS_H_
#define BROOM_SYSTEM_HELPER_OPERATIONS_H_

#include <string>
#include <string_view>
#include <vector>

#include "probe.h"

namespace broom {

// A fixed operation. Paths and arguments are compile-time constants: no value
// from the command line or the UI may be substituted here.
struct OperationSpec {
  const char* id;
  const char* binary_path;
  std::vector<const char*> arguments;
  unsigned int timeout_seconds;
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
