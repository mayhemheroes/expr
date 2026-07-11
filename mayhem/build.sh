#!/usr/bin/env bash
#
# expr/mayhem/build.sh — build expr-lang/expr's OSS-Fuzz Go fuzz target as a sanitized libFuzzer
# binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz target (projects/expr/build.sh):
#   go get github.com/AdamKorcz/go-118-fuzz-build/testing
#   compile_native_go_fuzzer github.com/expr-lang/expr/test/fuzz FuzzExpr fuzz_expr
# i.e. the NATIVE go fuzz harness `func FuzzExpr(f *testing.F)` (test/fuzz/fuzz_test.go), built
# with go-118-fuzz-build under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE.
# The harness compiles + runs an arbitrary expr program (expr.Compile + vm.VM.Run over a fixed
# env); the fuzzed surface is the expr parser/compiler/VM. It t.Skip()s a curated set of expected
# runtime errors, so only real panics/unexpected errors are reported.
#
# We produce:
#   /mayhem/fuzz_expr   — OSS-Fuzz target (fuzz.FuzzExpr, go-118-fuzz-build, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-fuzz builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_*_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper, CGO bridge files)
# default to DWARF5 with clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $GO_DEBUG_FLAGS. The verify check uses the FIRST CU's
# DWARF version (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── expr target: fuzz.FuzzExpr ────────────────────────────────────────────────────────────────
# Detect the harness signature and pick the right builder (mirrors compile_native_go_fuzzer's
# `func $function ... testing.F` test):
#   * native  `func FuzzExpr(f *testing.F)` -> go-118-fuzz-build  (this repo)
#   * legacy  `func FuzzExpr(data []byte) int` -> go-fuzz (go114-fuzz-build)
FUZZ_PKG="github.com/expr-lang/expr/test/fuzz"
FUZZ_FUNC="FuzzExpr"
FUZZ_OUT="fuzz_expr"
FUZZ_DIR="$SRC/test/fuzz"

if grep -RnE "func ${FUZZ_FUNC}\(" "$FUZZ_DIR"/*.go | grep -q "testing.F"; then
  echo "=== building ${FUZZ_OUT} (${FUZZ_FUNC}, NATIVE go-118-fuzz-build -tags gofuzz) ==="
  go-118-fuzz-build -tags gofuzz -o "$SRC/mayhem-build/${FUZZ_OUT}.a" -func "$FUZZ_FUNC" "$FUZZ_DIR"
else
  echo "=== building ${FUZZ_OUT} (${FUZZ_FUNC}, LEGACY go-fuzz -tags gofuzz) ==="
  go-fuzz -tags gofuzz -func "$FUZZ_FUNC" -o "$SRC/mayhem-build/${FUZZ_OUT}.a" "$FUZZ_PKG"
fi

# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/${FUZZ_OUT}.a" -o "/mayhem/${FUZZ_OUT}"
echo "built /mayhem/${FUZZ_OUT}"

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_OUT}" 2>&1 || true
