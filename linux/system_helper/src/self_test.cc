#include "self_test.h"

#include <sys/stat.h>

#include <string>
#include <utility>

#include "json.h"
#include "operations.h"

namespace broom {
namespace {

constexpr std::size_t kMaxPolicyBytes = 1024 * 1024;

SelfTestCheck MakeCheck(std::string id,
                        std::string status,
                        std::string message) {
  SelfTestCheck check;
  check.id = std::move(id);
  check.status = std::move(status);
  check.message = std::move(message);
  return check;
}

bool IsInstalled(const HelperContext& context) {
  if (context.environment == nullptr) return false;
  const std::string self_path = context.environment->SelfPath();
  return !self_path.empty() && self_path == context.helper_install_path;
}

SelfTestCheck CheckHelperInstall(const HelperContext& context) {
  if (!IsInstalled(context)) {
    return MakeCheck(
        "helper.install", "warn",
        "Running from a development path; installation permissions are not "
        "checked.");
  }

  const FileFacts facts =
      context.environment->Inspect(context.helper_install_path);
  if (!facts.exists || !facts.is_regular) {
    return MakeCheck("helper.install", "fail",
                     "The helper is not a regular file at its install path.");
  }
  if (facts.owner != 0) {
    return MakeCheck("helper.install", "fail",
                     "The helper is not owned by root.");
  }
  if ((facts.mode & (S_IWGRP | S_IWOTH)) != 0) {
    return MakeCheck("helper.install", "fail",
                     "The helper is writable by group or other users.");
  }
  if ((facts.mode & (S_ISUID | S_ISGID)) != 0) {
    return MakeCheck("helper.install", "fail",
                     "The helper must not be setuid or setgid.");
  }
  return MakeCheck("helper.install", "pass",
                   "The helper is owned by root and not writable by others.");
}

SelfTestCheck CheckPkexec(const HelperContext& context) {
  const bool installed = IsInstalled(context);
  const ToolAvailability availability =
      CheckTool(*context.environment, context.pkexec_path);
  if (availability.available) {
    return MakeCheck("polkit.pkexec", "pass",
                     "pkexec is available at its fixed path.");
  }
  if (availability.reason == "tool_missing") {
    if (installed) {
      return MakeCheck("polkit.pkexec", "fail",
                       "pkexec is not installed; authorization cannot start.");
    }
    return MakeCheck(
        "polkit.pkexec", "warn",
        "pkexec is not installed; development builds skip this requirement.");
  }
  return MakeCheck("polkit.pkexec", "fail",
                   "pkexec failed its ownership or permission check: " +
                       availability.reason + ".");
}

SelfTestCheck CheckPolicy(const HelperContext& context) {
  const bool installed = IsInstalled(context);
  const FileFacts facts = context.environment->Inspect(context.policy_path);
  if (!facts.exists) {
    if (installed) {
      return MakeCheck("polkit.policy", "fail",
                       "The Polkit policy is not installed.");
    }
    return MakeCheck(
        "polkit.policy", "warn",
        "The Polkit policy is not installed; development builds skip this "
        "requirement.");
  }
  if (!facts.is_regular) {
    return MakeCheck("polkit.policy", "fail",
                     "The Polkit policy is not a regular file.");
  }
  if (facts.owner != 0) {
    return MakeCheck("polkit.policy", "fail",
                     "The Polkit policy is not owned by root.");
  }
  if ((facts.mode & (S_IWGRP | S_IWOTH)) != 0) {
    return MakeCheck("polkit.policy", "fail",
                     "The Polkit policy is writable by group or other users.");
  }

  std::string contents;
  if (!context.environment->ReadFile(context.policy_path, kMaxPolicyBytes,
                                     &contents)) {
    return MakeCheck("polkit.policy", "fail",
                     "The Polkit policy cannot be read.");
  }
  if (contents.find("com.broom.Broom.clean-system-cache") ==
      std::string::npos) {
    return MakeCheck("polkit.policy", "fail",
                     "The Polkit policy does not declare the expected action.");
  }
  if (contents.find(context.helper_install_path) == std::string::npos) {
    return MakeCheck("polkit.policy", "fail",
                     "The Polkit policy does not point at the installed "
                     "helper.");
  }
  return MakeCheck("polkit.policy", "pass",
                   "The Polkit policy declares the expected action and helper "
                   "path.");
}

SelfTestCheck CheckOperation(const HelperContext& context,
                             const OperationSpec& operation) {
  const ToolAvailability availability =
      CheckTool(*context.environment, operation.binary_path);
  const std::string id = std::string("operation.") + operation.id;
  if (availability.available) {
    return MakeCheck(id, "pass",
                     std::string(operation.id) +
                         " is available at its fixed path.");
  }
  if (availability.reason == "tool_missing") {
    return MakeCheck(id, "warn",
                     std::string(operation.id) + " is not installed: " +
                         availability.reason + ".");
  }
  return MakeCheck(id, "fail",
                   std::string(operation.id) +
                       " failed its ownership or permission check: " +
                       availability.reason + ".");
}

}  // namespace

SelfTestReport RunSelfTest(const HelperContext& context) {
  SelfTestReport report;
  bool has_warning = false;
  bool has_failure = false;

  auto add = [&](SelfTestCheck check) {
    if (check.status == "warn") has_warning = true;
    if (check.status == "fail") has_failure = true;
    report.checks.push_back(std::move(check));
  };

  add(CheckHelperInstall(context));
  add(CheckPkexec(context));
  add(CheckPolicy(context));
  for (const OperationSpec& operation : AllOperations()) {
    add(CheckOperation(context, operation));
  }

  if (has_failure) {
    report.status = "failed";
  } else if (has_warning) {
    report.status = "degraded";
  } else {
    report.status = "ok";
  }
  return report;
}

std::string SelfTestReportJson(const SelfTestReport& report,
                               std::string_view helper_version) {
  std::string output =
      "{\"schemaVersion\":1,\"helperVersion\":" +
      JsonQuote(helper_version) + ",\"status\":" + JsonQuote(report.status) +
      ",\"checks\":[";
  bool first = true;
  for (const SelfTestCheck& check : report.checks) {
    if (!first) output.push_back(',');
    first = false;
    output += "{\"id\":" + JsonQuote(check.id) +
              ",\"status\":" + JsonQuote(check.status) +
              ",\"message\":" + JsonQuote(check.message) + "}";
  }
  output += "]}\n";
  return output;
}

}  // namespace broom
