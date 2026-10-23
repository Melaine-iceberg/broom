#include "helper.h"

#include <string_view>
#include <utility>

#include "cli.h"
#include "json.h"
#include "operations.h"
#include "self_test.h"

namespace broom {
namespace {

constexpr int kExitUsage = 64;
constexpr int kExitUnavailable = 69;
constexpr int kExitSoftware = 70;
constexpr int kExitPermission = 77;

int Fail(std::string* stdout_text,
         std::string* stderr_text,
         int exit_code,
         std::string_view code,
         std::string_view message,
         bool mention_help = false) {
  if (stdout_text != nullptr) {
    *stdout_text = ErrorJson(code, message, exit_code);
  }
  if (stderr_text != nullptr) {
    *stderr_text = "broom-system-helper: " + std::string(message) + "\n";
    if (mention_help) {
      *stderr_text += "Try 'broom-system-helper --help'.\n";
    }
  }
  return exit_code;
}

std::string BuildListJson(const HelperContext& context) {
  std::string output =
      "{\"schemaVersion\":1,\"helperVersion\":" +
      JsonQuote(context.version) + ",\"operations\":[";
  bool first = true;
  for (const OperationSpec& operation : AllOperations()) {
    const ToolAvailability availability =
        CheckTool(*context.environment, operation.binary_path);
    if (!first) output.push_back(',');
    first = false;
    output += "{\"id\":" + JsonQuote(operation.id) + ",\"available\":";
    output += availability.available ? "true" : "false";
    output += ",\"reason\":";
    output += availability.available ? "null" : JsonQuote(availability.reason);
    output += ",\"timeoutSeconds\":" +
              std::to_string(operation.timeout_seconds) + "}";
  }
  output += "]}\n";
  return output;
}

}  // namespace

int RunHelper(const std::vector<std::string>& arguments,
              HelperContext* context,
              std::string* stdout_text,
              std::string* stderr_text) {
  if (context == nullptr || context->environment == nullptr) {
    return Fail(stdout_text, stderr_text, kExitSoftware, "internal_error",
                "The helper environment is not initialized.");
  }

  const ParseResult parsed = ParseArguments(arguments);
  if (!parsed.ok) {
    return Fail(stdout_text, stderr_text, kExitUsage, "invalid_arguments",
                parsed.error, true);
  }
  if (!parsed.options.command.has_value()) {
    return Fail(stdout_text, stderr_text, kExitSoftware, "internal_error",
                "No command was selected.");
  }

  switch (*parsed.options.command) {
    case Command::kHelp:
      if (stdout_text != nullptr) *stdout_text = UsageText();
      return 0;

    case Command::kList:
      if (stdout_text != nullptr) *stdout_text = BuildListJson(*context);
      return 0;

    case Command::kSelfTest: {
      const SelfTestReport report = RunSelfTest(*context);
      if (stdout_text != nullptr) {
        *stdout_text = SelfTestReportJson(report, context->version);
      }
      return report.failed() ? kExitSoftware : 0;
    }

    case Command::kRun: {
      for (const std::string& id : parsed.options.operation_ids) {
        if (FindOperation(id) == nullptr) {
          return Fail(stdout_text, stderr_text, kExitUsage, "unknown_operation",
                      "Unknown operation id.", true);
        }
      }
      if (context->environment->EffectiveUid() != 0) {
        return Fail(stdout_text, stderr_text, kExitPermission,
                    "permission_denied", "--run must be executed as root.");
      }
      // Stage 1 deliberately stops here: the authorization chain can be
      // verified end to end, but no system tool is ever started.
      return Fail(stdout_text, stderr_text, kExitUnavailable,
                  "not_implemented",
                  "System cleanup operations are not implemented in this "
                  "build.");
    }
  }

  return Fail(stdout_text, stderr_text, kExitSoftware, "internal_error",
              "Unsupported command.");
}

}  // namespace broom
