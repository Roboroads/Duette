# 3.28: FetchContent SYSTEM (3.25) and EXCLUDE_FROM_ALL (3.28).
cmake_minimum_required(VERSION 3.28)

# Apple Silicon, macOS 14.2+. Set before project() so libASPL is built the same way (APPLE is
# not known yet here; other platforms ignore both).
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.2" CACHE STRING "Minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Architectures to build")

project(duette_driver LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# libASPL copies compile_commands.json from the top-level build tree, so it has to exist.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

if(APPLE)
  set(_duette_tests_default OFF)
else()
  # Off macOS only the tests can be built.
  set(_duette_tests_default ON)
endif()

option(DUETTE_TEST_DEVICES
  "Add the CI-only test devices (Duette Test Mic, Duette Test Speaker). Never shipped." OFF)
option(DUETTE_DRIVER_BUILD_TESTS "Build the driver unit tests (no Apple headers needed)"
  ${_duette_tests_default})
option(DUETTE_DRIVER_BUILD_PROBE "Build duette-driver-probe, the CoreAudio client CI runs" OFF)
option(DUETTE_WARNINGS_AS_ERRORS "Treat compiler warnings in driver code as errors" OFF)
set(DUETTE_BUILD_NUMBER "0" CACHE STRING "CFBundleVersion (the CI run number)")

# The single source of the version. release-please owns the file.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../version.txt" DUETTE_VERSION)
string(STRIP "${DUETTE_VERSION}" DUETTE_VERSION)
if(NOT DUETTE_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+")
  message(FATAL_ERROR "version.txt does not hold a version: '${DUETTE_VERSION}'")
endif()
message(STATUS "Duette driver ${DUETTE_VERSION} (${DUETTE_BUILD_NUMBER}), test devices: ${DUETTE_TEST_DEVICES}")

# The header-only DSP core (LoopbackBuffer, ToneGenerator).
set(DUETTE_CORE_BUILD_TESTS OFF)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../core" "${CMAKE_CURRENT_BINARY_DIR}/core")

add_library(duette_driver_warnings INTERFACE)
target_compile_options(duette_driver_warnings INTERFACE
  -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion)
if(DUETTE_WARNINGS_AS_ERRORS)
  target_compile_options(duette_driver_warnings INTERFACE -Werror)
endif()

# ---------------------------------------------------------------------------------------- tests

if(DUETTE_DRIVER_BUILD_TESTS)
  enable_testing()
  include(FetchContent)
  FetchContent_Declare(Catch2
    GIT_REPOSITORY https://github.com/catchorg/Catch2.git
    GIT_TAG        v3.7.1
    GIT_SHALLOW    TRUE)
  FetchContent_MakeAvailable(Catch2)
  list(APPEND CMAKE_MODULE_PATH "${catch2_SOURCE_DIR}/extras")
  include(Catch)

  find_package(Threads REQUIRED)
  add_executable(duette_driver_tests
    tests/shared_clock_tests.cpp
    tests/loopback_writer_tests.cpp
    tests/self_test_tone_tests.cpp)
  target_include_directories(duette_driver_tests PRIVATE src include)
  target_link_libraries(duette_driver_tests PRIVATE
    duette::core duette_driver_warnings Catch2::Catch2WithMain Threads::Threads)
  catch_discover_tests(duette_driver_tests PROPERTIES TIMEOUT 120)

  # The protocol header is plain C and has to stay that way: the app imports it from Swift.
  add_library(duette_driver_protocol_check OBJECT tests/protocol_header_check.c)
  target_include_directories(duette_driver_protocol_check PRIVATE include)
  target_compile_options(duette_driver_protocol_check PRIVATE -Wall -Wextra -Wpedantic -Werror)
  set_target_properties(duette_driver_protocol_check PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
endif()

if(NOT APPLE)
  if(NOT DUETTE_DRIVER_BUILD_TESTS)
    message(FATAL_ERROR "The HAL plug-in builds only on macOS; enable DUETTE_DRIVER_BUILD_TESTS.")
  endif()
  return()
endif()

# --------------------------------------------------------------------------------------- plug-in

if(CMAKE_GENERATOR MATCHES "Ninja")
  # libASPL declares an empty BYPRODUCTS per generated file; Ninja rejects that.
  message(FATAL_ERROR "Configure the plug-in with -G \"Unix Makefiles\": libASPL's CMake does not work with Ninja.")
endif()

include(FetchContent)
# libASPL (MIT), pinned to a release tag. Its CMake reads the tag with `git describe`, so it must
# come from git, not from a source archive.
FetchContent_Declare(libASPL
  GIT_REPOSITORY https://github.com/gavv/libASPL.git
  GIT_TAG        v3.1.2
  GIT_SHALLOW    TRUE
  # Its headers are included as system headers, so our warning flags don't apply to them.
  SYSTEM
  EXCLUDE_FROM_ALL)
set(BUILD_TESTING OFF)
FetchContent_MakeAvailable(libASPL)

# Fresh factory UUID for this plug-in (not shared with any other driver).
set(DUETTE_DRIVER_FACTORY_UUID "73D825D4-C3DF-4C14-97DC-A33A607E9305")
set(DUETTE_DRIVER_ENTRY_POINT "DuetteDriverEntryPoint")
set(DUETTE_DRIVER_BUNDLE_ID "me.roboroads.duette.driver")

configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

set(_duette_driver_sources
  src/Entry.cpp
  src/DuetteDevices.cpp)
if(DUETTE_TEST_DEVICES)
  list(APPEND _duette_driver_sources src/TestDevices.cpp)
endif()

# MODULE gives a Mach-O bundle; the target properties wrap it in Duette.driver/Contents/...
add_library(DuetteDriver MODULE ${_duette_driver_sources})
target_include_directories(DuetteDriver PRIVATE src include)
target_link_libraries(DuetteDriver PRIVATE libASPL duette::core duette_driver_warnings)
target_compile_definitions(DuetteDriver PRIVATE
  DUETTE_DRIVER_VERSION="${DUETTE_VERSION}"
  DUETTE_TEST_DEVICES=$<BOOL:${DUETTE_TEST_DEVICES}>)
set_target_properties(DuetteDriver PROPERTIES
  OUTPUT_NAME "Duette"
  PREFIX ""
  SUFFIX ""
  BUNDLE TRUE
  BUNDLE_EXTENSION "driver"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
  # Keep only the entry point exported.
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

if(DUETTE_DRIVER_BUILD_PROBE)
  add_executable(duette-driver-probe tests/driver_probe.cpp)
  target_include_directories(duette-driver-probe PRIVATE include)
  target_link_libraries(duette-driver-probe PRIVATE
    "-framework CoreAudio" "-framework CoreFoundation")
endif()
