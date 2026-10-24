#ifndef RUNNER_TRASH_H_
#define RUNNER_TRASH_H_

#include <cstdint>

struct TrashSummary {
  int64_t item_count = 0;
  int64_t total_bytes = 0;
};

// Read-only scan of the current user's freedesktop Trash directories.
// Returns false and sets `error_number` when the home trash cannot be read.
bool QueryUserTrash(TrashSummary* summary, int* error_number);

// Permanently deletes the contents of the current user's trash directories.
// Trash directories themselves are preserved. Returns false on the first
// deletion error and sets `error_number`; remaining directories are still
// attempted.
bool EmptyUserTrash(int* error_number);

#endif  // RUNNER_TRASH_H_
