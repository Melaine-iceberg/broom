#include <sys/stat.h>

#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "cli.h"
#include "helper.h"
#include "json.h"
#include "operations.h"
#include "probe.h"
#include "self_test.h"

namespace {

using broom::Command;
using broom::FileFacts;

int g_failures = 0;

void Expect(bool condition, std::string_view what) {
  if (condition) return;
  ++g_failures;
  std::cerr << "FAIL: " << what << "\n";
}

void ExpectString(const std::string& actual,
                  const std::string& expected,
                  std::string_view what) {
  if (actual == expected) return;
  ++g_failures;
  std::cerr << "FAIL: " << what << "\n  actual:   " << actual
            << "\n  expected: " << expected << "\n";
}

void ExpectContains(const std::string& haystack,
                    std::string_view needle,
                    std::string_view what) {
  Expect(haystack.find(needle) != std::string::npos, what);
}

class FakeEnvironment final : public broom::Environment {
 public:
  std::map<std::string, FileFacts> files;
  std::map<std::string, std::string> contents;
  uid_t uid = 1000;
  std::string self_path = "/build/broom-system-helper";

  FileFacts Inspect(const std::string& path) const override {
    const auto entry = files.find(path);
    return entry == files.end() ? FileFacts{} : entry->second;
  }

  bool ReadFile(const std::string& path,
                std::size_t max_bytes,
                std::string* result) const override {
    const auto entry = contents.find(path);
    if (entry == contents.end()) return false;
    if (entry->second.size() > max_bytes) return false;
    *result = entry->second;
    return true;
  }

  uid_t EffectiveUid() const override { return uid; }

  std::string SelfPath() const override { return self_path; }
};

constexpr char kHelperPath[] = "/usr/libexec/broom/broom-system-helper";
constexpr char kPolicyPath[] =
    "/usr/share/polkit-1/actions/com.broom.Broom.policy";
constexpr char kPkexecPath[] = "/usr/bin/pkexec";
constexpr char kAptGetPath[] = "/usr/bin/apt-get";
constexpr char kDnfPath[] = "/usr/bin/dnf";
constexpr char kJournalctlPath[] = "/usr/bin/journalctl";

FileFacts SecureExecutable() {
  FileFacts facts;
  facts.exists = true;
  facts.is_regular = true;
  facts.executable = true;
  facts.owner = 0;
  facts.mode = 0100755;
  return facts;
}

class FakeRunner final : public broom::OperationRunner {
 public:
  bool acquire_ok = true;
  std::string acquire_reason = "Another system cleanup is already running.";
  int acquire_calls = 0;
  int release_calls = 0;
  std::vector<std::string> ran;
  std::map<std::string, broom::OperationRunResult> results;

  bool TryAcquire(std::string* reason) override {
    ++acquire_calls;
    if (!acquire_ok) {
      if (reason != nullptr) *reason = acquire_reason;
      return false;
    }
    return true;
  }

  void Release() override { ++release_calls; }

  broom::OperationRunResult Run(const broom::OperationSpec& operation) override {
    ran.emplace_back(operation.id);
    const auto entry = results.find(operation.id);
    if (entry != results.end()) return entry->second;
    broom::OperationRunResult result;
    result.status = broom::OperationStatus::kOk;
    result.exit_code = 0;
    result.message = "faked";
    return result;
  }
};

FileFacts SecurePolicyFile() {
  FileFacts facts;
  facts.exists = true;
  facts.is_regular = true;
  facts.executable = false;
  facts.owner = 0;
  facts.mode = 0100644;
  return facts;
}

struct Fixture {
  FakeEnvironment environment;
  FakeRunner runner;
  broom::HelperContext context;

  Fixture() {
    context.environment = &environment;
    context.runner = &runner;
    context.helper_install_path = kHelperPath;
    context.policy_path = kPolicyPath;
    context.pkexec_path = kPkexecPath;
    context.version = "test";
  }

  void InstallTools() {
    environment.files[kAptGetPath] = SecureExecutable();
    environment.files[kDnfPath] = SecureExecutable();
    environment.files[kJournalctlPath] = SecureExecutable();
  }

