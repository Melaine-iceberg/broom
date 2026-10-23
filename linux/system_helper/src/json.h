#ifndef BROOM_SYSTEM_HELPER_JSON_H_
#define BROOM_SYSTEM_HELPER_JSON_H_

#include <string>
#include <string_view>

namespace broom {

// Quotes a UTF-8 string as a JSON string literal. The helper only emits ASCII
// diagnostics, but escaping remains mandatory because messages can include
// values derived from arguments or system tools.
std::string JsonQuote(std::string_view value);

std::string ErrorJson(std::string_view code,
                      std::string_view message,
                      int exit_code);

}  // namespace broom

#endif  // BROOM_SYSTEM_HELPER_JSON_H_
