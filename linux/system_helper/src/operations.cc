#include "operations.h"

#include <algorithm>
#include <sys/stat.h>

namespace broom {

const std::vector<OperationSpec>& AllOperations() {
  static const std::vector<OperationSpec> operations = {
      OperationSpec{"apt-cache",
                    "/usr/bin/apt-get",
                    {"clean"},
                    {"DEBIAN_FRONTEND=noninteractive"},
                    "/var/cache/apt",
                    600},
      OperationSpec{"dnf-packages",
                    "/usr/bin/dnf",
                    {"clean", "packages"},
                    {},
                    "/var/cache/dnf",
                    600},
      OperationSpec{"pacman-cache",
                    "/usr/bin/pacman",
                    {"-Sc", "--noconfirm"},
                    {},
                    "/var/cache/pacman/pkg",
                    600},
      OperationSpec{"zypper-cache",
                    "/usr/bin/zypper",
                    {"--non-interactive", "clean"},
                    {},
                    "/var/cache/zypp",
                    600},
      OperationSpec{"flatpak-unused",
                    "/usr/bin/flatpak",
                    {"uninstall",
                     "--unused",
                     "--system",
                     "--noninteractive",
                     "--assumeyes"},
                    {},
                    "/var/lib/flatpak",
                    600},
      OperationSpec{"snap-revisions",
                    "/usr/bin/snap",
                    {"list", "--all"},
                    {},
                    "/var/lib/snapd",
                    600,
                    OperationKind::kSnapRevisions},
      OperationSpec{"journal-7d",
                    "/usr/bin/journalctl",
                    {"--vacuum-time=7d"},
                    {},
                    "/var/log/journal",
                    120},
  };
  return operations;
}

const OperationSpec* FindOperation(std::string_view id) {
  for (const OperationSpec& operation : AllOperations()) {
    if (id == operation.id) return &operation;
  }
  return nullptr;
}

std::vector<const OperationSpec*> SelectOperations(
    const std::vector<std::string>& ids) {
  std::vector<const OperationSpec*> selected;
  for (const OperationSpec& operation : AllOperations()) {
    if (std::find(ids.begin(), ids.end(), operation.id) != ids.end()) {
      selected.push_back(&operation);
    }
  }
  return selected;
}

ToolAvailability CheckTool(const Environment& environment,
                           const std::string& path) {
  const FileFacts facts = environment.Inspect(path);
  if (!facts.exists) return ToolAvailability{false, "tool_missing"};
  if (!facts.is_regular) return ToolAvailability{false, "tool_not_regular"};
  if (!facts.executable) {
    return ToolAvailability{false, "tool_not_executable"};
  }
  if (facts.owner != 0) return ToolAvailability{false, "tool_unsafe_owner"};
  if ((facts.mode & (S_IWGRP | S_IWOTH)) != 0) {
    return ToolAvailability{false, "tool_unsafe_permissions"};
  }
  return ToolAvailability{true, std::string()};
}

}  // namespace broom
