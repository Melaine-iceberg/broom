#ifndef BROOM_SYSTEM_HELPER_CLI_H_
#define BROOM_SYSTEM_HELPER_CLI_H_

#include <optional>
#include <string>
#include <vector>

namespace broom {

enum class Command { kHelp, kList, kRun, kSelfTest };

struct Options {
  std::optional<Command> command;
  std::vector<std::string> operation_ids;
};

struct ParseResult {
  bool ok = false;
  Options options;
  std::string error;
};

ParseResult ParseArguments(const std::vector<std::string>& arguments);

std::string UsageText();

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_CLI_H_
