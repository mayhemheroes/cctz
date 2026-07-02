#!/usr/bin/env bash
#
# cctz/mayhem/build.sh — build google/cctz's OSS-Fuzz harness (fuzz_cctz.cc) as a sanitized
# libFuzzer target (+ a standalone reproducer), AND cctz's own CMake/CTest gtest suite (normal
# flags) for mayhem/test.sh to RUN.
#
# cctz is a C++ civil-time / timezone library. The fuzzed surface is its STRING PARSING and
# timezone machinery: the harness pulls attacker-controlled bytes through a FuzzedDataProvider and
#   1. load_time_zone(tz)            — parse a timezone NAME and load its zoneinfo
#   2. cctz::parse(fmt, str, tz, &tp)— parse a strptime-style time STRING with a fuzz-chosen format
#   3. cctz::convert(civil_second…)  — normalize a (fuzz-supplied) Y/M/D h:m:s civil time
#   4. cctz::format(fmt, tp, tz)      — render it back with a fuzz-chosen format
# i.e. the input is a packed FuzzedDataProvider blob, not a single time string. We compile the cctz
# library ITSELF with $SANITIZER_FLAGS so the parsing/formatting code (not just the harness) is
# instrumented, then link it into the harness.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). FuzzedDataProvider.h ships on clang's default include path in the base.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
INC="-I$SRC/include"
STD="-std=c++17"

# cctz's library sources (mirrors the add_library(cctz …) list in CMakeLists.txt; Windows-only
# files excluded). Compiled with sanitizers so the fuzzed code is instrumented.
CCTZ_SRCS=(
  src/civil_time_detail.cc
  src/time_zone_fixed.cc
  src/time_zone_format.cc
  src/time_zone_if.cc
  src/time_zone_impl.cc
  src/time_zone_info.cc
  src/time_zone_libc.cc
  src/time_zone_lookup.cc
  src/time_zone_posix.cc
  src/zone_info_source.cc
)

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# ── 1) Build the cctz static library WITH sanitizers (the fuzzed parser is instrumented) ──────────
OBJS=()
for s in "${CCTZ_SRCS[@]}"; do
  obj="$BUILD/$(basename "${s%.cc}").o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC -c "$s" -o "$obj"
  OBJS+=("$obj")
done
LIBCCTZ="$BUILD/libcctz.a"
rm -f "$LIBCCTZ"; ar rcs "$LIBCCTZ" "${OBJS[@]}"

# ── 2) libFuzzer target -> /mayhem/fuzz_cctz ──────────────────────────────────────────────────────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
    "$HARNESS_DIR/fuzz_cctz.cc" $LIB_FUZZING_ENGINE "$LIBCCTZ" -lpthread \
    -o "/mayhem/fuzz_cctz"

# ── 3) standalone reproducer -> /mayhem/fuzz_cctz-standalone (no libFuzzer runtime, one input) ─────
# The driver is C (extern "C" LLVMFuzzerTestOneInput); compile it as a C object first so clang++
# doesn't mangle its symbol reference, then link with the C++ harness + sanitized lib.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
    "$HARNESS_DIR/fuzz_cctz.cc" "$BUILD/standalone_main.o" "$LIBCCTZ" -lpthread \
    -o "/mayhem/fuzz_cctz-standalone"

echo "built fuzz_cctz (+ standalone)"

# ── 4) Build cctz's OWN gtest/gmock suite via CMake with NORMAL flags (clean, separate tree) so
#       test.sh only RUNS it. These are real known-answer tests (civil_time_test, time_zone_format_test,
#       time_zone_lookup_test) that assert exact civil-time/format/parse results against gtest/gmock
#       expectations, using the bundled testdata/zoneinfo (TZDIR is set per-test by CMake) — so they
#       are self-contained and need no network/system tzdata. -DBUILD_BENCHMARK=OFF drops the
#       google/benchmark dependency; tools/examples off to keep the build lean. ──────────────────────
TESTDIR="$SRC/mayhem-tests"
if command -v cmake >/dev/null 2>&1; then
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    cmake -S "$SRC" -B "$TESTDIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=ON \
      -DBUILD_BENCHMARK=OFF \
      -DBUILD_TOOLS=OFF \
      -DBUILD_EXAMPLES=OFF
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    cmake --build "$TESTDIR" -j"$MAYHEM_JOBS" \
      --target civil_time_test time_zone_format_test time_zone_lookup_test
  echo "built cctz gtest suite in mayhem-tests/"
else
  echo "WARNING: cmake not found — test suite not built (mayhem/test.sh will fail loudly)" >&2
fi

echo "build.sh complete:"
ls -la /mayhem/fuzz_cctz /mayhem/fuzz_cctz-standalone 2>&1 || true
