#include "helper.h"

#include <string_view>
#include <utility>
#include <vector>

#include "cli.h"
#include "json.h"
#include "operations.h"
#include "runner.h"
#include "self_test.h"

namespace broom {
namespace {

constexpr int kExitUsage = 64;
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

struct OperationEntry {
  const OperationSpec* spec = nullptr;
  OperationRunResult result;
};

std::string BuildRunJson(const std::vector<OperationEntry>& entries) {
  std::string output = "{\"schemaVersion\":1,\"operations\":[";
  bool first = true;
  for (const OperationEntry& entry : entries) {
    if (!first) output.push_back(',');
    first = false;
    output += "{\"id\":" + JsonQuote(entry.spec->id) + ",\"status\":" +
              JsonQuote(OperationStatusName(entry.result.status));
    output += ",\"exitCode\":";
    output += entry.result.exit_code >= 0
                  ? std::to_string(entry.result.exit_code)
                  : "null";
    output += ",\"freedBytes\":";
    output += entry.result.freed_bytes >= 0
                  ? std::to_string(entry.result.freed_bytes)
                  : "null";
    output += ",\"message\":" + JsonQuote(entry.result.message) + "}";
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
      if (context->runner == nullptr) {
        return Fail(stdout_text, stderr_text, kExitSoftware, "internal_error",
                    "The operation runner is not initialized.");
      }

      const std::vector<const OperationSpec*> selected =
          SelectOperations(parsed.options.operation_ids);
      std::vector<OperationEntry> entries;
      entries.reserve(selected.size());
      for (const OperationSpec* operation : selected) {
        OperationEntry entry;
        entry.spec = operation;
        entries.push_back(std::move(entry));
      }

      std::string lock_error;
      if (!context->runner->TryAcquire(&lock_error)) {
        for (OperationEntry& entry : entries) {
          entry.result.status = OperationStatus::kBusy;
          entry.result.message = lock_error;
        }
        if (stdout_text != nullptr) *stdout_text = BuildRunJson(entries);
        return 0;
      }

      for (OperationEntry& entry : entries) {
        const ToolAvailability availability =
            CheckTool(*context->environment, entry.spec->binary_path);
        if (!availability.available) {
          entry.result.status = OperationStatus::kUnavailable;
          entry.result.message =
              "The system tool is unavailable: " + availability.reason + ".";
          continue;
        }
        entry.result = context->runner->Run(*entry.spec);
      }
      context->runner->Release();

      if (stdout_text != nullptr) *stdout_text = BuildRunJson(entries);
      return 0;
    }
  }

  return Fail(stdout_text, stderr_text, kExitSoftware, "internal_error",
              "Unsupported command.");
}

}  // namespace broom
