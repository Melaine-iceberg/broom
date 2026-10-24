#include "trash.h"

#include <mntent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include <glib/gstdio.h>

namespace {

// The trash layout is defined by the freedesktop.org Trash specification:
// $XDG_DATA_HOME/Trash plus per-mount .Trash/$uid or .Trash-$uid directories.
// Every path is discovered here; the UI never supplies one. Symbolic links are
// never followed, and emptying only walks the `files` and `info` children of a
// directory that was itself identified as a trash root.

std::string HomeTrashDirectory() {
  g_autofree gchar* path =
      g_build_filename(g_get_user_data_dir(), "Trash", nullptr);
  return path;
}

bool IsRealDirectory(const std::string& path, struct stat* info) {
  return g_lstat(path.c_str(), info) == 0 && S_ISDIR(info->st_mode);
}

// A trash root must belong to the current user and must not be writable by
// other users. This mirrors the ownership requirements in the Trash spec and
// prevents a shared volume from pointing Broom at somebody else's directory.
bool IsUserTrashDirectory(const std::string& path, struct stat* info) {
  if (!IsRealDirectory(path, info)) return false;
  return info->st_uid == getuid() &&
         (info->st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

void AddTrashDirectory(const std::string& path,
                       std::vector<std::string>* directories,
                       std::set<std::string>* seen) {
  struct stat info;
  if (!IsUserTrashDirectory(path, &info)) return;
  if (seen->insert(path).second) directories->push_back(path);
}

// /proc/self/mounts escapes spaces and other special characters as octal.
std::string UnescapeMountPath(const char* raw) {
  std::string path;
  for (const char* character = raw; *character != '\0'; ++character) {
    if (*character == '\\' && character[1] >= '0' && character[1] <= '3' &&
        character[2] >= '0' && character[2] <= '7' && character[3] >= '0' &&
        character[3] <= '7') {
      path.push_back(static_cast<char>((character[1] - '0') * 64 +
                                       (character[2] - '0') * 8 +
                                       (character[3] - '0')));
      character += 3;
    } else {
      path.push_back(*character);
    }
  }
  return path;
}

std::vector<std::string> CollectTrashDirectories() {
  std::vector<std::string> directories;
  std::set<std::string> seen;
  AddTrashDirectory(HomeTrashDirectory(), &directories, &seen);

  const uid_t uid = getuid();
  FILE* mounts = setmntent("/proc/self/mounts", "r");
  if (mounts != nullptr) {
    while (struct mntent* entry = getmntent(mounts)) {
      const std::string mount_path = UnescapeMountPath(entry->mnt_dir);
      if (mount_path.empty()) continue;

      // The shared .Trash directory must be sticky; its per-user child is the
      // actual trash root. Some file managers use .Trash-$uid instead.
      g_autofree gchar* shared =
          g_build_filename(mount_path.c_str(), ".Trash", nullptr);
      struct stat shared_info;
      if (g_lstat(shared, &shared_info) == 0 && S_ISDIR(shared_info.st_mode) &&
          (shared_info.st_mode & S_ISVTX) != 0) {
        g_autofree gchar* uid_text =
            g_strdup_printf("%u", static_cast<unsigned>(uid));
        g_autofree gchar* per_uid =
            g_build_filename(shared, uid_text, nullptr);
        AddTrashDirectory(per_uid, &directories, &seen);
      }

      g_autofree gchar* per_user_name =
          g_strdup_printf(".Trash-%u", static_cast<unsigned>(uid));
      g_autofree gchar* per_user =
          g_build_filename(mount_path.c_str(), per_user_name, nullptr);
      AddTrashDirectory(per_user, &directories, &seen);
    }
    endmntent(mounts);
  }
  return directories;
}

void SumTreeBytes(const std::string& path, int64_t* total_bytes) {
  struct stat info;
  if (g_lstat(path.c_str(), &info) != 0) return;
  if (S_ISREG(info.st_mode)) {
    *total_bytes += static_cast<int64_t>(info.st_size);
    return;
  }
  if (!S_ISDIR(info.st_mode)) return;

  GDir* directory = g_dir_open(path.c_str(), 0, nullptr);
  if (directory == nullptr) return;
  while (const gchar* name = g_dir_read_name(directory)) {
    g_autofree gchar* child = g_build_filename(path.c_str(), name, nullptr);
    SumTreeBytes(child, total_bytes);
  }
  g_dir_close(directory);
}

void MeasureTrash(const std::string& trash_root,
                  int64_t* item_count,
                  int64_t* total_bytes,
                  int* error_number) {
  struct stat root_info;
  if (!IsUserTrashDirectory(trash_root, &root_info)) return;

  g_autofree gchar* files =
      g_build_filename(trash_root.c_str(), "files", nullptr);
  struct stat files_info;
  if (!IsRealDirectory(files, &files_info)) return;

  GDir* directory = g_dir_open(files, 0, nullptr);
  if (directory == nullptr) {
    if (errno != ENOENT && error_number != nullptr && *error_number == 0) {
      *error_number = errno;
    }
    return;
  }
  while (const gchar* name = g_dir_read_name(directory)) {
    g_autofree gchar* child = g_build_filename(files, name, nullptr);
    struct stat info;
    if (g_lstat(child, &info) != 0) continue;
    if (S_ISREG(info.st_mode) || S_ISDIR(info.st_mode) ||
        S_ISLNK(info.st_mode)) {
      *item_count += 1;
      if (!S_ISLNK(info.st_mode)) SumTreeBytes(child, total_bytes);
    }
  }
  g_dir_close(directory);
}

bool RemoveTree(const std::string& path, int* error_number) {
  struct stat info;
  if (g_lstat(path.c_str(), &info) != 0) {
    if (errno == ENOENT) return true;
    *error_number = errno;
    return false;
  }
  if (!S_ISDIR(info.st_mode)) {
    if (g_unlink(path.c_str()) != 0 && errno != ENOENT) {
      *error_number = errno;
      return false;
    }
    return true;
  }

  GDir* directory = g_dir_open(path.c_str(), 0, nullptr);
  if (directory == nullptr) {
    *error_number = errno;
    return false;
  }
  while (const gchar* name = g_dir_read_name(directory)) {
    g_autofree gchar* child = g_build_filename(path.c_str(), name, nullptr);
    if (!RemoveTree(child, error_number)) {
      g_dir_close(directory);
      return false;
    }
  }
  g_dir_close(directory);
  if (g_rmdir(path.c_str()) != 0 && errno != ENOENT) {
    *error_number = errno;
    return false;
  }
  return true;
}

bool EmptySingleTrash(const std::string& trash_root, int* error_number) {
  struct stat root_info;
  if (!IsUserTrashDirectory(trash_root, &root_info)) return true;

  for (const char* child_name : {"files", "info"}) {
    g_autofree gchar* child_directory =
        g_build_filename(trash_root.c_str(), child_name, nullptr);
    struct stat info;
    if (!IsRealDirectory(child_directory, &info)) continue;

    GDir* directory = g_dir_open(child_directory, 0, nullptr);
    if (directory == nullptr) {
      if (errno == ENOENT) continue;
      *error_number = errno;
      return false;
    }
    while (const gchar* name = g_dir_read_name(directory)) {
      g_autofree gchar* child =
          g_build_filename(child_directory, name, nullptr);
      if (!RemoveTree(child, error_number)) {
        g_dir_close(directory);
        return false;
      }
    }
    g_dir_close(directory);
  }

  // This is a cache used by some file managers. Its removal is best-effort.
  g_autofree gchar* sizes =
      g_build_filename(trash_root.c_str(), "directorysizes", nullptr);
  (void)g_unlink(sizes);
  return true;
}

}  // namespace

bool QueryUserTrash(TrashSummary* summary, int* error_number) {
  if (summary == nullptr) return false;
  summary->item_count = 0;
  summary->total_bytes = 0;
  if (error_number != nullptr) *error_number = 0;

  const std::string home = HomeTrashDirectory();
  int home_error = 0;
  MeasureTrash(home, &summary->item_count, &summary->total_bytes, &home_error);
  if (home_error != 0) {
    if (error_number != nullptr) *error_number = home_error;
    return false;
  }

  for (const std::string& directory : CollectTrashDirectories()) {
    if (directory == home) continue;
    // An unreadable trash on another mount should not hide the home trash.
    MeasureTrash(directory, &summary->item_count, &summary->total_bytes,
                 nullptr);
  }
  return true;
}

bool EmptyUserTrash(int* error_number) {
  if (error_number != nullptr) *error_number = 0;

  int first_error = 0;
  for (const std::string& directory : CollectTrashDirectories()) {
    int deletion_error = 0;
    if (!EmptySingleTrash(directory, &deletion_error) && first_error == 0) {
      first_error = deletion_error;
    }
  }
  if (first_error != 0) {
    if (error_number != nullptr) *error_number = first_error;
    return false;
  }
  return true;
}
