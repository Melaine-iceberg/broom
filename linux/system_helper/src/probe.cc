#include "probe.h"

#include <array>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace broom {
namespace {

class PosixEnvironment final : public Environment {
 public:
  FileFacts Inspect(const std::string& path) const override {
    struct stat status {};
    if (stat(path.c_str(), &status) != 0) return FileFacts{};

    FileFacts facts;
    facts.exists = true;
    facts.is_regular = S_ISREG(status.st_mode);
    facts.executable = (status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
    facts.owner = status.st_uid;
    facts.mode = status.st_mode;
    return facts;
  }

  bool ReadFile(const std::string& path,
                std::size_t max_bytes,
                std::string* contents) const override {
    if (contents == nullptr) return false;

    struct stat status {};
    if (stat(path.c_str(), &status) != 0) return false;
    if (!S_ISREG(status.st_mode)) return false;
    if (status.st_size < 0 ||
        static_cast<std::size_t>(status.st_size) > max_bytes) {
      return false;
    }

    const auto size = static_cast<std::size_t>(status.st_size);
    std::string data(size, '\0');
    if (size == 0) {
      contents->clear();
      return true;
    }

    std::ifstream input(path, std::ios::binary);
    if (!input) return false;
    input.read(data.data(), static_cast<std::streamsize>(size));
    if (!input || input.gcount() != static_cast<std::streamsize>(size)) {
      return false;
    }
    *contents = std::move(data);
    return true;
  }

  uid_t EffectiveUid() const override { return geteuid(); }

  std::string SelfPath() const override {
    std::array<char, 4096> buffer {};
    const ssize_t length =
        readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
    if (length <= 0) return std::string();
    return std::string(buffer.data(), static_cast<std::size_t>(length));
  }
};

}  // namespace

std::unique_ptr<Environment> CreatePosixEnvironment() {
  return std::make_unique<PosixEnvironment>();
}

}  // namespace broom
