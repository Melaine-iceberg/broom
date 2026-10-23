#ifndef BROOM_SYSTEM_HELPER_PROBE_H_
#define BROOM_SYSTEM_HELPER_PROBE_H_

#include <cstddef>
#include <memory>
#include <string>
#include <sys/types.h>

namespace broom {

struct FileFacts {
  bool exists = false;
  bool is_regular = false;
  bool executable = false;
  uid_t owner = 0;
  mode_t mode = 0;
};

// Narrow read-only view of the host filesystem. Tests inject a fake so the
// ownership and permission rules can be exercised without root.
class Environment {
 public:
  virtual ~Environment() = default;

  virtual FileFacts Inspect(const std::string& path) const = 0;

  // Reads at most `max_bytes`; returns false when the path is missing, is not
  // a regular file, exceeds the limit, or cannot be read completely.
  virtual bool ReadFile(const std::string& path,
                        std::size_t max_bytes,
                        std::string* contents) const = 0;

  virtual uid_t EffectiveUid() const = 0;

  virtual std::string SelfPath() const = 0;
};

std::unique_ptr<Environment> CreatePosixEnvironment();

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_PROBE_H_
