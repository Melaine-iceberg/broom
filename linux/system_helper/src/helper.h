#ifndef BROOM_SYSTEM_HELPER_HELPER_H_
#define BROOM_SYSTEM_HELPER_HELPER_H_

#include <string>
#include <vector>

#include "probe.h"
#include "runner.h"

namespace broom {

struct HelperContext {
  Environment* environment = nullptr;
  // Owned by main() in production and by the caller in tests. --run requires a
  // runner; --list and --self-test do not touch it.
  OperationRunner* runner = nullptr;
  std::string helper_install_path;
  std::string policy_path;
  std::string pkexec_path;
  std::string version;
};

// Runs one helper invocation and fills the streams that main() prints.
int RunHelper(const std::vector<std::string>& arguments,
              HelperContext* context,
              std::string* stdout_text,
              std::string* stderr_text);

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_HELPER_H_
