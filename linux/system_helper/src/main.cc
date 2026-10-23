#include <cstddef>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "helper.h"
#include "probe.h"

#ifndef BROOM_HELPER_VERSION
#define BROOM_HELPER_VERSION "dev"
#endif
#ifndef BROOM_HELPER_INSTALL_PATH
#define BROOM_HELPER_INSTALL_PATH "/usr/libexec/broom/broom-system-helper"
#endif
#ifndef BROOM_POLICY_INSTALL_PATH
#define BROOM_POLICY_INSTALL_PATH \
  "/usr/share/polkit-1/actions/com.broom.Broom.policy"
#endif
#ifndef BROOM_PKEXEC_PATH
#define BROOM_PKEXEC_PATH "/usr/bin/pkexec"
#endif

int main(int argc, char** argv) {
  std::vector<std::string> arguments;
  if (argc > 1) {
    arguments.reserve(static_cast<std::size_t>(argc - 1));
    for (int index = 1; index < argc; ++index) {
      arguments.emplace_back(argv[index]);
    }
  }

  const std::unique_ptr<broom::Environment> environment =
      broom::CreatePosixEnvironment();
  broom::HelperContext context;
  context.environment = environment.get();
  context.helper_install_path = BROOM_HELPER_INSTALL_PATH;
  context.policy_path = BROOM_POLICY_INSTALL_PATH;
  context.pkexec_path = BROOM_PKEXEC_PATH;
  context.version = BROOM_HELPER_VERSION;

  std::string stdout_text;
  std::string stderr_text;
  const int exit_code =
      broom::RunHelper(arguments, &context, &stdout_text, &stderr_text);

  if (!stdout_text.empty()) {
    (void)std::fwrite(stdout_text.data(), 1, stdout_text.size(), stdout);
  }
  if (!stderr_text.empty()) {
    (void)std::fwrite(stderr_text.data(), 1, stderr_text.size(), stderr);
  }
  return exit_code;
}
