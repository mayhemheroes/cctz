#!/usr/bin/env bash
#
# cctz/mayhem/test.sh — RUN cctz's own gtest/gmock suite (built by mayhem/build.sh with normal
# flags via CMake) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: cctz's gtest suite is a real known-answer / assertion suite — civil_time_test,
# time_zone_format_test and time_zone_lookup_test parse/format/normalize fixed civil times and
# timezone strings and ASSERT the exact expected results (EXPECT_EQ on values, formatted strings,
# civil-time fields) using the bundled testdata/zoneinfo. A no-op / "exit(0)" patch — or any change
# that perturbs a parsed/formatted/normalized result — makes EXPECT_* fail, so it cannot pass this
# oracle. This script only RUNS the pre-built binaries; it never compiles.
#
# Self-contained: TZDIR points at the in-repo testdata/zoneinfo, so no network / system tzdata is
# touched (matching the ENVIRONMENT property CMake sets on these tests).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"
export TZDIR="$SRC/testdata/zoneinfo"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "cctz-gtest" 0 1 0; exit 2
fi

# The gtest binaries built by build.sh (keep in sync). CMake emits them at the build-tree root.
TESTS=(
  civil_time_test
  time_zone_format_test
  time_zone_lookup_test
)

PASSED=0; FAILED=0
for t in "${TESTS[@]}"; do
  bin="$BUILDDIR/$t"
  if [ ! -x "$bin" ]; then
    echo "MISSING $t" >&2; FAILED=$((FAILED+1)); continue
  fi
  out="$("$bin" 2>&1)"; rc=$?
  echo "$out" | tail -3
  # gtest prints "[  PASSED  ] N test(s)." and "[  FAILED  ] N test(s)," — sum across binaries so a
  # single failing assertion is counted, not just a binary-level pass/fail.
  p=$(printf '%s\n' "$out" | sed -n 's/.*\[  PASSED  \][[:space:]]*\([0-9][0-9]*\) test.*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/.*\[  FAILED  \][[:space:]]*\([0-9][0-9]*\) test.*/\1/p' | tail -1)
  : "${p:=0}" "${f:=0}"
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
    # Crash / nonzero exit with no parsed gtest failure line — count as one failure.
    f=1
  fi
  echo "  $t: passed=$p failed=$f (exit $rc)"
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f ))
done

emit_ctrf "cctz-gtest" "$PASSED" "$FAILED" 0
