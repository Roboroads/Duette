cmake_minimum_required(VERSION 3.24)
project(duette_core LANGUAGES CXX)

# Header-only DSP core. Consumers link duette::core; nothing here depends on Apple frameworks.
add_library(duette_core INTERFACE)
add_library(duette::core ALIAS duette_core)
target_include_directories(duette_core INTERFACE
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(duette_core INTERFACE cxx_std_17)

option(DUETTE_CORE_BUILD_TESTS "Build the DSP core tests" ${PROJECT_IS_TOP_LEVEL})
option(DUETTE_WARNINGS_AS_ERRORS "Treat compiler warnings as errors in the core tests" OFF)
set(DUETTE_SANITIZER "none" CACHE STRING
  "Sanitizer for the core tests: none, asan (address + undefined) or tsan (thread)")
set_property(CACHE DUETTE_SANITIZER PROPERTY STRINGS none asan tsan)

if(NOT DUETTE_CORE_BUILD_TESTS)
  return()
endif()

enable_testing()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

# Sanitizer flags go on before Catch2 is fetched so Catch2 is instrumented the same way.
if(DUETTE_SANITIZER STREQUAL "asan")
  set(_duette_san -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
elseif(DUETTE_SANITIZER STREQUAL "tsan")
  set(_duette_san -fsanitize=thread -fno-omit-frame-pointer)
elseif(NOT DUETTE_SANITIZER STREQUAL "none")
  message(FATAL_ERROR "DUETTE_SANITIZER must be none, asan or tsan (got '${DUETTE_SANITIZER}')")
endif()
if(_duette_san)
  add_compile_options(${_duette_san})
  add_link_options(${_duette_san})
  message(STATUS "duette core: sanitizer '${DUETTE_SANITIZER}' enabled")
endif()

include(FetchContent)
FetchContent_Declare(Catch2
  GIT_REPOSITORY https://github.com/catchorg/Catch2.git
  GIT_TAG        v3.7.1
  GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(Catch2)
if(catch2_SOURCE_DIR)
  list(APPEND CMAKE_MODULE_PATH ${catch2_SOURCE_DIR}/extras)
endif()
include(Catch)

add_library(duette_core_warnings INTERFACE)
if(MSVC)
  target_compile_options(duette_core_warnings INTERFACE /W4)
  if(DUETTE_WARNINGS_AS_ERRORS)
    target_compile_options(duette_core_warnings INTERFACE /WX)
  endif()
else()
  target_compile_options(duette_core_warnings INTERFACE
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion)
  if(DUETTE_WARNINGS_AS_ERRORS)
    target_compile_options(duette_core_warnings INTERFACE -Werror)
  endif()
endif()

# Every public header has to compile on its own.
file(GLOB DUETTE_CORE_HEADERS CONFIGURE_DEPENDS
  RELATIVE ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${CMAKE_CURRENT_SOURCE_DIR}/include/duette/*.hpp)
set(_header_check_sources)
foreach(_header IN LISTS DUETTE_CORE_HEADERS)
  string(MAKE_C_IDENTIFIER "${_header}" _id)
  set(_src ${CMAKE_CURRENT_BINARY_DIR}/header_check/${_id}.cpp)
  file(CONFIGURE OUTPUT ${_src} CONTENT "#include <${_header}>\n#include <${_header}>\n" @ONLY)
  list(APPEND _header_check_sources ${_src})
endforeach()
add_library(duette_core_header_check OBJECT ${_header_check_sources})
target_link_libraries(duette_core_header_check PRIVATE duette::core duette_core_warnings)

find_package(Threads REQUIRED)

add_executable(duette_core_tests
  tests/loopback_buffer_test.cpp
  tests/smoothed_gain_test.cpp
  tests/mixer_test.cpp
  tests/meter_test.cpp
  tests/tone_test.cpp
  tests/zero_run_test.cpp
  tests/latency_estimator_test.cpp)
target_link_libraries(duette_core_tests PRIVATE
  duette::core duette_core_warnings Catch2::Catch2WithMain Threads::Threads)
catch_discover_tests(duette_core_tests PROPERTIES TIMEOUT 300)

# The allocation guard replaces the global operator new, so it gets its own program. It is built
# without optimization: the optimizer may delete a new/delete pair whose memory is never used,
# which would hide an allocation from the counter.
#
# It is skipped under TSan: the guard is single-threaded, so TSan adds nothing, and clang's TSan
# runtime defines operator new itself, which clashes with the replacement at link time.
if(NOT DUETTE_SANITIZER STREQUAL "tsan")
  add_executable(duette_core_alloc_tests tests/alloc_guard_test.cpp)
  target_link_libraries(duette_core_alloc_tests PRIVATE
    duette::core duette_core_warnings Catch2::Catch2WithMain)
  if(NOT MSVC)
    target_compile_options(duette_core_alloc_tests PRIVATE -O0)
  endif()
  catch_discover_tests(duette_core_alloc_tests TEST_PREFIX "alloc: " PROPERTIES TIMEOUT 300)
endif()
