#ifndef BROOM_SYSTEM_HELPER_HELPER_H_
#define BROOM_SYSTEM_HELPER_HELPER_H_

#include <string>
#include <vector>

#include "probe.h"

namespace broom {

struct HelperContext {
  Environment* environment = nullptr;
  std::string helper_install_path;
  std::string policy_path;
  std::string pkexec_path;
  std::string version;
};

// Runs one helper invocation and fills the streams that main() prints. The
// function performs no filesystem mutation: stage 1 only lists, self-tests,
// validates arguments, and reports that cleanup is not implemented.
int RunHelper(const std::vector<std::string>& arguments,
              HelperContext* context,
              std::string* stdout_text,
              std::string* stderr_text);

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_HELPER_H_
