#!/usr/bin/env bash
# Build and test the header-only DSP core in core/.
#
# Usage: scripts/ci/test-core.sh [plain] [asan] [tsan]
#   plain  optimized build, no sanitizer
#   asan   AddressSanitizer + UndefinedBehaviorSanitizer (UB aborts the test)
#   tsan   ThreadSanitizer
# With no arguments all three run, in that order. The first failure stops the script.
#
# Environment:
#   DUETTE_CORE_BUILD_DIR  where the build trees go (default: <repo>/build/core-test)
#   CXX                    compiler to use (default: CMake's choice)
#   CMAKE_GENERATOR        generator to use (default: Ninja if installed, else CMake's choice)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root=$(pwd)
build_root=${DUETTE_CORE_BUILD_DIR:-$repo_root/build/core-test}

modes=("$@")
if [ ${#modes[@]} -eq 0 ]; then
  modes=(plain asan tsan)
fi

if [ -z "${CMAKE_GENERATOR:-}" ] && command -v ninja >/dev/null 2>&1; then
  export CMAKE_GENERATOR=Ninja
fi

if command -v nproc >/dev/null 2>&1; then
  jobs=$(nproc)
else
  jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
fi

# Leak checking only exists on Linux; asking for it on macOS makes ASan refuse to start.
asan_options=${ASAN_OPTIONS:-}
if [ -z "$asan_options" ] && [ "$(uname -s)" = Linux ]; then
  asan_options=detect_leaks=1
fi

for mode in "${modes[@]}"; do
  case "$mode" in
    plain) sanitizer=none ;;
    asan)  sanitizer=asan ;;
    tsan)  sanitizer=tsan ;;
    *) echo "test-core.sh: unknown mode '$mode' (expected plain, asan or tsan)" >&2; exit 2 ;;
  esac

  build_dir=$build_root/$mode
  echo "==> core tests: $mode ($build_dir)"
  cmake -S "$repo_root/core" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DDUETTE_SANITIZER="$sanitizer" \
    -DDUETTE_WARNINGS_AS_ERRORS=ON
  cmake --build "$build_dir" --parallel "$jobs"

  # halt_on_error keeps a TSan report from being printed and then ignored.
  UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1}" \
  TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1 second_deadlock_stack=1}" \
  ASAN_OPTIONS="$asan_options" \
    ctest --test-dir "$build_dir" --output-on-failure --no-tests=error --parallel "$jobs"
done

echo "==> core tests passed: ${modes[*]}"
