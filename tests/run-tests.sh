#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# ---------------------------------------------------------------------------
# run-tests.sh -- exercise the installer and the loader in a sandbox
#
# Every test runs against a throwaway HOME under $TMPDIR, so nothing here
# touches the start-up files of whoever is running it.
#
#   ./tests/run-tests.sh
#
# A missing shell is skipped, not failed: the suite has to run on a bare
# CI image as well as on a developer's laptop.
# ---------------------------------------------------------------------------

set -eu

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BEGIN_MARK='# >>> lfreleng-actions/shell-scripts >>>'
SANDBOX=''
passed=0
failed=0
skipped=0

cleanup() {
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
    return 0
}
trap cleanup EXIT HUP INT TERM

pass() {
    passed=$((passed + 1))
    printf 'ok    %s\n' "$1"
}

fail() {
    failed=$((failed + 1))
    printf 'FAIL  %s\n' "$1"
    if [ $# -gt 1 ] && [ -n "$2" ]; then
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
    return 0
}

skip() {
    skipped=$((skipped + 1))
    printf 'skip  %s (%s)\n' "$1" "$2"
}

# Assert that a command succeeds, showing its output when it does not.
check() {
    _name=$1
    shift
    if _out=$("$@" 2>&1); then
        pass "$_name"
    else
        fail "$_name" "$_out"
    fi
}

# Assert that the output of a shell one-liner equals an expected string.
# Only stdout counts: an interactive bash started without a controlling
# terminal announces 'no job control in this shell' on stderr, which is
# noise rather than failure. Stderr is kept back for the failure report.
check_output() {
    _name=$1
    _want=$2
    _home=$3
    shift 3

    _errlog="$SANDBOX/stderr.log"
    _got=$(env -i HOME="$_home" PATH="$PATH" "$@" 2>"$_errlog") || true

    if [ "$_got" = "$_want" ]; then
        pass "$_name"
    else
        fail "$_name" "expected '$_want', got '$_got'
 stderr: $(cat "$_errlog")"
    fi
}

# A fresh HOME with recognisable start-up files, so the tests can prove the
# installer leaves existing content alone.
new_home() {
    _home="$SANDBOX/home-$1"
    mkdir -p "$_home"
    printf '# original zshrc\nalias ll="ls -l"\n' >"$_home/.zshrc"
    printf '# original bashrc\nalias la="ls -a"\n' >"$_home/.bashrc"
    printf '%s\n' "$_home"
}

install_into() {
    HOME=$1 "$REPO_DIR/install.sh" --yes --fork-path "$2"
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/lfreleng-tests.XXXXXX")
printf 'testing %s\n\n' "$REPO_DIR"

# --- static checks ---------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
    check 'shellcheck: every shell file' \
        shellcheck "$REPO_DIR/install.sh" "$REPO_DIR/loader.sh" \
        "$REPO_DIR/tests/run-tests.sh" "$REPO_DIR"/tools/*.sh
else
    skip 'shellcheck: every shell file' 'shellcheck not installed'
fi

for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
        skip "$shell: parses every shell file" "$shell not installed"
        continue
    fi
    check "$shell: parses loader.sh" "$shell" -n "$REPO_DIR/loader.sh"
    for tool in "$REPO_DIR"/tools/*.sh; do
        check "$shell: parses tools/$(basename "$tool")" "$shell" -n "$tool"
    done
done

# --- installation ----------------------------------------------------------

home=$(new_home basic)
forks="$SANDBOX/forks"
mkdir -p "$forks"

if install_into "$home" "$forks" >"$SANDBOX/install.log" 2>&1; then
    pass 'install: first run succeeds'
else
    fail 'install: first run succeeds' "$(cat "$SANDBOX/install.log")"
fi

for file in "$home/.zshrc" "$home/.bashrc"; do
    name=$(basename "$file")
    if grep -qxF "$BEGIN_MARK" "$file"; then
        pass "install: block written to $name"
    else
        fail "install: block written to $name"
    fi
    if grep -q '^alias ' "$file"; then
        pass "install: existing content in $name survives"
    else
        fail "install: existing content in $name survives"
    fi
done

# --- idempotency -----------------------------------------------------------

cp "$home/.zshrc" "$SANDBOX/zshrc.after-first"
install_into "$home" "$forks" >/dev/null 2>&1
install_into "$home" "$forks" >/dev/null 2>&1

if cmp -s "$SANDBOX/zshrc.after-first" "$home/.zshrc"; then
    pass 'install: re-running changes nothing'
else
    fail 'install: re-running changes nothing' \
        "$(diff "$SANDBOX/zshrc.after-first" "$home/.zshrc" || true)"
fi

count=$(grep -cxF "$BEGIN_MARK" "$home/.zshrc")
if [ "$count" -eq 1 ]; then
    pass 'install: exactly one block after three runs'
else
    fail 'install: exactly one block after three runs' "found $count"
fi

# --- the shells actually load the tools ------------------------------------

if command -v zsh >/dev/null 2>&1; then
    check_output 'zsh: an interactive shell defines release' \
        'release: function' "$home" \
        zsh -i -c 'whence -w release'
else
    skip 'zsh: an interactive shell defines release' 'zsh not installed'
fi

if command -v bash >/dev/null 2>&1; then
    check_output 'bash: an interactive shell defines release' \
        'function' "$home" \
        bash --rcfile "$home/.bashrc" -i -c 'type -t release'
else
    skip 'bash: an interactive shell defines release' 'bash not installed'
fi

# --- the loader on its own -------------------------------------------------

for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
        skip "$shell: sourcing loader.sh by hand works" "$shell not installed"
        continue
    fi

    check_output "$shell: sourcing loader.sh by hand works" yes "$home" \
        "$shell" -c \
        ". '$REPO_DIR/loader.sh'; command -v release >/dev/null && echo yes"

    if got=$(env -i HOME="$home" PATH="$PATH" \
        LFRELENG_SHELL_SCRIPTS_SKIP=release "$shell" -c \
        ". '$REPO_DIR/loader.sh'; command -v release >/dev/null || echo none" \
        2>/dev/null) && [ "$got" = none ]; then
        pass "$shell: LFRELENG_SHELL_SCRIPTS_SKIP leaves a tool out"
    else
        fail "$shell: LFRELENG_SHELL_SCRIPTS_SKIP leaves a tool out" "$got"
    fi
done

# --- release: finding a clone by name --------------------------------------

if command -v git >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    git init -q "$forks/example-repo"
    run_release() {
        env -i HOME="$home" PATH="$PATH" \
            bash --rcfile "$home/.bashrc" -i -c "$1" 2>&1 || true
    }

    got=$(run_release 'cd / && release example-repo')
    case "$got" in
        *"working in $forks/example-repo"*)
            pass 'release: finds a clone under the recorded directory' ;;
        *)  fail 'release: finds a clone under the recorded directory' "$got" ;;
    esac

    got=$(run_release 'cd / && release no-such-repo')
    case "$got" in
        *'no clone of '*) pass 'release: reports a clone it cannot find' ;;
        *) fail 'release: reports a clone it cannot find' "$got" ;;
    esac

    got=$(run_release \
        'cd / && unset LFRELENG_ACTIONS_FORK_PATH && release anything')
    case "$got" in
        *'no search'*) pass 'release: explains an unset search root' ;;
        *) fail 'release: explains an unset search root' "$got" ;;
    esac
else
    skip 'release: finds a clone under the recorded directory' \
        'git or bash not installed'
fi

# --- status ----------------------------------------------------------------

got=$(HOME="$home" "$REPO_DIR/install.sh" --status 2>&1)
case "$got" in
    *installed*) pass 'status: reports the block as installed' ;;
    *) fail 'status: reports the block as installed' "$got" ;;
esac

# --- dry run ---------------------------------------------------------------

cp "$home/.zshrc" "$SANDBOX/zshrc.before-dry-run"
HOME="$home" "$REPO_DIR/install.sh" --dry-run --fork-path "$SANDBOX/other" \
    >/dev/null 2>&1
if cmp -s "$SANDBOX/zshrc.before-dry-run" "$home/.zshrc"; then
    pass 'dry run: writes nothing'
else
    fail 'dry run: writes nothing'
fi

# --- uninstall -------------------------------------------------------------

HOME="$home" "$REPO_DIR/install.sh" --uninstall >/dev/null 2>&1
if grep -q 'lfreleng-actions/shell-scripts' "$home/.zshrc" "$home/.bashrc"; then
    fail 'uninstall: removes every block'
else
    pass 'uninstall: removes every block'
fi
if grep -q '^alias ll' "$home/.zshrc"; then
    pass 'uninstall: leaves the original content behind'
else
    fail 'uninstall: leaves the original content behind'
fi
if [ -f "$home/.zshrc.lfreleng.bak" ]; then
    pass 'uninstall: keeps a backup'
else
    fail 'uninstall: keeps a backup'
fi

# --- half-deleted markers --------------------------------------------------

broken=$(new_home broken)
printf '# start\n%s\nstray\n' "$BEGIN_MARK" >"$broken/.zshrc"
if install_into "$broken" "$forks" >/dev/null 2>&1; then
    fail 'install: refuses a file with unpaired markers'
else
    pass 'install: refuses a file with unpaired markers'
fi

# --- a start-up file that does not exist yet -------------------------------

# Which file appears depends on the shells the machine carries: a Linux
# image with no zsh gets ~/.bashrc alone, and rightly so. Assert that at
# least one start-up file was created and carries the block.
fresh="$SANDBOX/home-fresh"
mkdir -p "$fresh"
created=0
if install_into "$fresh" "$forks" >/dev/null 2>&1; then
    for file in "$fresh/.zshrc" "$fresh/.bashrc"; do
        if [ -f "$file" ] && grep -qxF "$BEGIN_MARK" "$file"; then
            created=$((created + 1))
        fi
    done
fi
if [ "$created" -gt 0 ]; then
    pass 'install: creates a missing start-up file'
else
    fail 'install: creates a missing start-up file'
fi

# --- result ----------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
