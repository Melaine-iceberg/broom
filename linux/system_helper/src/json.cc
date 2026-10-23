#include "json.h"

#include <cstdio>

namespace broom {

std::string JsonQuote(std::string_view value) {
  std::string output;
  output.reserve(value.size() + 2);
  output.push_back('"');
  for (const unsigned char character : value) {
    switch (character) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\b':
        output += "\\b";
        break;
      case '\f':
        output += "\\f";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (character < 0x20) {
          char escaped[7];
          std::snprintf(escaped, sizeof(escaped), "\\u%04x", character);
          output += escaped;
        } else {
          output.push_back(static_cast<char>(character));
        }
        break;
    }
  }
  output.push_back('"');
  return output;
}

std::string ErrorJson(std::string_view code,
                      std::string_view message,
                      int exit_code) {
  return "{\"schemaVersion\":1,\"error\":{\"code\":" + JsonQuote(code) +
         ",\"message\":" + JsonQuote(message) +
         ",\"exitCode\":" + std::to_string(exit_code) + "}}\n";
}

}  // namespace broom
