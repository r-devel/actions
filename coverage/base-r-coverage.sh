#!/bin/bash
# Coverage of base R (R code and C/Fortran) while running `make check-all`.
#
# Usage: base-r-coverage.sh <step>, steps in order:
#   build       configure and build R with gcov instrumentation in $BUILD
#   covr        install covr into $COVR_LIB, using the R built in $BUILD
#   instrument  instrument the R code of the base packages built in $BUILD
#   check       run the checks, recording coverage
#   collect     write lcov files (paths relative to $SRC) and, if genhtml is
#               installed, an HTML report
#
# Environment: SRC (R sources, default: the current directory). BUILD,
# COVR_LIB and OUT default to directories next to $SRC.
# Also CHECK_TARGET (default check-all) and JOBS (default: all cores).
set -euo pipefail
SRC=$(cd "${SRC:-.}" && pwd)
# The steps change directory, so the paths are made absolute first; they don't
# need to exist yet.
WORK=$(realpath -m "${WORK:-$(dirname "$SRC")/base-r-coverage}")
BUILD=$(realpath -m "${BUILD:-$WORK/build-gcov}")
COVR_LIB=$(realpath -m "${COVR_LIB:-$WORK/covr-lib}")
OUT=$(realpath -m "${OUT:-$WORK/out}")
CHECK_TARGET=${CHECK_TARGET:-check-all}
JOBS=${JOBS:-$(nproc)}
# The R code below reads these from the environment
export SRC BUILD OUT
export TRACES=$OUT/traces
CONFIG=(--enable-R-shlib --with-blas --with-lapack --disable-java)
export R_KEEP_PKG_SOURCE=yes LC_ALL=C.UTF-8

case "${1:-}" in
build)
  F='-g -O0 --coverage'
  mkdir -p "$BUILD" && cd "$BUILD"
  "$SRC/configure" "${CONFIG[@]}" CFLAGS="$F" CXXFLAGS="$F" FFLAGS="$F" \
    FCFLAGS="$F" LDFLAGS=--coverage
  make -j"$JOBS"
  ;;
covr)
  # covr must stay installed at this path while R is instrumented: its
  # shared library path is baked into the base package loader. Its compiled
  # dependencies are built with --coverage too, but they are outside $SRC so
  # they are not reported.
  mkdir -p "$COVR_LIB"
  R_LIBS="$COVR_LIB" "$BUILD/bin/Rscript" -e '
    install.packages("pak", lib = Sys.getenv("R_LIBS"), repos = sprintf(
      "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
      .Platform$pkgType, R.Version()$os, R.Version()$arch))
    # TODO: switch to the CRAN release of covr once it has these functions
    pak::pkg_install("r-lib/covr@covr-base-packages", lib = Sys.getenv("R_LIBS"))'
  ;;
instrument)
  R_LIBS="$COVR_LIB" "$BUILD/bin/Rscript" -e '
    covr::instrument_base_r(Sys.getenv("SRC"),
      lib = file.path(Sys.getenv("BUILD"), "library"),
      trace_dir = Sys.getenv("TRACES"),
      cores = parallel::detectCores())'
  # Instrumenting ran the coverage build, start from zero
  find "$BUILD" -name '*.gcda' -delete
  ;;
check)
  mkdir -p "$TRACES"
  cd "$BUILD"
  # -k: a failing test shouldn't stop the coverage of the rest.
  # TEST_MC_CORES runs the package tests and examples in parallel. The full
  # log goes to $OUT/check.log, the job log only gets a summary.
  TEST_MC_CORES=$JOBS COVERAGE_DIR="$TRACES" \
    xvfb-run -a make -k "$CHECK_TARGET" > "$OUT/check.log" 2>&1 || status=$?
  tail -n 30 "$OUT/check.log"
  if [ "${status:-0}" != 0 ]; then
    echo "make $CHECK_TARGET failed (status $status), failing tests:"
    for f in tests/*.fail; do
      if [ -e "$f" ]; then
        echo "==> $f <=="
        tail -n 30 "$f"
      fi
    done
  fi
  ;;
collect)
  # Collect before any uninstrument_base_r(), which deletes the counters file
  mkdir -p "$OUT"
  R_LIBS="$COVR_LIB" "$BUILD/bin/Rscript" -e '
    src <- Sys.getenv("SRC"); out <- Sys.getenv("OUT")
    r <- covr::base_r_code_coverage(Sys.getenv("TRACES"), src)
    c <- covr::base_r_compiled_coverage(Sys.getenv("BUILD"), src)
    covr::lcov(r, file.path(out, "lcov-r.info"))
    covr::lcov(c, file.path(out, "lcov-c.info"))
    cat(sprintf("R %.1f%%, compiled %.1f%%, total %.1f%%\n",
      covr::percent_coverage(r), covr::percent_coverage(c),
      covr::percent_coverage(c(r, c))))'
  # Some R code isn't from a file of $SRC (e.g. tcltk is loaded from its
  # installed copy in $BUILD): genhtml can't show it and Codecov can't map it.
  # Paths of files in $SRC are relative, drop the absolute ones.
  cd "$SRC"
  for f in "$OUT"/lcov-r.info "$OUT"/lcov-c.info; do
    awk -v RS='end_of_record\n' -v ORS='end_of_record\n' '
      /(^|\n)SF:\// { dropped++; next }
      NF { print }
      END { if (dropped) printf "dropped %d files not in the source tree\n", dropped > "/dev/stderr" }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  # The HTML report is a convenience: it shouldn't stop the uploads. lcov 2
  # rejects some of covr's records ("unexpected category UNK"), which
  # `category` ignores; lcov 1 doesn't know that category.
  if command -v genhtml > /dev/null; then
    genhtml -q --ignore-errors source,category -o "$OUT/html" \
      "$OUT/lcov-r.info" "$OUT/lcov-c.info" ||
      genhtml -q --ignore-errors source -o "$OUT/html" \
        "$OUT/lcov-r.info" "$OUT/lcov-c.info" ||
      echo "genhtml failed, no HTML report" >&2
  fi
  ;;
*)
  echo "usage: $0 build|covr|instrument|check|collect" >&2
  exit 1
  ;;
esac