  void InstallComplete() {
    environment.self_path = kHelperPath;
    environment.files[kHelperPath] = SecureExecutable();
    environment.files[kPkexecPath] = SecureExecutable();
    environment.files[kPolicyPath] = SecurePolicyFile();
    environment.contents[kPolicyPath] =
        "<action id=\"com.broom.Broom.clean-system-cache\"/>"
        "<annotate key=\"org.freedesktop.policykit.exec.path\">" +
        std::string(kHelperPath) + "</annotate>";
    InstallTools();
  }
};

struct RunOutcome {
  int exit_code = 0;
  std::string out;
  std::string err;
};

RunOutcome Run(Fixture* fixture, const std::vector<std::string>& arguments) {
  RunOutcome outcome;
  outcome.exit_code = broom::RunHelper(
      arguments, &fixture->context, &outcome.out, &outcome.err);
  return outcome;
}

void TestParseArguments() {
  {
    const broom::ParseResult parsed =
        broom::ParseArguments({"--list", "--json"});
    Expect(parsed.ok, "list parses");
    Expect(parsed.options.command == Command::kList, "list command");
    Expect(parsed.options.operation_ids.empty(), "list has no operations");
  }
  {
    const broom::ParseResult parsed = broom::ParseArguments(
        {"--run", "journal-7d,dnf-packages", "--json"});
    Expect(parsed.ok, "run parses");
    Expect(parsed.options.command == Command::kRun, "run command");
    Expect(parsed.options.operation_ids.size() == 2, "run keeps both ids");
    Expect(parsed.options.operation_ids[0] == "journal-7d",
           "run preserves argument order");
    Expect(parsed.options.operation_ids[1] == "dnf-packages",
           "run preserves the second id");
  }
  {
    const broom::ParseResult parsed = broom::ParseArguments({"--self-test"});
    Expect(parsed.ok, "self-test parses without --json");
    Expect(parsed.options.command == Command::kSelfTest, "self-test command");
  }
  {
    const broom::ParseResult parsed = broom::ParseArguments({"--help"});
    Expect(parsed.ok, "help parses");
    Expect(parsed.options.command == Command::kHelp, "help command");
  }

  const std::vector<std::vector<std::string>> invalid = {
      {},
      {"--list", "--self-test"},
      {"--list", "--list"},
      {"--run"},
      {"--run", ""},
      {"--run", "dnf-packages,"},
      {"--run", ",dnf-packages"},
      {"--run", "dnf-packages,,journal-7d"},
      {"--run", "dnf-packages,/var/cache/dnf"},
      {"--run", "../dnf-packages"},
      {"--run", "dnf packages"},
      {"--run=dnf-packages"},
      {"--run", "dnf-packages", "--path", "/var/cache/dnf"},
      {"--path", "/var/cache/dnf"},
      {"--command", "rm"},
      {"--shell", "sh"},
      {"--list", "extra"},
      {"--json"},
      {"--json", "--json", "--list"},
      {"--help", "--json"},
      {"--help", "--list"},
  };
  for (const std::vector<std::string>& arguments : invalid) {
    const broom::ParseResult parsed = broom::ParseArguments(arguments);
    Expect(!parsed.ok, "invalid argument list is rejected");
    Expect(!parsed.error.empty(), "invalid argument list has an error");
  }

  const std::string long_argument(300, 'a');
  const broom::ParseResult too_long =
      broom::ParseArguments({"--run", long_argument});
  Expect(!too_long.ok, "overlong run list is rejected");
}

void TestOperationSelection() {
  for (const broom::OperationSpec& operation : broom::AllOperations()) {
    Expect(operation.binary_path[0] == '/', "tool paths are absolute");
    Expect(!operation.arguments.empty(), "operations have fixed arguments");
    Expect(operation.timeout_seconds > 0, "operations have a timeout");
  }
  Expect(broom::FindOperation("apt-cache") != nullptr,
         "apt-cache is known");
  Expect(broom::FindOperation("dnf-packages") != nullptr,
         "dnf-packages is known");
  Expect(broom::FindOperation("journal-7d") != nullptr,
         "journal-7d is known");
  Expect(broom::FindOperation("dnf") == nullptr, "short names are rejected");
  Expect(broom::FindOperation("/var/cache/dnf") == nullptr,
         "paths are never operations");

  const std::vector<const broom::OperationSpec*> selected =
      broom::SelectOperations(
          {"journal-7d", "dnf-packages", "apt-cache", "journal-7d",
           "unknown"});
  Expect(selected.size() == 3, "selection deduplicates and drops unknown ids");
  Expect(std::string(selected[0]->id) == "apt-cache",
         "apt runs first regardless of input order");
  Expect(std::string(selected[1]->id) == "dnf-packages",
         "dnf runs second");
  Expect(std::string(selected[2]->id) == "journal-7d",
         "journal runs third");
}

void TestList() {
  {
    Fixture fixture;
    fixture.InstallTools();
    const RunOutcome outcome = Run(&fixture, {"--list", "--json"});
    Expect(outcome.exit_code == 0, "list succeeds");
    Expect(outcome.err.empty(), "list writes no diagnostics");
    ExpectContains(outcome.out, "\"schemaVersion\":1", "list schema");
    ExpectContains(outcome.out, "\"helperVersion\":\"test\"",
                   "list helper version");
    ExpectContains(outcome.out,
                   "\"id\":\"apt-cache\",\"available\":true", "apt listed");
    ExpectContains(outcome.out, "\"reason\":null,\"timeoutSeconds\":600",
                   "apt timeout");
    ExpectContains(outcome.out,
                   "\"id\":\"dnf-packages\",\"available\":true", "dnf listed");
    ExpectContains(outcome.out, "\"reason\":null,\"timeoutSeconds\":600",
                   "dnf timeout");
    ExpectContains(outcome.out,
                   "\"id\":\"journal-7d\",\"available\":true",
                   "journal listed");
    ExpectContains(outcome.out, "\"timeoutSeconds\":120", "journal timeout");
  }
  {
    Fixture fixture;
    fixture.InstallTools();
    fixture.environment.files.erase(kDnfPath);
    const RunOutcome outcome = Run(&fixture, {"--list"});
    Expect(outcome.exit_code == 0, "list works without --json");
    ExpectContains(outcome.out,
                   "\"id\":\"dnf-packages\",\"available\":false", "dnf missing");
    ExpectContains(outcome.out, "\"reason\":\"tool_missing\"",
                   "dnf missing reason");
  }
  {
    Fixture fixture;
    fixture.InstallTools();
    FileFacts facts = SecureExecutable();
    facts.owner = 1000;
    fixture.environment.files[kDnfPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--list"});
    ExpectContains(outcome.out, "\"reason\":\"tool_unsafe_owner\"",
                   "non-root tool is rejected");
  }
  {
    Fixture fixture;
    fixture.InstallTools();
    FileFacts facts = SecureExecutable();
    facts.executable = false;
    fixture.environment.files[kJournalctlPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--list"});
    ExpectContains(outcome.out, "\"reason\":\"tool_not_executable\"",
                   "non-executable tool is rejected");
  }
  {
    Fixture fixture;
    fixture.InstallTools();
    FileFacts facts = SecureExecutable();
    facts.mode = 0100775;
    fixture.environment.files[kJournalctlPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--list"});
    ExpectContains(outcome.out, "\"reason\":\"tool_unsafe_permissions\"",
                   "group-writable tool is rejected");
  }
}

void TestRunBoundary() {
  {
    Fixture fixture;
    fixture.environment.uid = 1000;
    const RunOutcome outcome =
        Run(&fixture, {"--run", "dnf-packages,journal-7d", "--json"});
    Expect(outcome.exit_code == 77, "non-root run is rejected");
    ExpectContains(outcome.out, "\"code\":\"permission_denied\"",
                   "non-root error code");
    ExpectContains(outcome.out, "\"exitCode\":77", "non-root exit code");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    fixture.runner.acquire_ok = false;
    const RunOutcome outcome =
        Run(&fixture, {"--run", "dnf-packages,journal-7d", "--json"});
    Expect(outcome.exit_code == 0, "a held lock still returns a report");
    ExpectContains(outcome.out, "\"status\":\"busy\"", "lock reports busy");
    ExpectContains(outcome.out,
                   "\"message\":\"Another system cleanup is already running.\"",
                   "lock reason is reported");
    Expect(fixture.runner.ran.empty(), "no tool runs while the lock is held");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    fixture.InstallTools();
    broom::OperationRunResult dnf;
    dnf.status = broom::OperationStatus::kOk;
    dnf.exit_code = 0;
    dnf.freed_bytes = 4096;
    dnf.message = "packages removed";
    fixture.runner.results["dnf-packages"] = dnf;
    const RunOutcome outcome =
        Run(&fixture, {"--run", "journal-7d,dnf-packages", "--json"});
    Expect(outcome.exit_code == 0, "root run reports success");
    ExpectContains(outcome.out,
                   "\"id\":\"dnf-packages\",\"status\":\"ok\"",
                   "dnf status is ok");
    ExpectContains(outcome.out, "\"freedBytes\":4096",
                   "freed bytes are reported");
    ExpectContains(outcome.out, "\"id\":\"journal-7d\",\"status\":\"ok\"",
                   "journal status is ok");
    Expect(fixture.runner.acquire_calls == 1, "the lock is acquired once");
    Expect(fixture.runner.release_calls == 1, "the lock is released");
    Expect(fixture.runner.ran.size() == 2, "both selected tools run");
    Expect(fixture.runner.ran[0] == "dnf-packages",
           "canonical order starts with dnf");
    Expect(fixture.runner.ran[1] == "journal-7d",
           "canonical order ends with journal");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    fixture.InstallTools();
    fixture.environment.files.erase(kAptGetPath);
    const RunOutcome outcome = Run(&fixture, {"--run", "apt-cache"});
    Expect(outcome.exit_code == 0, "missing tools still produce a report");
    ExpectContains(outcome.out,
                   "\"id\":\"apt-cache\",\"status\":\"unavailable\"",
                   "apt is unavailable");
    ExpectContains(outcome.out, "\"exitCode\":null",
                   "unavailable operations have no exit code");
    Expect(fixture.runner.ran.empty(), "missing tools are never started");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    fixture.InstallTools();
    broom::OperationRunResult failed;
    failed.status = broom::OperationStatus::kFailed;
    failed.exit_code = 100;
    failed.message = "lock is busy";
    fixture.runner.results["dnf-packages"] = failed;
    const RunOutcome outcome =
        Run(&fixture, {"--run", "dnf-packages,journal-7d", "--json"});
    Expect(outcome.exit_code == 0, "partial failures still return a report");
    ExpectContains(outcome.out,
                   "\"id\":\"dnf-packages\",\"status\":\"failed\"",
                   "failed dnf is reported");
    ExpectContains(outcome.out, "\"exitCode\":100", "failure exit code");
    ExpectContains(outcome.out, "\"message\":\"lock is busy\"",
                   "failure message is escaped");
    ExpectContains(outcome.out,
                   "\"id\":\"journal-7d\",\"status\":\"ok\"",
                   "later operations still run");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    const RunOutcome outcome = Run(&fixture, {"--run", "rm-rf"});
    Expect(outcome.exit_code == 64, "unknown operation is rejected");
    ExpectContains(outcome.out, "\"code\":\"unknown_operation\"",
                   "unknown operation code");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    const RunOutcome outcome = Run(&fixture, {"--run", "/var/cache/dnf"});
    Expect(outcome.exit_code == 64, "path in run is rejected");
    ExpectContains(outcome.out, "\"code\":\"invalid_arguments\"",
                   "path is an invalid argument");
  }
  {
    Fixture fixture;
    fixture.environment.uid = 0;
    const RunOutcome outcome =
        Run(&fixture, {"--run", "dnf-packages", "--path", "/var/cache/dnf"});
    Expect(outcome.exit_code == 64, "extra path option is rejected");
    ExpectContains(outcome.out, "\"code\":\"invalid_arguments\"",
                   "extra option is an invalid argument");
  }
}

void TestSelfTest() {
  {
    Fixture fixture;
    fixture.InstallComplete();
    const RunOutcome outcome = Run(&fixture, {"--self-test", "--json"});
    Expect(outcome.exit_code == 0, "complete installation self-test passes");
    ExpectContains(outcome.out, "\"status\":\"ok\"", "self-test ok status");
    ExpectContains(outcome.out,
                   "\"id\":\"helper.install\",\"status\":\"pass\"",
                   "helper permissions pass");
    ExpectContains(outcome.out, "\"id\":\"polkit.pkexec\",\"status\":\"pass\"",
                   "pkexec passes");
    ExpectContains(outcome.out, "\"id\":\"polkit.policy\",\"status\":\"pass\"",
                   "policy passes");
    ExpectContains(outcome.out,
                   "\"id\":\"operation.apt-cache\",\"status\":\"pass\"",
                   "apt passes");
    ExpectContains(outcome.out,
                   "\"id\":\"operation.dnf-packages\",\"status\":\"pass\"",
                   "dnf passes");
    ExpectContains(outcome.out,
                   "\"id\":\"operation.journal-7d\",\"status\":\"pass\"",
                   "journal passes");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    fixture.environment.uid = 1000;
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 0, "self-test does not require root");
    ExpectContains(outcome.out, "\"status\":\"ok\"", "non-root self-test ok");
  }
  {
    Fixture fixture;
    fixture.InstallTools();
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 0, "development build self-test degrades");
    ExpectContains(outcome.out, "\"status\":\"degraded\"",
                   "development build is degraded");
    ExpectContains(outcome.out,
                   "\"id\":\"helper.install\",\"status\":\"warn\"",
                   "development path warns");
    ExpectContains(outcome.out, "\"id\":\"polkit.pkexec\",\"status\":\"warn\"",
                   "missing pkexec warns in development");
    ExpectContains(outcome.out, "\"id\":\"polkit.policy\",\"status\":\"warn\"",
                   "missing policy warns in development");
    ExpectContains(outcome.out,
                   "\"id\":\"operation.dnf-packages\",\"status\":\"pass\"",
                   "available tool still passes");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    FileFacts facts = fixture.environment.files[kHelperPath];
    facts.mode = 0100775;
    fixture.environment.files[kHelperPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 70, "unsafe helper fails self-test");
    ExpectContains(outcome.out, "\"status\":\"failed\"", "failed status");
    ExpectContains(outcome.out,
                   "\"id\":\"helper.install\",\"status\":\"fail\"",
                   "unsafe helper is a failure");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    FileFacts facts = fixture.environment.files[kHelperPath];
    facts.mode = 0104755;
    fixture.environment.files[kHelperPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 70, "setuid helper fails self-test");
    ExpectContains(outcome.out, "\"id\":\"helper.install\",\"status\":\"fail\"",
                   "setuid helper is a failure");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    FileFacts facts = fixture.environment.files[kPkexecPath];
    facts.mode = 0100777;
    fixture.environment.files[kPkexecPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 70, "unsafe pkexec fails self-test");
    ExpectContains(outcome.out, "\"id\":\"polkit.pkexec\",\"status\":\"fail\"",
                   "unsafe pkexec is a failure");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    fixture.environment.contents[kPolicyPath] = "no action here";
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 70, "policy without the action fails");
    ExpectContains(outcome.out, "\"id\":\"polkit.policy\",\"status\":\"fail\"",
                   "missing action is a failure");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    fixture.environment.contents[kPolicyPath] =
        "com.broom.Broom.clean-system-cache /opt/other/helper";
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 70, "policy with a wrong exec path fails");
    ExpectContains(outcome.out, "\"id\":\"polkit.policy\",\"status\":\"fail\"",
                   "wrong exec path is a failure");
  }
  {
    Fixture fixture;
    fixture.InstallComplete();
    FileFacts facts = SecureExecutable();
    facts.owner = 1000;
    fixture.environment.files[kDnfPath] = facts;
    const RunOutcome outcome = Run(&fixture, {"--self-test"});
    Expect(outcome.exit_code == 70, "unsafe operation tool fails self-test");
    ExpectContains(outcome.out,
                   "\"id\":\"operation.dnf-packages\",\"status\":\"fail\"",
                   "unsafe dnf is a failure");
  }
}

