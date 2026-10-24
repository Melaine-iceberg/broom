#include "runner.h"

#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string>
#include <sys/file.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace broom {
namespace {

constexpr char kLockPath[] = "/run/broom-system-helper.lock";
constexpr std::size_t kMaxCapturedBytes = 1024 * 1024;
constexpr std::size_t kMaxMessageBytes = 500;
constexpr std::size_t kMaxSnapNameBytes = 64;
constexpr std::size_t kMaxSnapRevisionBytes = 16;

long long AvailableBytes(const std::string& path) {
  struct statvfs status {};
  if (statvfs(path.c_str(), &status) != 0) return -1;
  const auto block_size = static_cast<long long>(status.f_frsize);
  const auto available = static_cast<long long>(status.f_bavail);
  if (block_size <= 0 || available < 0) return -1;
  return available * block_size;
}

std::string Trimmed(std::string value) {
  const auto is_space = [](unsigned char character) {
    return std::isspace(character) != 0;
  };
  while (!value.empty() &&
         is_space(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
  }
  std::size_t start = 0;
  while (start < value.size() &&
         is_space(static_cast<unsigned char>(value[start]))) {
    ++start;
  }
  return value.substr(start);
}

std::string Summarize(const std::string& text) {
  const std::string trimmed = Trimmed(text);
  if (trimmed.empty()) return std::string();
  if (trimmed.size() <= kMaxMessageBytes) return trimmed;
  return trimmed.substr(0, kMaxMessageBytes) + "...";
}

std::string Lowercase(std::string value) {
  for (char& character : value) {
    character = static_cast<char>(
        std::tolower(static_cast<unsigned char>(character)));
  }
  return value;
}

bool LooksBusy(const std::string& stderr_text) {
  const std::string lower = Lowercase(stderr_text);
  return lower.find("could not get lock") != std::string::npos ||
         lower.find("unable to lock database") != std::string::npos ||
         lower.find("failed to init transaction") != std::string::npos ||
         lower.find("failed to obtain the transaction lock") !=
             std::string::npos ||
         lower.find("system management is locked") != std::string::npos ||
         lower.find("failed to lock file") != std::string::npos ||
         lower.find("is held by process") != std::string::npos ||
         lower.find("waiting for process") != std::string::npos ||
         lower.find("change in progress") != std::string::npos ||
         lower.find("snapd is not responding") != std::string::npos;
}

void SetNonBlocking(int descriptor) {
  const int flags = fcntl(descriptor, F_GETFL, 0);
  if (flags >= 0) {
    (void)fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
  }
}

// Reads everything currently available. Returns true when the pipe reached EOF
// (or failed), false when it is merely empty for now.
bool DrainPipe(int descriptor, std::string* capture) {
  char buffer[65536];
  while (true) {
    const ssize_t length = read(descriptor, buffer, sizeof(buffer));
    if (length > 0) {
      const std::size_t size = static_cast<std::size_t>(length);
      const std::size_t remaining =
          kMaxCapturedBytes > capture->size()
              ? kMaxCapturedBytes - capture->size()
              : 0;
      if (remaining > 0) {
        capture->append(buffer, size < remaining ? size : remaining);
      }
      continue;
    }
    if (length == 0) return true;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return false;
    return true;
  }
}

std::string FailureMessage(const std::string& stderr_text, int exit_code) {
  const std::string summary = Summarize(stderr_text);
  if (!summary.empty()) return "Operation failed: " + summary;
  return "Operation failed with exit code " + std::to_string(exit_code) + ".";
}

// One child process invocation. A setup_error means the process could not be
// started at all; otherwise timed_out or wait_status describe the result.
struct ProcessOutcome {
  std::string setup_error;
  bool exited = false;
  bool timed_out = false;
  int wait_status = 0;
  std::string stdout_text;
  std::string stderr_text;
};

std::vector<std::string> BuildArguments(const OperationSpec& operation) {
  std::vector<std::string> arguments;
  arguments.push_back(operation.binary_path);
  for (const char* argument : operation.arguments) {
    arguments.emplace_back(argument);
  }
  return arguments;
}

std::vector<std::string> BuildEnvironment(const OperationSpec& operation) {
  std::vector<std::string> environment;
  environment.emplace_back("PATH=/usr/sbin:/usr/bin:/sbin:/bin");
  environment.emplace_back("LC_ALL=C");
  environment.emplace_back("LANG=C");
  environment.emplace_back("HOME=/");
  for (const char* entry : operation.environment) {
    environment.emplace_back(entry);
  }
  return environment;
}

ProcessOutcome Execute(const std::string& binary_path,
                       const std::vector<std::string>& arguments,
                       const std::vector<std::string>& environment,
                       unsigned int timeout_seconds) {
  ProcessOutcome outcome;

  std::vector<char*> argument_pointers;
  argument_pointers.reserve(arguments.size() + 1);
  for (const std::string& argument : arguments) {
    argument_pointers.push_back(const_cast<char*>(argument.c_str()));
  }
  argument_pointers.push_back(nullptr);

  std::vector<char*> environment_pointers;
  environment_pointers.reserve(environment.size() + 1);
  for (const std::string& entry : environment) {
    environment_pointers.push_back(const_cast<char*>(entry.c_str()));
  }
  environment_pointers.push_back(nullptr);

  int output_pipe[2] = {-1, -1};
  int error_pipe[2] = {-1, -1};
  if (pipe(output_pipe) != 0 || pipe(error_pipe) != 0) {
    if (output_pipe[0] >= 0) {
      (void)close(output_pipe[0]);
      (void)close(output_pipe[1]);
    }
    outcome.setup_error = "Cannot create a pipe for the system tool.";
    return outcome;
  }

  const pid_t child = fork();
  if (child < 0) {
    (void)close(output_pipe[0]);
    (void)close(output_pipe[1]);
    (void)close(error_pipe[0]);
    (void)close(error_pipe[1]);
    outcome.setup_error = "Cannot start the system tool.";
    return outcome;
  }

  if (child == 0) {
    (void)setpgid(0, 0);
    (void)dup2(output_pipe[1], STDOUT_FILENO);
    (void)dup2(error_pipe[1], STDERR_FILENO);
    (void)close(output_pipe[0]);
    (void)close(output_pipe[1]);
    (void)close(error_pipe[0]);
    (void)close(error_pipe[1]);
    execve(binary_path.c_str(), argument_pointers.data(),
           environment_pointers.data());
    _exit(127);
  }

  (void)setpgid(child, child);
  (void)close(output_pipe[1]);
  (void)close(error_pipe[1]);
  SetNonBlocking(output_pipe[0]);
  SetNonBlocking(error_pipe[0]);

  bool stdout_open = true;
  bool error_open = true;
  int status = 0;
  const auto deadline =
      std::chrono::steady_clock::now() +
      std::chrono::seconds(timeout_seconds);

  while (!(outcome.exited && !stdout_open && !error_open)) {
    if (std::chrono::steady_clock::now() >= deadline) {
      outcome.timed_out = true;
      break;
    }

    struct pollfd descriptors[2] = {};
    nfds_t count = 0;
    if (stdout_open) {
      descriptors[count].fd = output_pipe[0];
      descriptors[count].events = POLLIN;
      ++count;
    }
    if (error_open) {
      descriptors[count].fd = error_pipe[0];
      descriptors[count].events = POLLIN;
      ++count;
    }

    const int ready = poll(descriptors, count, 100);
    if (ready > 0) {
      for (nfds_t index = 0; index < count; ++index) {
        if (descriptors[index].revents == 0) continue;
        if (descriptors[index].fd == output_pipe[0]) {
          if (DrainPipe(output_pipe[0], &outcome.stdout_text)) {
            stdout_open = false;
          }
        } else {
          if (DrainPipe(error_pipe[0], &outcome.stderr_text)) {
            error_open = false;
          }
        }
      }
    }

    if (!outcome.exited) {
      const pid_t waited = waitpid(child, &status, WNOHANG);
      if (waited == child) outcome.exited = true;
    }
  }

  if (outcome.timed_out) {
    (void)kill(-child, SIGKILL);
    (void)kill(child, SIGKILL);
    const auto reap_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (true) {
      const pid_t waited = waitpid(child, &status, WNOHANG);
      if (waited == child || (waited < 0 && errno == ECHILD)) break;
      if (std::chrono::steady_clock::now() >= reap_deadline) break;
      (void)usleep(10000);
    }
  } else if (!outcome.exited) {
    (void)waitpid(child, &status, 0);
    outcome.exited = true;
  }

  if (stdout_open) {
    (void)DrainPipe(output_pipe[0], &outcome.stdout_text);
  }
  if (error_open) {
    (void)DrainPipe(error_pipe[0], &outcome.stderr_text);
  }
  (void)close(output_pipe[0]);
  (void)close(error_pipe[0]);

  outcome.wait_status = status;
  return outcome;
}

OperationRunResult FailedResult(std::string message) {
  OperationRunResult result;
  result.status = OperationStatus::kFailed;
  result.message = std::move(message);
  return result;
}

OperationRunResult MapOutcome(const ProcessOutcome& outcome) {
  OperationRunResult result;
  if (!outcome.setup_error.empty()) {
    return FailedResult(outcome.setup_error);
  }
  if (outcome.timed_out) {
    return FailedResult(
        "Operation timed out; its process group was terminated.");
  }
  if (!outcome.exited || !WIFEXITED(outcome.wait_status)) {
    if (WIFSIGNALED(outcome.wait_status)) {
      result.status = OperationStatus::kFailed;
      result.exit_code = 128 + WTERMSIG(outcome.wait_status);
      result.message = "Operation was terminated by signal " +
                       std::to_string(WTERMSIG(outcome.wait_status)) + ".";
    } else {
      result = FailedResult("Operation did not finish normally.");
    }
    return result;
  }

  const int exit_code = WEXITSTATUS(outcome.wait_status);
  result.exit_code = exit_code;
  if (exit_code == 0) {
    result.status = OperationStatus::kOk;
    result.message = "Operation completed.";
    return result;
  }
  if (exit_code == 127) {
    result.status = OperationStatus::kFailed;
    result.message = "The system tool could not be started.";
    return result;
  }
  if (LooksBusy(outcome.stderr_text)) {
    result.status = OperationStatus::kBusy;
    result.message =
        "The package manager is in use; try again after it finishes.";
    return result;
  }
  result = FailedResult(FailureMessage(outcome.stderr_text, exit_code));
  result.exit_code = exit_code;
  return result;
}

bool SafeSnapName(const std::string& name) {
  if (name.empty() || name.size() > kMaxSnapNameBytes) return false;
  for (std::size_t index = 0; index < name.size(); ++index) {
    const unsigned char character = static_cast<unsigned char>(name[index]);
    const bool lowercase = character >= 'a' && character <= 'z';
    const bool digit = character >= '0' && character <= '9';
    if (index == 0) {
      if (!lowercase && !digit) return false;
      continue;
    }
    if (!lowercase && !digit && character != '-') return false;
  }
  return true;
}

bool SafeSnapRevision(const std::string& revision) {
  if (revision.empty() || revision.size() > kMaxSnapRevisionBytes) {
    return false;
  }
  for (const char character : revision) {
    if (character < '0' || character > '9') return false;
  }
  return true;
}

std::vector<std::string> SplitWhitespace(const std::string& line) {
  std::vector<std::string> fields;
  std::size_t index = 0;
  while (index < line.size()) {
    while (index < line.size() &&
           std::isspace(static_cast<unsigned char>(line[index])) != 0) {
      ++index;
    }
    const std::size_t start = index;
    while (index < line.size() &&
           std::isspace(static_cast<unsigned char>(line[index])) == 0) {
      ++index;
    }
    if (index > start) fields.push_back(line.substr(start, index - start));
  }
  return fields;
}

// Snap notes are a single column that may list comma-separated flags.
bool HasDisabledNote(const std::string& notes) {
  std::size_t start = 0;
  while (start <= notes.size()) {
    const std::size_t comma = notes.find(',', start);
    const std::size_t end = comma == std::string::npos ? notes.size() : comma;
    if (notes.substr(start, end - start) == "disabled") return true;
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  return false;
}

unsigned int RemainingSeconds(
    const std::chrono::steady_clock::time_point& deadline) {
  const auto left = deadline - std::chrono::steady_clock::now();
  if (left.count() <= 0) return 0;
  const auto seconds =
      std::chrono::duration_cast<std::chrono::seconds>(left).count();
  if (seconds <= 0) return 1;
  return static_cast<unsigned int>(seconds);
}

class SystemOperationRunner final : public OperationRunner {
 public:
  ~SystemOperationRunner() override { Release(); }

  bool TryAcquire(std::string* reason) override {
    if (lock_fd_ >= 0) return true;
    const int descriptor =
        open(kLockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (descriptor < 0) {
      if (reason != nullptr) {
        *reason = "Cannot open the cleanup lock: " +
                  std::string(std::strerror(errno)) + ".";
      }
      return false;
    }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
      const int error = errno;
      (void)close(descriptor);
      if (reason != nullptr) {
        *reason = error == EWOULDBLOCK
                      ? "Another system cleanup is already running."
                      : "Cannot lock the cleanup state: " +
                            std::string(std::strerror(error)) + ".";
      }
      return false;
    }
    lock_fd_ = descriptor;
    return true;
  }

  void Release() override {
    if (lock_fd_ < 0) return;
    (void)flock(lock_fd_, LOCK_UN);
    (void)close(lock_fd_);
    lock_fd_ = -1;
  }

  OperationRunResult Run(const OperationSpec& operation) override {
    long long before = AvailableBytes(operation.storage_path);
    if (before < 0) before = AvailableBytes("/");

    const std::vector<std::string> environment = BuildEnvironment(operation);
    OperationRunResult result =
        operation.kind == OperationKind::kSnapRevisions
            ? RunSnapRevisions(operation, environment)
            : MapOutcome(Execute(operation.binary_path, BuildArguments(operation),
                                 environment, operation.timeout_seconds));

    long long after = AvailableBytes(operation.storage_path);
    if (after < 0) after = AvailableBytes("/");
    if (before >= 0 && after >= 0) {
      const long long freed = after - before;
      result.freed_bytes = freed > 0 ? freed : 0;
    }
    return result;
  }

 private:
  OperationRunResult RunSnapRevisions(
      const OperationSpec& operation,
      const std::vector<std::string>& environment) {
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(operation.timeout_seconds);

    unsigned int timeout = RemainingSeconds(deadline);
    if (timeout == 0) {
      return FailedResult(
          "Operation timed out; its process group was terminated.");
    }
    ProcessOutcome listing =
        Execute(operation.binary_path, BuildArguments(operation), environment,
                timeout);
    if (!listing.setup_error.empty() || listing.timed_out ||
        !listing.exited || !WIFEXITED(listing.wait_status)) {
      return MapOutcome(listing);
    }
    if (WEXITSTATUS(listing.wait_status) != 0) {
      const int exit_code = WEXITSTATUS(listing.wait_status);
      if (LooksBusy(listing.stderr_text)) {
        OperationRunResult result;
        result.status = OperationStatus::kBusy;
        result.exit_code = exit_code;
        result.message =
            "The package manager is in use; try again after it finishes.";
        return result;
      }
      const std::string summary = Summarize(listing.stderr_text);
      OperationRunResult result = FailedResult(
          summary.empty()
              ? "Could not list snap revisions: exit code " +
                    std::to_string(exit_code) + "."
              : "Could not list snap revisions: " + summary);
      result.exit_code = exit_code;
      return result;
    }

    const std::vector<SnapRevision> revisions =
        ParseDisabledSnapRevisions(listing.stdout_text);
    if (revisions.empty()) {
      OperationRunResult result;
      result.status = OperationStatus::kOk;
      result.exit_code = 0;
      result.message = "No disabled snap revisions were found.";
      return result;
    }

    std::size_t removed = 0;
    std::string first_failure;
    int first_failure_exit = -1;
    bool first_failure_busy = false;
    bool timed_out = false;

    for (const SnapRevision& revision : revisions) {
      timeout = RemainingSeconds(deadline);
      if (timeout == 0) {
        timed_out = true;
        break;
      }
      std::vector<std::string> arguments;
      arguments.emplace_back(operation.binary_path);
      arguments.emplace_back("remove");
      arguments.emplace_back(revision.name);
      arguments.emplace_back("--revision=" + revision.revision);
      ProcessOutcome removal =
          Execute(operation.binary_path, arguments, environment, timeout);
      const bool succeeded =
          removal.setup_error.empty() && !removal.timed_out &&
          removal.exited && WIFEXITED(removal.wait_status) &&
          WEXITSTATUS(removal.wait_status) == 0;
      if (succeeded) {
        ++removed;
        continue;
      }
      if (first_failure.empty()) {
        if (!removal.setup_error.empty()) {
          first_failure = removal.setup_error;
        } else if (removal.timed_out) {
          timed_out = true;
          first_failure = "Removing " + revision.name + " timed out.";
        } else if (removal.exited && WIFEXITED(removal.wait_status)) {
          first_failure_exit = WEXITSTATUS(removal.wait_status);
          first_failure_busy = LooksBusy(removal.stderr_text);
          first_failure =
              FailureMessage(removal.stderr_text, first_failure_exit);
        } else {
          first_failure = "Removing " + revision.name + " did not finish.";
        }
      }
      if (removal.timed_out) break;
    }

    OperationRunResult result;
    if (timed_out) {
      result.status = OperationStatus::kFailed;
      result.exit_code = first_failure_exit;
      result.message =
          "Removed " + std::to_string(removed) + " of " +
          std::to_string(revisions.size()) +
          " disabled snap revisions before the operation timed out.";
      if (!first_failure.empty()) result.message += " " + first_failure;
    } else if (first_failure.empty()) {
      result.status = OperationStatus::kOk;
      result.exit_code = 0;
      result.message =
          "Removed " + std::to_string(removed) + " disabled snap revision" +
          (removed == 1 ? "." : "s.");
    } else if (removed == 0 && first_failure_busy) {
      result.status = OperationStatus::kBusy;
      result.exit_code = first_failure_exit;
      result.message =
          "The package manager is in use; try again after it finishes.";
    } else {
      result.status = OperationStatus::kFailed;
      result.exit_code = first_failure_exit;
      result.message = "Removed " + std::to_string(removed) + " of " +
                       std::to_string(revisions.size()) +
                       " disabled snap revisions: " + first_failure;
    }
    return result;
  }

  int lock_fd_ = -1;
};

}  // namespace

const char* OperationStatusName(OperationStatus status) {
  switch (status) {
    case OperationStatus::kOk:
      return "ok";
    case OperationStatus::kFailed:
      return "failed";
    case OperationStatus::kBusy:
      return "busy";
    case OperationStatus::kSkipped:
      return "skipped";
    case OperationStatus::kUnavailable:
      return "unavailable";
  }
  return "failed";
}

std::vector<SnapRevision> ParseDisabledSnapRevisions(const std::string& output) {
  std::vector<SnapRevision> revisions;
  std::vector<std::string> seen;
  std::size_t start = 0;
  while (start < output.size()) {
    const std::size_t newline = output.find('\n', start);
    const std::size_t end =
        newline == std::string::npos ? output.size() : newline;
    std::string line = output.substr(start, end - start);
    start = end + 1;
    if (!line.empty() && line.back() == '\r') line.pop_back();

    // Name, Version, Rev, Tracking, Publisher, Notes. Requiring exactly six
    // fields avoids trusting a revision column when snap changes the layout.
    const std::vector<std::string> fields = SplitWhitespace(line);
    if (fields.size() != 6) continue;
    if (!SafeSnapName(fields[0])) continue;
    if (!SafeSnapRevision(fields[2])) continue;
    if (!HasDisabledNote(fields.back())) continue;

    const std::string key = fields[0] + "/" + fields[2];
    bool duplicate = false;
    for (const std::string& existing : seen) {
      if (existing == key) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) continue;
    seen.push_back(key);

    SnapRevision revision;
    revision.name = fields[0];
    revision.revision = fields[2];
    revisions.push_back(std::move(revision));
  }
  return revisions;
}

std::unique_ptr<OperationRunner> CreateSystemOperationRunner() {
  return std::make_unique<SystemOperationRunner>();
}

}  // namespace broom
