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
         lower.find("failed to obtain the transaction lock") !=
             std::string::npos ||
         lower.find("is held by process") != std::string::npos ||
         lower.find("waiting for process") != std::string::npos;
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
    OperationRunResult result;

    long long before = AvailableBytes(operation.storage_path);
    if (before < 0) before = AvailableBytes("/");

    std::vector<std::string> arguments;
    arguments.push_back(operation.binary_path);
    for (const char* argument : operation.arguments) {
      arguments.emplace_back(argument);
    }
    std::vector<char*> argument_pointers;
    argument_pointers.reserve(arguments.size() + 1);
    for (std::string& argument : arguments) {
      argument_pointers.push_back(argument.data());
    }
    argument_pointers.push_back(nullptr);

    std::vector<std::string> environment;
    environment.emplace_back("PATH=/usr/sbin:/usr/bin:/sbin:/bin");
    environment.emplace_back("LC_ALL=C");
    environment.emplace_back("LANG=C");
    environment.emplace_back("HOME=/");
    for (const char* entry : operation.environment) {
      environment.emplace_back(entry);
    }
    std::vector<char*> environment_pointers;
    environment_pointers.reserve(environment.size() + 1);
    for (std::string& entry : environment) {
      environment_pointers.push_back(entry.data());
    }
    environment_pointers.push_back(nullptr);

    int output_pipe[2] = {-1, -1};
    int error_pipe[2] = {-1, -1};
    if (pipe(output_pipe) != 0 || pipe(error_pipe) != 0) {
      if (output_pipe[0] >= 0) {
        (void)close(output_pipe[0]);
        (void)close(output_pipe[1]);
      }
      result.status = OperationStatus::kFailed;
      result.message = "Cannot create a pipe for the system tool.";
      return result;
    }

    const pid_t child = fork();
    if (child < 0) {
      (void)close(output_pipe[0]);
      (void)close(output_pipe[1]);
      (void)close(error_pipe[0]);
      (void)close(error_pipe[1]);
      result.status = OperationStatus::kFailed;
      result.message = "Cannot start the system tool.";
      return result;
    }

    if (child == 0) {
      (void)setpgid(0, 0);
      (void)dup2(output_pipe[1], STDOUT_FILENO);
      (void)dup2(error_pipe[1], STDERR_FILENO);
      (void)close(output_pipe[0]);
      (void)close(output_pipe[1]);
      (void)close(error_pipe[0]);
      (void)close(error_pipe[1]);
      execve(operation.binary_path, argument_pointers.data(),
             environment_pointers.data());
      _exit(127);
    }

    (void)setpgid(child, child);
    (void)close(output_pipe[1]);
    (void)close(error_pipe[1]);
    SetNonBlocking(output_pipe[0]);
    SetNonBlocking(error_pipe[0]);

    std::string stdout_text;
    std::string stderr_text;
    bool stdout_open = true;
    bool error_open = true;
    bool exited = false;
    bool timed_out = false;
    int status = 0;
    const auto deadline =
        std::chrono::steady_clock::now() +
        std::chrono::seconds(operation.timeout_seconds);

    while (!(exited && !stdout_open && !error_open)) {
      if (std::chrono::steady_clock::now() >= deadline) {
        timed_out = true;
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
            if (DrainPipe(output_pipe[0], &stdout_text)) stdout_open = false;
          } else {
            if (DrainPipe(error_pipe[0], &stderr_text)) error_open = false;
          }
        }
      }

      if (!exited) {
        const pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) exited = true;
      }
    }

    if (timed_out) {
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
    } else if (!exited) {
      (void)waitpid(child, &status, 0);
      exited = true;
    }

    if (stdout_open) {
      (void)DrainPipe(output_pipe[0], &stdout_text);
    }
    if (error_open) {
      (void)DrainPipe(error_pipe[0], &stderr_text);
    }
    (void)close(output_pipe[0]);
    (void)close(error_pipe[0]);

    long long after = AvailableBytes(operation.storage_path);
    if (after < 0) after = AvailableBytes("/");
    if (before >= 0 && after >= 0) {
      const long long freed = after - before;
      result.freed_bytes = freed > 0 ? freed : 0;
    }

    if (timed_out) {
      result.status = OperationStatus::kFailed;
      result.message =
          "Operation timed out; its process group was terminated.";
      return result;
    }

    if (!exited || !WIFEXITED(status)) {
      result.status = OperationStatus::kFailed;
      if (WIFSIGNALED(status)) {
        result.exit_code = 128 + WTERMSIG(status);
        result.message = "Operation was terminated by signal " +
                         std::to_string(WTERMSIG(status)) + ".";
      } else {
        result.message = "Operation did not finish normally.";
      }
      return result;
    }

    const int exit_code = WEXITSTATUS(status);
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
    if (LooksBusy(stderr_text)) {
      result.status = OperationStatus::kBusy;
      result.message =
          "The package manager is in use; try again after it finishes.";
      return result;
    }
    result.status = OperationStatus::kFailed;
    result.message = FailureMessage(stderr_text, exit_code);
    return result;
  }

 private:
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

std::unique_ptr<OperationRunner> CreateSystemOperationRunner() {
  return std::make_unique<SystemOperationRunner>();
}

}  // namespace broom