void TestSystemRunner() {
  const std::unique_ptr<broom::OperationRunner> runner =
      broom::CreateSystemOperationRunner();
  {
    const broom::OperationSpec operation{"test-ok", "/usr/bin/true", {}, {},
                                         "/tmp", 5};
    const broom::OperationRunResult result = runner->Run(operation);
    Expect(result.status == broom::OperationStatus::kOk, "true succeeds");
    Expect(result.exit_code == 0, "true exit code");
  }
  {
    const broom::OperationSpec operation{"test-fail", "/usr/bin/false", {}, {},
                                         "/tmp", 5};
    const broom::OperationRunResult result = runner->Run(operation);
    Expect(result.status == broom::OperationStatus::kFailed, "false fails");
    Expect(result.exit_code == 1, "false exit code");
    ExpectContains(result.message, "exit code 1", "failure message");
  }
  {
    const broom::OperationSpec operation{
        "test-timeout", "/usr/bin/sleep", {"5"}, {}, "/tmp", 1};
    const broom::OperationRunResult result = runner->Run(operation);
    Expect(result.status == broom::OperationStatus::kFailed,
           "timeout is a failure");
    ExpectContains(result.message, "timed out", "timeout message");
  }
}

void TestArgumentErrorsAndHelp() {
  {
    Fixture fixture;
    const RunOutcome outcome = Run(&fixture, {"--list", "--bogus"});
    Expect(outcome.exit_code == 64, "unknown option exits with usage");
    ExpectContains(outcome.out, "\"code\":\"invalid_arguments\"",
                   "unknown option JSON error");
    ExpectContains(outcome.err, "Try 'broom-system-helper --help'",
                   "usage hint is printed");
  }
  {
    Fixture fixture;
    const RunOutcome outcome = Run(&fixture, {"--help"});
    Expect(outcome.exit_code == 0, "help succeeds");
    ExpectContains(outcome.out, "Usage:", "help has usage");
    ExpectContains(outcome.out, "--self-test", "help lists self-test");
    ExpectContains(outcome.out, "--run", "help lists run");
    ExpectContains(outcome.out, "apt-cache", "help lists apt-cache");
    Expect(outcome.out.find("\"schemaVersion\"") == std::string::npos,
           "help is not JSON");
  }
}

void TestJsonQuoting() {
  ExpectString(broom::JsonQuote("plain"), "\"plain\"", "plain JSON string");
  ExpectString(broom::JsonQuote("a\"b\\c\n\t"), "\"a\\\"b\\\\c\\n\\t\"",
               "quotes, backslashes and newlines are escaped");
  ExpectString(broom::JsonQuote(std::string("\x01", 1)), "\"\\u0001\"",
               "control characters are escaped");
  const std::string error =
      broom::ErrorJson("bad\"code", "line\nbreak", 64);
  ExpectContains(error, "\"code\":\"bad\\\"code\"", "error code is escaped");
  ExpectContains(error, "\"message\":\"line\\nbreak\"",
                 "error message is escaped");
  ExpectContains(error, "\"exitCode\":64", "error carries the exit code");
}

}  // namespace

int main() {
  TestParseArguments();
  TestOperationSelection();
  TestList();
  TestRunBoundary();
  TestSelfTest();
  TestSystemRunner();
  TestArgumentErrorsAndHelp();
  TestJsonQuoting();

  if (g_failures != 0) {
    std::cerr << g_failures << " assertion(s) failed\n";
    return 1;
  }
  std::cout << "All system helper tests passed\n";
  return 0;
}
