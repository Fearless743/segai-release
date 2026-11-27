#!/usr/bin/env bash
# Regression tests for install.sh asset selection. No network, no root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -n "$ROOT/install.sh"

# Load install.sh as a library without running main() or its traps.
sed '$d' "$ROOT/install.sh" > "$TMP/install-lib.sh"
# shellcheck disable=SC1090
source "$TMP/install-lib.sh"
trap - ERR EXIT

# --- stubs -----------------------------------------------------------------
uname() {
    case "${1:-}" in
        -m) printf '%s\n' "${TEST_ARCH:-x86_64}" ;;
        *)  printf '%s\n' "${TEST_OS:-Linux}" ;;
    esac
}
ldd() { printf '%s\n' "${TEST_LDD:-ldd (GNU libc) 2.41}"; }
http_ok() {
    local name="${1##*/}"
    case " ${AVAILABLE_ASSETS:-} " in
        *" $name "*) return 0 ;;
        *) return 1 ;;
    esac
}
log_info()  { :; }
log_warn()  { :; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

fail=0
check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
        fail=1
    fi
}

GNU_X86="sekai-x86_64-unknown-linux-gnu.tar.gz"
MUSL_X86="sekai-x86_64-unknown-linux-musl.tar.gz"
GNU_ARM="sekai-aarch64-unknown-linux-gnu.tar.gz"
MUSL_ARM="sekai-aarch64-unknown-linux-musl.tar.gz"

expect_asset() {
    local name="$1" expected="$2" os="$3" arch="$4" ldd_out="$5" assets="$6"
    export TEST_OS="$os" TEST_ARCH="$arch" TEST_LDD="$ldd_out" AVAILABLE_ASSETS="$assets"
    ASSET=""
    RELEASE_VERSION=v0.1.3
    detect_asset
    check "$name" "$expected" "$ASSET"
}

GLIBC='ldd (GNU libc) 2.41'
MUSL='musl libc (x86_64)'

# v0.1.3 has no x86_64 gnu package; glibc hosts must not 404.
expect_asset 'glibc x86_64 falls back to static musl' "$MUSL_X86" \
    Linux x86_64 "$GLIBC" "$MUSL_X86"
expect_asset 'glibc x86_64 prefers gnu when available' "$GNU_X86" \
    Linux x86_64 "$GLIBC" "$GNU_X86 $MUSL_X86"

# A musl host must never be handed a dynamic glibc binary.
expect_asset 'musl x86_64 stays on musl' "$MUSL_X86" \
    Linux x86_64 "$MUSL" "$GNU_X86 $MUSL_X86"

expect_asset 'glibc aarch64 falls back to musl' "$MUSL_ARM" \
    Linux aarch64 "$GLIBC" "$MUSL_ARM"
expect_asset 'glibc aarch64 prefers gnu' "$GNU_ARM" \
    Linux aarch64 "$GLIBC" "$GNU_ARM $MUSL_ARM"

# No asset at all is an explicit failure, not a silent bad download.
if (export TEST_OS=Linux TEST_ARCH=x86_64 TEST_LDD="$GLIBC" AVAILABLE_ASSETS=''
        detect_asset) >/dev/null 2>&1; then
    printf 'FAIL missing assets should fail\n' >&2
    fail=1
else
    printf 'ok   missing assets fail loudly\n'
fi

exit "$fail"
