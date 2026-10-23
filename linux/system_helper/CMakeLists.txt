cmake_minimum_required(VERSION 3.16)
project(broom_system_helper VERSION 0.1.0 LANGUAGES CXX)

include(GNUInstallDirs)

option(BROOM_HELPER_BUILD_TESTS "Build the helper unit tests" ON)
option(BROOM_HELPER_ENABLE_INSTALL "Generate the Polkit policy and install rules" ON)

set(BROOM_HELPER_INSTALL_PATH
    "${CMAKE_INSTALL_FULL_LIBEXECDIR}/broom/broom-system-helper")
set(BROOM_POLICY_INSTALL_PATH
    "${CMAKE_INSTALL_FULL_DATADIR}/polkit-1/actions/com.broom.Broom.policy")

set(BROOM_HELPER_SOURCES
  src/cli.cc
  src/helper.cc
  src/json.cc
  src/operations.cc
  src/probe.cc
  src/self_test.cc
)

function(broom_helper_configure target)
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_compile_definitions(${target} PRIVATE
    BROOM_HELPER_VERSION="${PROJECT_VERSION}"
    BROOM_HELPER_INSTALL_PATH="${BROOM_HELPER_INSTALL_PATH}"
    BROOM_POLICY_INSTALL_PATH="${BROOM_POLICY_INSTALL_PATH}"
    BROOM_PKEXEC_PATH="/usr/bin/pkexec"
  )
endfunction()

add_executable(broom-system-helper src/main.cc ${BROOM_HELPER_SOURCES})
broom_helper_configure(broom-system-helper)

if(BROOM_HELPER_ENABLE_INSTALL)
  configure_file(
    policy/com.broom.Broom.policy.in
    "${CMAKE_CURRENT_BINARY_DIR}/com.broom.Broom.policy"
    @ONLY
  )
  install(TARGETS broom-system-helper
    RUNTIME DESTINATION "${CMAKE_INSTALL_LIBEXECDIR}/broom")
  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/com.broom.Broom.policy"
    DESTINATION "${CMAKE_INSTALL_DATADIR}/polkit-1/actions")
endif()

if(BROOM_HELPER_BUILD_TESTS)
  enable_testing()
  add_executable(broom-system-helper-tests
    tests/helper_tests.cc
    ${BROOM_HELPER_SOURCES}
  )
  broom_helper_configure(broom-system-helper-tests)
  add_test(NAME broom-system-helper-tests COMMAND broom-system-helper-tests)
  add_test(NAME helper_list_smoke COMMAND broom-system-helper --list --json)
  add_test(NAME helper_self_test_smoke COMMAND broom-system-helper --self-test --json)
endif()
