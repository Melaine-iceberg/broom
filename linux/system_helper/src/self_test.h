#ifndef BROOM_SYSTEM_HELPER_SELF_TEST_H_
#define BROOM_SYSTEM_HELPER_SELF_TEST_H_

#include <string>
#include <string_view>
#include <vector>

#include "helper.h"

namespace broom {

struct SelfTestCheck {
  std::string id;
  std::string status;  // "pass", "warn", or "fail"
  std::string message;
};

struct SelfTestReport {
  std::string status;  // "ok", "degraded", or "failed"
  std::vector<SelfTestCheck> checks;

  bool failed() const { return status == "failed"; }
};

SelfTestReport RunSelfTest(const HelperContext& context);

std::string SelfTestReportJson(const SelfTestReport& report,
                               std::string_view helper_version);

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_SELF_TEST_H_
