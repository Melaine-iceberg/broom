#include "cli.h"

#include <string_view>
#include <utility>

namespace broom {
namespace {

constexpr std::size_t kMaxArguments = 16;
constexpr std::size_t kMaxTokenLength = 256;
constexpr std::size_t kMaxOperationIdLength = 64;
constexpr std::size_t kMaxOperationsPerRun = 8;

bool IsOperationId(std::string_view id) {
  if (id.empty() || id.size() > kMaxOperationIdLength) return false;
  for (const char character : id) {
    const bool allowed =
        (character >= 'a' && character <= 'z') ||
        (character >= '0' && character <= '9') || character == '-';
    if (!allowed) return false;
  }
  return true;
}

std::string Truncate(std::string_view value) {
  constexpr std::size_t kMax = 80;
  if (value.size() <= kMax) return std::string(value);
  return std::string(value.substr(0, kMax)) + "...";
}

ParseResult Error(std::string message) {
  ParseResult result;
  result.error = std::move(message);
  return result;
}

bool BeginCommand(std::optional<Command>* command,
                  Command value,
                  std::string* error) {
  if (command->has_value()) {
    *error = "only one command may be specified";
    return false;
  }
  *command = value;
  return true;
}

}  // namespace

ParseResult ParseArguments(const std::vector<std::string>& arguments) {
  if (arguments.empty()) return Error("no command specified");
  if (arguments.size() > kMaxArguments) return Error("too many arguments");

  std::optional<Command> command;
  std::vector<std::string> operation_ids;
  bool json = false;

  for (std::size_t index = 0; index < arguments.size(); ++index) {
    const std::string& argument = arguments[index];
    if (argument.size() > kMaxTokenLength) return Error("argument is too long");

    if (argument == "--json") {
      if (json) return Error("--json specified more than once");
      json = true;
      continue;
    }
    if (argument == "--help" || argument == "-h") {
      std::string error;
      if (!BeginCommand(&command, Command::kHelp, &error)) return Error(error);
      continue;
    }
    if (argument == "--list") {
      std::string error;
      if (!BeginCommand(&command, Command::kList, &error)) return Error(error);
      continue;
    }
    if (argument == "--self-test") {
      std::string error;
      if (!BeginCommand(&command, Command::kSelfTest, &error)) {
        return Error(error);
      }
      continue;
    }
    if (argument == "--run") {
      std::string error;
      if (!BeginCommand(&command, Command::kRun, &error)) return Error(error);
      if (index + 1 >= arguments.size()) {
        return Error("--run requires a comma-separated operation list");
      }
      const std::string& value = arguments[++index];
      if (value.size() > kMaxTokenLength) {
        return Error("operation list is too long");
      }
      if (value.empty()) {
        return Error("--run requires a comma-separated operation list");
      }

      std::vector<std::string> parsed_ids;
      std::size_t start = 0;
      while (start <= value.size()) {
        const std::size_t comma = value.find(',', start);
        const std::size_t end =
            comma == std::string::npos ? value.size() : comma;
        const std::string id = value.substr(start, end - start);
        if (!IsOperationId(id)) {
          return Error("invalid operation id in --run list");
        }
        parsed_ids.push_back(id);
        if (comma == std::string::npos) break;
        start = comma + 1;
      }
      if (parsed_ids.size() > kMaxOperationsPerRun) {
        return Error("too many operations requested");
      }
      operation_ids = std::move(parsed_ids);
      continue;
    }
    if (argument.rfind("--run=", 0) == 0) {
      return Error(
          "--run uses a separate argument: --run <operation[,operation...]>");
    }
    if (!argument.empty() && argument.front() == '-') {
      return Error("unknown option: " + Truncate(argument));
    }
    return Error("unexpected argument: " + Truncate(argument));
  }

  if (!command.has_value()) return Error("no command specified");
  if (json && *command == Command::kHelp) {
    return Error("--json cannot be combined with --help");
  }

  ParseResult result;
  result.ok = true;
  result.options.command = *command;
  result.options.operation_ids = std::move(operation_ids);
  return result;
}

std::string UsageText() {
  return
      "Usage:\n"
      "  broom-system-helper --list [--json]\n"
      "  broom-system-helper --self-test [--json]\n"
      "  broom-system-helper --run <operation[,operation...]> [--json]\n"
      "  broom-system-helper --help\n"
      "\n"
      "Commands:\n"
      "  --list       Report fixed operations and whether their tools are "
      "usable.\n"
      "  --self-test  Run read-only installation and tool checks.\n"
      "  --run        Validate and run operations as root.\n"
      "\n"
      "Operations:\n"
      "  apt-cache     Clean downloaded APT package archives.\n"
      "  dnf-packages  Clean downloaded DNF package cache.\n"
      "  journal-7d    Vacuum systemd journal entries older than seven "
      "days.\n"
      "\n"
      "Exit codes:\n"
      "  0   success\n"
      "  64  invalid arguments\n"
      "  69  operation unavailable\n"
      "  70  self-test failed\n"
      "  77  --run was not started as root\n";
}

}  // namespace broom
