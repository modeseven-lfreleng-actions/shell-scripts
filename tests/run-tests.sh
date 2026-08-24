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

# The installer honours $ZDOTDIR, which overrides HOME for zsh's start-up
# file. Left set, it would send every install below at the real ~/.zshrc
# of whoever is running the suite -- and the uninstall test would then
# strip their genuine block. Clear it before anything else runs.
unset ZDOTDIR

REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BEGIN_MARK='# >>> lfreleng-actions/shell-scripts >>>'
END_MARK='# <<< lfreleng-actions/shell-scripts <<<'
SANDBOX=''
passed=0
failed=0
skipped=0

cleanup() {
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
    return 0
}

# A handler that only tidied up would swallow the signal and let the
# suite carry on against a sandbox it had just deleted. Clean up and
# leave, as the installer does.
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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

# --- the block keeps its place ---------------------------------------------

# Anything written after the block runs after it today. Re-installing
# must not move the block to the end and put those lines in front of the
# variables and functions it defines.
place_home=$(new_home place)
install_into "$place_home" "$forks" >/dev/null 2>&1
printf '\n# after the block\nalias later="echo later"\n' >>"$place_home/.zshrc"
install_into "$place_home" "$forks" >/dev/null 2>&1
if [ "$(grep -n 'alias later' "$place_home/.zshrc" | cut -d: -f1)" -gt \
    "$(grep -nxF "$END_MARK" "$place_home/.zshrc" | cut -d: -f1)" ]; then
    pass 'install: re-installing leaves the block where it was'
else
    fail 'install: re-installing leaves the block where it was' \
        "$(cat "$place_home/.zshrc")"
fi
if grep -q '^alias ll' "$place_home/.zshrc" &&
    [ "$(grep -n 'alias ll' "$place_home/.zshrc" | cut -d: -f1)" -lt \
    "$(grep -nxF "$BEGIN_MARK" "$place_home/.zshrc" | cut -d: -f1)" ]; then
    pass 'install: content before the block stays before it'
else
    fail 'install: content before the block stays before it'
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

    # A word whose only slash is the trailing one that completion leaves
    # behind is tried as a path first...
    got=$(env -i HOME="$home" PATH="$PATH" bash --rcfile "$home/.bashrc" -i -c \
        "cd '$forks' && release example-repo/" 2>&1 || true)
    case "$got" in
        *"working in example-repo"*)
            pass 'release: a completed directory is tried as a path' ;;
        *)  fail 'release: a completed directory is tried as a path' "$got" ;;
    esac

    # ...and falls back to the roots when that finds nothing, so typing
    # the slash out of habit from elsewhere still works.
    got=$(run_release 'cd / && release example-repo/')
    case "$got" in
        *"working in $forks/example-repo"*)
            pass 'release: a trailing slash still reaches the clone roots' ;;
        *)  fail 'release: a trailing slash still reaches the clone roots' \
                "$got" ;;
    esac

    # That relative path meets 'cd', which consults CDPATH. A decoy of
    # the same name on CDPATH must not capture it: the recursive call
    # would tag whatever it landed in. The decoy carries a remote, so
    # the two are told apart by which message comes back.
    decoy="$SANDBOX/cdp-decoy"
    mkdir -p "$decoy"
    git init -q "$decoy/example-repo"
    git -C "$decoy/example-repo" remote add origin "$decoy/nowhere.git"
    got=$(env -i HOME="$home" PATH="$PATH" CDPATH="$decoy" \
        bash --rcfile "$home/.bashrc" -i -c \
        "cd '$forks' && release example-repo/" 2>&1 || true)
    case "$got" in
        *"no 'upstream' or 'origin' remote configured"*)
            pass 'release: CDPATH cannot redirect the recursive step' ;;
        *)  fail 'release: CDPATH cannot redirect the recursive step' "$got" ;;
    esac

    got=$(run_release \
        'cd / && unset LFRELENG_ACTIONS_FORK_PATH && release anything')
    case "$got" in
        *'no search'*) pass 'release: explains an unset search root' ;;
        *) fail 'release: explains an unset search root' "$got" ;;
    esac

    # 'latest' is the function's own keyword. A clone that happens to
    # carry that name must not capture the documented form.
    git init -q "$forks/latest"
    got=$(env -i HOME="$home" PATH="$PATH" bash --rcfile "$home/.bashrc" -i -c \
        "cd '$forks/example-repo' && release latest" 2>&1 || true)
    case "$got" in
        *"'latest' names a clone"*)
            fail "release: 'latest' is never read as a repository name" "$got" ;;
        *)  pass "release: 'latest' is never read as a repository name" ;;
    esac
else
    skip 'release: finds a clone under the recorded directory' \
        'git or bash not installed'
fi

# --- bash login shells -----------------------------------------------------

# A login shell reads the first of ~/.bash_profile, ~/.bash_login and
# ~/.profile that exists, and nothing else -- not ~/.bashrc. On a home
# with none of them, the installer has to create one, or macOS Terminal
# would open a shell that had never heard of these tools.
login_home="$SANDBOX/home-login"
mkdir -p "$login_home"
install_into "$login_home" "$forks" >/dev/null 2>&1
if command -v bash >/dev/null 2>&1; then
    check_output 'bash: a login shell on a bare home defines release' \
        function "$login_home" bash -lc 'type -t release'
else
    skip 'bash: a login shell on a bare home defines release' 'bash not installed'
fi

# --- a clone root given as a PATH-style list -------------------------------

# LFRELENG_ACTIONS_FORK_PATH may hold several roots, and anything the
# block derived from it would then name nothing.
if command -v bash >/dev/null 2>&1; then
    got=$(env -i HOME="$home" PATH="$PATH" \
        LFRELENG_ACTIONS_FORK_PATH="/nowhere-a:/nowhere-b" \
        bash --rcfile "$home/.bashrc" -i -c 'type -t release' 2>/dev/null)
    if [ "$got" = function ]; then
        pass 'loader: a colon-separated clone root still loads the tools'
    else
        fail 'loader: a colon-separated clone root still loads the tools' "$got"
    fi
else
    skip 'loader: a colon-separated clone root still loads the tools' \
        'bash not installed'
fi

# --- status ----------------------------------------------------------------

got=$(HOME="$home" "$REPO_DIR/install.sh" --status 2>&1)
case "$got" in
    *installed*) pass 'status: reports the block as installed' ;;
    *) fail 'status: reports the block as installed' "$got" ;;
esac

# The value in the block, not the one this process happens to carry.
got=$(env -i HOME="$home" PATH="$PATH" "$REPO_DIR/install.sh" --status 2>&1)
case "$got" in
    *"recorded"*"$forks"*)
        pass 'status: reports the recorded clone directory' ;;
    *)  fail 'status: reports the recorded clone directory' "$got" ;;
esac

# ...as the directory, not as the shell source that names it. The block
# holds '$HOME/a\$b', and a reader wants '/home/you/a$b'.
decode_home=$(new_home decode)
decode_root="$decode_home/a\$b:$decode_home/two"
mkdir -p "$decode_home/a\$b" "$decode_home/two"
HOME="$decode_home" "$REPO_DIR/install.sh" --yes --fork-path "$decode_root" \
    >/dev/null 2>&1
got=$(env -i HOME="$decode_home" PATH="$PATH" "$REPO_DIR/install.sh" --status 2>&1)
case "$got" in
    *"$decode_root"*)
        pass 'status: decodes the recorded value back to a directory' ;;
    *)  fail 'status: decodes the recorded value back to a directory' \
            "expected '$decode_root' in:
$got" ;;
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

# --- a start-up file that is a symlink --------------------------------------

# Many people keep their start-up files as symlinks into a dotfiles
# repository. Writing through the link is why the installer rewrites
# contents in place rather than renaming a temporary file over the top,
# and that guarantee is worth a test of its own.
link_home=$(new_home symlink)
mkdir -p "$link_home/dotfiles"
printf '# tracked zshrc\nalias dot="echo dot"\n' >"$link_home/dotfiles/zshrc"
rm -f "$link_home/.zshrc"
ln -s dotfiles/zshrc "$link_home/.zshrc"

install_into "$link_home" "$forks" >/dev/null 2>&1
if [ -L "$link_home/.zshrc" ]; then
    pass 'install: a symlinked start-up file stays a symlink'
else
    fail 'install: a symlinked start-up file stays a symlink'
fi
if grep -qxF "$BEGIN_MARK" "$link_home/dotfiles/zshrc"; then
    pass 'install: the block lands in the symlink target'
else
    fail 'install: the block lands in the symlink target'
fi
if grep -q '^alias dot' "$link_home/dotfiles/zshrc"; then
    pass 'install: the target keeps the content it had'
else
    fail 'install: the target keeps the content it had'
fi
if [ -s "$link_home/.zshrc.lfreleng.bak" ] &&
    grep -q '^alias dot' "$link_home/.zshrc.lfreleng.bak"; then
    pass 'install: the backup of a symlink holds the real content'
else
    fail 'install: the backup of a symlink holds the real content'
fi

HOME="$link_home" "$REPO_DIR/install.sh" --uninstall >/dev/null 2>&1
if [ -L "$link_home/.zshrc" ] &&
    ! grep -q 'lfreleng-actions/shell-scripts' "$link_home/dotfiles/zshrc" &&
    grep -q '^alias dot' "$link_home/dotfiles/zshrc"; then
    pass 'uninstall: the symlink and its target both survive'
else
    fail 'uninstall: the symlink and its target both survive'
fi

# --- half-deleted and misordered markers -----------------------------------

broken=$(new_home broken)
printf '# start\n%s\nstray\n' "$BEGIN_MARK" >"$broken/.zshrc"
if install_into "$broken" "$forks" >/dev/null 2>&1; then
    fail 'install: refuses a file with an unclosed marker'
else
    pass 'install: refuses a file with an unclosed marker'
fi

# One malformed file must stop the run before any other file is written,
# rather than partway through -- half the shells carrying the block and
# half not is a state nobody asked for.
partial=$(new_home partial)
printf '# start\n%s\nstray\n' "$BEGIN_MARK" >"$partial/.bashrc"
cp "$partial/.zshrc" "$SANDBOX/partial.zshrc.before"
if install_into "$partial" "$forks" >/dev/null 2>&1; then
    fail 'install: a malformed file stops the run before any write'
elif cmp -s "$SANDBOX/partial.zshrc.before" "$partial/.zshrc"; then
    pass 'install: a malformed file stops the run before any write'
else
    fail 'install: a malformed file stops the run before any write' \
        'another file had already been written'
fi

# The same for uninstall: a valid file must not lose its block when a
# later candidate turns out to be malformed.
partial2=$(new_home partial-uninstall)
install_into "$partial2" "$forks" >/dev/null 2>&1
cp "$partial2/.zshrc" "$SANDBOX/partial2.zshrc.before"
printf '# start\n%s\nstray\n' "$BEGIN_MARK" >"$partial2/.profile"
if HOME="$partial2" "$REPO_DIR/install.sh" --uninstall >/dev/null 2>&1; then
    fail 'uninstall: a malformed file stops the run before any write'
elif cmp -s "$SANDBOX/partial2.zshrc.before" "$partial2/.zshrc"; then
    pass 'uninstall: a malformed file stops the run before any write'
else
    fail 'uninstall: a malformed file stops the run before any write' \
        'another file had already been cleaned'
fi

# Markers are not the only way a target can be unusable. A later one
# that is a directory, or that cannot be written, has to stop the run
# before an earlier one is touched.
for bad_kind in directory unwritable; do
    bad_home=$(new_home "bad-$bad_kind")
    cp "$bad_home/.zshrc" "$SANDBOX/bad.zshrc.before"
    rm -f "$bad_home/.bashrc"
    case "$bad_kind" in
        directory)  mkdir -p "$bad_home/.bashrc" ;;
        unwritable) printf '# rc\n' >"$bad_home/.bashrc"
                    chmod 444 "$bad_home/.bashrc" ;;
    esac

    if install_into "$bad_home" "$forks" >/dev/null 2>&1; then
        fail "install: refuses a target that is $bad_kind"
    elif cmp -s "$SANDBOX/bad.zshrc.before" "$bad_home/.zshrc"; then
        pass "install: refuses a target that is $bad_kind"
    else
        fail "install: refuses a target that is $bad_kind" \
            'another file had already been written'
    fi
    chmod u+w "$bad_home/.bashrc" 2>/dev/null || true
done

# --- a home that cannot name start-up files --------------------------------

for bad_home_value in '' relative/path; do
    if HOME="$bad_home_value" "$REPO_DIR/install.sh" --status >/dev/null 2>&1; then
        fail "install: refuses HOME='$bad_home_value'"
    else
        pass "install: refuses HOME='$bad_home_value'"
    fi
done

# A relative ZDOTDIR resolves against whatever directory the reader
# happens to be in, which is one thing for this installer and another
# for the zsh that reads the file later.
if HOME="$SANDBOX" ZDOTDIR=relative/zdir \
    "$REPO_DIR/install.sh" --status >/dev/null 2>&1; then
    fail 'install: refuses a relative ZDOTDIR'
else
    pass 'install: refuses a relative ZDOTDIR'
fi

# --- permissions on a file the installer creates ---------------------------

# A permissive umask in the caller's environment must not leave shell
# configuration writable by anyone else: those lines run at every login.
umask_home="$SANDBOX/home-umask"
mkdir -p "$umask_home"
(
    umask 000
    HOME="$umask_home" "$REPO_DIR/install.sh" --yes --fork-path "$forks"
) >/dev/null 2>&1
for created in "$umask_home/.zshrc" "$umask_home/.bashrc"; do
    [ -f "$created" ] || continue
    name=$(basename "$created")

    # 'stat' spells its arguments differently on BSD and GNU, so read the
    # mode from ls: characters 6 and 9 of the first field are the group
    # and other write bits.
    # shellcheck disable=SC2012  # reading the mode, not a file name
    mode=$(LC_ALL=C ls -ld "$created")
    mode=${mode%% *}
    group_w=$(printf '%s' "$mode" | cut -c6)
    other_w=$(printf '%s' "$mode" | cut -c9)

    if [ "$group_w" = w ] || [ "$other_w" = w ]; then
        fail "install: a created $name is writable by its owner alone" \
            "mode $mode"
    else
        pass "install: a created $name is writable by its owner alone"
    fi
done

# --- a start-up file that is a symlink --------------------------------------
# A closing marker above an opening one balances by count, and would see
# strip_block keep the text above and drop everything below.
reversed=$(new_home reversed)
printf '# keep me\n%s\n# and me\n%s\n# and me too\n' \
    "$END_MARK" "$BEGIN_MARK" >"$reversed/.zshrc"
cp "$reversed/.zshrc" "$SANDBOX/reversed.before"
if install_into "$reversed" "$forks" >/dev/null 2>&1; then
    fail 'install: refuses a file with reversed markers'
elif cmp -s "$SANDBOX/reversed.before" "$reversed/.zshrc"; then
    pass 'install: refuses a file with reversed markers'
else
    fail 'install: refuses a file with reversed markers' 'the file changed'
fi

# --- awkward characters in the recorded path -------------------------------

# A path holding a dollar sign, a backtick, a quote or a backslash must
# reach the start-up file as itself. Left unescaped it would expand -- or
# run -- every time a shell starts, so the fixture carries one of each
# and two sentinels that only a command substitution could create.
awkward_home=$(new_home awkward)
sentinel_dollar="$SANDBOX/PWNED-dollar"
sentinel_backtick="$SANDBOX/PWNED-backtick"
awkward_root="$SANDBOX/awk-\$(touch $sentinel_dollar)-\`touch $sentinel_backtick\`-\"q\"-b\\s"
mkdir -p "$awkward_root"

if ! command -v bash >/dev/null 2>&1; then
    skip 'install: records a path holding shell metacharacters intact' \
        'bash not installed'
elif ! HOME="$awkward_home" "$REPO_DIR/install.sh" --yes \
    --fork-path "$awkward_root" >/dev/null 2>&1; then
    # Separate from the bash check above: an installer failure reported
    # as 'bash not installed' would hide a regression in this very path.
    fail 'install: records a path holding shell metacharacters intact' \
        'the installer refused the path'
else
    # shellcheck disable=SC2016  # the inner shell expands this, not us
    got=$(env -i HOME="$awkward_home" PATH="$PATH" bash \
        --rcfile "$awkward_home/.bashrc" -i -c \
        'printf %s "$LFRELENG_ACTIONS_FORK_PATH"' 2>/dev/null)

    if [ "$got" != "$awkward_root" ]; then
        fail 'install: records a path holding shell metacharacters intact' \
            "expected '$awkward_root', got '$got'"
    elif [ -f "$sentinel_dollar" ]; then
        fail 'install: records a path holding shell metacharacters intact' \
            'a command substitution ran'
    elif [ -f "$sentinel_backtick" ]; then
        fail 'install: records a path holding shell metacharacters intact' \
            'a backtick substitution ran'
    else
        pass 'install: records a path holding shell metacharacters intact'
    fi
fi

# The same characters again, one at a time, so a regression that mangles
# exactly one of them cannot hide behind the others.
if command -v bash >/dev/null 2>&1; then
    # shellcheck disable=SC1003  # a lone backslash in single quotes is literal
    for awkward_name in dollar backtick quote backslash bang; do
        case "$awkward_name" in
            dollar)    awkward_bit='$' ;;
            backtick)  awkward_bit='`' ;;
            quote)     awkward_bit='"' ;;
            backslash) awkward_bit='\' ;;
            bang)      awkward_bit='!' ;;
        esac

        one_home=$(new_home "awkward-$awkward_name")
        one_root="$SANDBOX/one${awkward_bit}dir"
        mkdir -p "$one_root"
        HOME="$one_home" "$REPO_DIR/install.sh" --yes --fork-path "$one_root" \
            >/dev/null 2>&1
        # shellcheck disable=SC2016  # the inner shell expands this, not us
        got=$(env -i HOME="$one_home" PATH="$PATH" bash \
            --rcfile "$one_home/.bashrc" -i -c \
            'printf %s "$LFRELENG_ACTIONS_FORK_PATH"' 2>/dev/null)
        if [ "$got" = "$one_root" ]; then
            pass "install: a path holding a $awkward_name round-trips"
        else
            fail "install: a path holding a $awkward_name round-trips" \
                "expected '$one_root', got '$got'"
        fi
    done
else
    skip 'install: awkward characters round-trip one at a time' \
        'bash not installed'
fi

# --- a login profile that mentions .bashrc -------------------------------

# No reading of ~/.bash_profile can prove that it reaches ~/.bashrc, so
# an existing one always gets the block. Two blocks in two files is
# redundant rather than wrong: sourcing loader.sh twice re-defines the
# same functions.
for variant in commented sourcing; do
    profile_home=$(new_home "profile-$variant")
    case "$variant" in
        commented) printf '# I used to: source ~/.bashrc\nexport FOO=1\n' ;;
        sourcing)  printf '# login\nif [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n' ;;
    esac >"$profile_home/.bash_profile"

    install_into "$profile_home" "$forks" >/dev/null 2>&1
    if grep -qxF "$BEGIN_MARK" "$profile_home/.bash_profile"; then
        pass "install: manages an existing .bash_profile ($variant)"
    else
        fail "install: manages an existing .bash_profile ($variant)"
    fi

    HOME="$profile_home" "$REPO_DIR/install.sh" --uninstall >/dev/null 2>&1
    if grep -q 'lfreleng-actions/shell-scripts' \
        "$profile_home/.bash_profile" "$profile_home/.bashrc"; then
        fail "install: uninstall clears .bash_profile too ($variant)"
    else
        pass "install: uninstall clears .bash_profile too ($variant)"
    fi
done

# --- the root directory is a valid, if eccentric, answer -------------------

root_home=$(new_home root)
if HOME="$root_home" "$REPO_DIR/install.sh" --yes --fork-path / \
    >/dev/null 2>&1 &&
    grep -q 'LFRELENG_ACTIONS_FORK_PATH="/"' "$root_home/.zshrc"; then
    pass 'install: accepts / as the clone directory'
else
    fail 'install: accepts / as the clone directory'
fi

# An explicitly empty answer is a mistake worth reporting, not an
# instruction to use the default.
empty_home=$(new_home empty)
if HOME="$empty_home" "$REPO_DIR/install.sh" --yes --fork-path '' \
    >/dev/null 2>&1; then
    fail 'install: refuses an explicitly empty clone directory'
elif grep -qxF "$BEGIN_MARK" "$empty_home/.zshrc"; then
    fail 'install: refuses an explicitly empty clone directory' \
        'it installed anyway'
else
    pass 'install: refuses an explicitly empty clone directory'
fi

# --- the tools survive a caller running under set -u -----------------------

# release() lives in the caller's shell, where a bare $2 would be an
# error rather than an empty string.
for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
        skip "$shell: release survives 'set -u'" "$shell not installed"
        continue
    fi
    got=$(env -i HOME="$home" PATH="$PATH" "$shell" -c \
        ". '$REPO_DIR/loader.sh'; set -u; cd /; release; echo \"rc=\$?\"" \
        2>/dev/null)
    case "$got" in
        *'rc=2'*) pass "$shell: release survives 'set -u'" ;;
        *) fail "$shell: release survives 'set -u'" "$got" ;;
    esac
done

# --- release: refusals that need no network and no signing key -------------
#
# Build a clone with real 'upstream' and 'origin' remotes, both local bare
# repositories, and prove the guards that stand between a stale or dirty
# checkout and a signed tag. Nothing here reaches 'git tag -s' or 'gh'.

if command -v git >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    # A home of its own: the uninstall test above stripped the block from
    # $home, so the tools are no longer there to call.
    release_home=$(new_home release)
    install_into "$release_home" "$forks" >/dev/null 2>&1

    fixture="$SANDBOX/fixture"
    mkdir -p "$fixture"
    (
        set -e
        cd "$fixture"
        export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
        export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
        git init -q --bare upstream.git
        git init -q --bare origin.git
        git init -q -b main work
        cd work
        # A local identity, not an exported one: later commits run from
        # 'env -i' shells that carry no environment at all, and a runner
        # has no global git identity to fall back on.
        git config user.name Test
        git config user.email test@example.invalid
        git config commit.gpgsign false
        git config tag.gpgsign false
        echo one >file
        git add file
        git commit -q -m 'Initial commit'
        git remote add upstream "$fixture/upstream.git"
        git remote add origin "$fixture/origin.git"
        git push -q upstream main
        git push -q origin main
        # Give both bare repositories a resolvable symbolic HEAD, as a
        # real forge does. 'git init --bare' points HEAD at whatever
        # init.defaultBranch says, which is unset on a machine with no
        # global git config -- leaving HEAD naming a branch that does not
        # exist, and the tests measuring the environment rather than the
        # tool.
        git -C "$fixture/upstream.git" symbolic-ref HEAD refs/heads/main
        git -C "$fixture/origin.git" symbolic-ref HEAD refs/heads/main
        git tag -a v0.0.1 -m v0.0.1
        git push -q upstream refs/tags/v0.0.1
        git tag -d v0.0.1 >/dev/null
    ) >"$SANDBOX/fixture.log" 2>&1 || fail 'release: fixture builds' \
        "$(cat "$SANDBOX/fixture.log")"

    in_fixture() {
        case "$fixture_shell" in
            bash)
                env -i HOME="$release_home" PATH="$PATH" bash \
                    --rcfile "$release_home/.bashrc" -i -c \
                    "cd '$fixture/work' && $1; echo \"__rc=\$?\"" 2>&1
                ;;
            *)
                # zsh reads $HOME/.zshrc for an interactive shell, so it
                # needs no equivalent of --rcfile.
                env -i HOME="$release_home" PATH="$PATH" "$fixture_shell" -i -c \
                    "cd '$fixture/work' && $1; echo \"__rc=\$?\"" 2>&1
                ;;
        esac
    }

    # Assert that a command both reports the expected refusal and returns
    # non-zero. Matching the message alone would let a regression that
    # printed the refusal and then returned success pass unnoticed --
    # which is the shape a caller would act on as if it had worked.
    assert_refusal() {
        _ar_name=$1
        _ar_want=$2
        _ar_out=$(in_fixture "$3")
        _ar_rc=${_ar_out##*__rc=}
        _ar_text=${_ar_out%__rc=*}

        case "$_ar_text" in
            *"$_ar_want"*)
                if [ "$_ar_rc" = 0 ]; then
                    fail "$_ar_name" 'printed the refusal but returned 0'
                else
                    pass "$_ar_name"
                fi
                ;;
            *) fail "$_ar_name" "$_ar_out" ;;
        esac
    }

    # The core refusals run under both supported shells. release() is
    # sourced into the caller's shell and leans on constructs the two
    # spell differently, so proving them in bash alone would leave the
    # zsh half of the audience covered by parse checks and hope.
    for fixture_shell in bash zsh; do
        if ! command -v "$fixture_shell" >/dev/null 2>&1; then
            skip "$fixture_shell: core release refusals" \
                "$fixture_shell not installed"
            continue
        fi

        assert_refusal \
            "$fixture_shell: refuses to tag over uncommitted work" \
            'working tree is dirty' 'echo dirty >> file && release v9.9.9'
        (cd "$fixture/work" && git checkout -q -- file)

        assert_refusal \
            "$fixture_shell: refuses a tag the remote already carries" \
            "tag 'v0.0.1' already exists" 'release v0.0.1'

        assert_refusal \
            "$fixture_shell: refuses a remote that does not exist" \
            "no remote named 'nosuchremote'" 'release v9.9.9 nosuchremote'

        assert_refusal \
            "$fixture_shell: refuses to switch branches over untracked files" \
            'untracked files would come too' \
            'git checkout -q -b side2 && : > scratch.txt && release latest'
        (cd "$fixture/work" && rm -f scratch.txt &&
            git checkout -q main && git branch -q -D side2)

        assert_refusal \
            "$fixture_shell: reports local commits rather than dropping them" \
            'holds commits that are not on' \
            'git commit -q --allow-empty -m Local && release latest'
        (cd "$fixture/work" && git reset -q --hard upstream/main)

        assert_refusal \
            "$fixture_shell: refuses an argument too many" \
            'too many arguments' 'release v1.2.3 origin typo'

        assert_refusal \
            "$fixture_shell: a path with a digit is not read as a version" \
            "no clone at 'other/repo2'" 'release other/repo2'
    done
    fixture_shell=bash

    # The rest run under bash alone: they turn on fixture surgery --
    # rewriting remote URLs, wrapper binaries on PATH -- rather than on
    # anything the two shells do differently.
    assert_refusal 'release: a path-shaped typo is not tagged' \
        "no clone at 'other/repo'" 'release other/repo'

    # A bare digitless word that names no clone stays the caller's to
    # tag, which is the fall-through those two must not disturb.
    got=$(in_fixture 'release nightly')
    case "$got" in
        *'no clone'*)
            fail 'release: a bare digitless word is still tagged as asked' \
                "$got" ;;
        *)  pass 'release: a bare digitless word is still tagged as asked' ;;
    esac

    # ...which leaves --tag as the way to say 'this really is the tag'.
    # A slash-bearing name such as 'release/1.2' is a legitimate git tag
    # and must not read as a path.
    got=$(in_fixture 'release --tag release/1.2')
    case "$got" in
        *'no clone at'*)
            fail 'release: --tag takes a slash-bearing tag literally' "$got" ;;
        *)  pass 'release: --tag takes a slash-bearing tag literally' ;;
    esac

    # Likewise a tag literally named 'latest', which would otherwise be
    # the keyword and send the function off to read a draft release.
    got=$(in_fixture 'release --tag latest')
    case "$got" in
        *'GitHub CLI'*|*'draft'*)
            fail 'release: --tag latest is a name, not the keyword' "$got" ;;
        *)  pass 'release: --tag latest is a name, not the keyword' ;;
    esac

    assert_refusal 'release: --tag needs a name' \
        'needs a version to tag' 'release --tag'

    # ...and under 'set -e', where a git command that answers with a
    # non-zero status -- 'symbolic-ref' on a detached HEAD, say -- would
    # end the session instead of letting the warning print.
    for shell in bash zsh; do
        if ! command -v "$shell" >/dev/null 2>&1; then
            skip "$shell: release survives 'set -e' on a detached HEAD" \
                "$shell not installed"
            continue
        fi
        got=$(env -i HOME="$release_home" PATH="$PATH" "$shell" -c \
            ". '$REPO_DIR/loader.sh'
             set -e
             cd '$fixture/work'
             git checkout -q --detach
             release v9.9.4" 2>&1 || true)
        (cd "$fixture/work" && git checkout -q main)
        case "$got" in
            *"on 'detached HEAD', not 'main'"*)
                pass "$shell: release survives 'set -e' on a detached HEAD" ;;
            *)  fail "$shell: release survives 'set -e' on a detached HEAD" \
                    "$got" ;;
        esac
    done

    # A clone whose only remote goes by neither conventional name still
    # has a source of truth, and skipping the sync there would tag
    # whatever age of HEAD happened to be checked out.
    custom="$SANDBOX/custom-remote"
    git clone -q "$fixture/upstream.git" "$custom" 2>/dev/null
    (cd "$custom" &&
        git config user.name Test &&
        git config user.email test@example.invalid &&
        git remote rename origin gh)
    got=$(env -i HOME="$release_home" PATH="$PATH" bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$custom' && release v9.9.3 gh" 2>&1 || true)
    case "$got" in
        *'no remote to sync from'*|*"no 'upstream' or 'origin' remote to sync"*)
            fail 'release: syncs from a remote by an unconventional name' \
                "$got" ;;
        *'already matches gh/main'*|*"fast-forwarded 'main' to gh/main"*)
            pass 'release: syncs from a remote by an unconventional name' ;;
        *)  fail 'release: syncs from a remote by an unconventional name' \
                "$got" ;;
    esac

    # A server that has renamed its default branch leaves this clone's
    # cached refs/remotes/<remote>/HEAD naming the old one. The release
    # must follow the remote, and the clone's own view should end up
    # matching -- which needs the fetch to have happened first, since
    # 'git remote set-head' wants the tracking ref to exist.
    renamed="$SANDBOX/renamed"
    renamed_up="$SANDBOX/renamed-up.git"
    git init -q --bare -b main "$renamed_up"
    git clone -q "$renamed_up" "$renamed" 2>/dev/null
    (
        set -e
        cd "$renamed"
        git config user.name Test
        git config user.email test@example.invalid
        git config commit.gpgsign false
        git commit -q --allow-empty -m seed
        git push -q origin main
        git remote rename origin upstream
    ) >/dev/null 2>&1
    git -C "$renamed_up" branch -m main trunk
    git -C "$renamed_up" symbolic-ref HEAD refs/heads/trunk
    # Follow the rename locally too, so the sync runs rather than
    # standing aside as it rightly does for a version named on a branch
    # that is not the default one.
    git -C "$renamed" checkout -q -b trunk
    # git 2.47 and later update the remote HEAD on fetch by themselves,
    # which would make this test pass whatever the tool did. Turn that
    # off, so what is measured is the tool's own call -- and so that the
    # test also describes the older git where it is the only mechanism.
    git -C "$renamed" config remote.upstream.followRemoteHEAD never

    got=$(env -i HOME="$release_home" PATH="$PATH" bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$renamed' && release v9.9.2" 2>&1 || true)
    case "$got" in
        *'upstream/trunk'*)
            pass 'release: follows a default branch renamed on the server' ;;
        *)  fail 'release: follows a default branch renamed on the server' \
                "$got" ;;
    esac
    if [ "$(git -C "$renamed" symbolic-ref --short refs/remotes/upstream/HEAD 2>/dev/null)" \
        = upstream/trunk ]; then
        pass 'release: leaves the cached default branch matching the remote'
    else
        fail 'release: leaves the cached default branch matching the remote' \
            "$(git -C "$renamed" symbolic-ref --short refs/remotes/upstream/HEAD 2>&1)"
    fi

    # A staged submodule pointer is uncommitted work, and a clone
    # configured with diff.ignoreSubmodules=all would hide it from the
    # dirty-tree guard unless that setting is overridden outright.
    submod="$SANDBOX/submodule-main"
    submod_sub="$SANDBOX/submodule-sub"
    if git init -q "$submod_sub" >/dev/null 2>&1 &&
        (
            set -e
            cd "$submod_sub"
            git config user.name Test
            git config user.email test@example.invalid
            git config commit.gpgsign false
            git commit -q --allow-empty -m s1
            git commit -q --allow-empty -m s2
        ) >/dev/null 2>&1 &&
        git clone -q "$fixture/upstream.git" "$submod" >/dev/null 2>&1 &&
        (
            set -e
            cd "$submod"
            git config user.name Test
            git config user.email test@example.invalid
            git config commit.gpgsign false
            git remote rename origin upstream
            git -c protocol.file.allow=always submodule add -q "$submod_sub" sub
            git commit -q -m 'Add the submodule'
            cd sub && git checkout -q HEAD~1
            cd .. && git add sub
            # The setting that would otherwise hide it.
            git config diff.ignoreSubmodules all
        ) >/dev/null 2>&1; then

        got=$(env -i HOME="$release_home" PATH="$PATH" bash \
            --rcfile "$release_home/.bashrc" -i -c \
            "cd '$submod' && release latest; echo \"__rc=\$?\"" 2>&1)
        case "$got" in
            *'working tree is dirty'*__rc=0)
                fail 'release: a staged submodule pointer counts as dirty' \
                    'printed the refusal but returned 0' ;;
            *'working tree is dirty'*)
                pass 'release: a staged submodule pointer counts as dirty' ;;
            *)  fail 'release: a staged submodule pointer counts as dirty' \
                    "$got" ;;
        esac
    else
        skip 'release: a staged submodule pointer counts as dirty' \
            'this git will not build the submodule fixture'
    fi

    # A clone with no commits reaching the tagging step -- which the
    # sync would otherwise have prevented -- has an unborn HEAD, and
    # every git command from there on would fail in git's own words.
    empty_clone="$SANDBOX/empty-clone"
    git init -q -b main "$empty_clone"
    (cd "$empty_clone" &&
        git config user.name Test &&
        git config user.email test@example.invalid &&
        git remote add upstream "$fixture/upstream.git")
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_NO_SYNC=1 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$empty_clone' && release --tag v1.0.0; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'no commits'*__rc=0)
            fail 'release: refuses a clone with no commits' \
                'printed the refusal but returned 0' ;;
        *'no commits'*)
            pass 'release: refuses a clone with no commits' ;;
        *)  fail 'release: refuses a clone with no commits' "$got" ;;
    esac

    # A bare repository answers 'false' to --is-inside-work-tree and
    # exits 0, so the status alone would let one through to the tagging.
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_NO_SYNC=1 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/upstream.git' && release v9.9.9; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'bare repository'*__rc=0) fail 'release: refuses to tag from a bare repository' \
            'printed the refusal but returned 0' ;;
        *'bare repository'*)
            pass 'release: refuses to tag from a bare repository' ;;
        *)  fail 'release: refuses to tag from a bare repository' "$got" ;;
    esac

    # A clone with no commits sits on an unborn branch: symbolic-ref
    # answers 'main' while refs/heads/main does not exist, so comparing
    # names alone would skip the branch creation and leave every later
    # 'rev-parse HEAD' to fail.
    unborn="$SANDBOX/unborn"
    git init -q -b main "$unborn"
    (cd "$unborn" &&
        git config user.name Test &&
        git config user.email test@example.invalid &&
        git remote add upstream "$fixture/upstream.git")
    got=$(env -i HOME="$release_home" PATH="$PATH" bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$unborn' && release v9.9.7" 2>&1 || true)
    case "$got" in
        *"created 'main' from upstream/main"*)
            pass 'release: populates an unborn branch from the remote' ;;
        *)  fail 'release: populates an unborn branch from the remote' "$got" ;;
    esac

    # A named version on a side branch is a deliberate act, so the sync
    # stands aside with a warning rather than moving the checkout. This
    # one is not a refusal: it warns and carries on to the signing step,
    # which is where it stops for want of a key.
    got=$(in_fixture 'git checkout -q -b side && release v9.9.9')
    case "$got" in
        *"on 'side', not 'main'"*)
            pass 'release: leaves a side branch alone, with a warning' ;;
        *)  fail 'release: leaves a side branch alone, with a warning' "$got" ;;
    esac
    (cd "$fixture/work" && git checkout -q main && git branch -q -D side)

    # A remote that reads one repository and writes another cannot be
    # released from: everything the function inspects would describe a
    # repository other than the one the tag lands on. A second push URL
    # alongside a matching first is the same problem, twice over.
    (cd "$fixture/work" &&
        git remote set-url --push upstream "$fixture/origin.git")
    assert_refusal 'release: refuses a remote with a separate push URL' \
        'does not fetch and push one URL' 'release v9.9.9'

    (cd "$fixture/work" &&
        git remote set-url --push upstream "$fixture/upstream.git" &&
        git remote set-url --add --push upstream "$fixture/origin.git")
    assert_refusal 'release: refuses a remote with two push URLs' \
        'does not fetch and push one URL' 'release v9.9.9'

    (cd "$fixture/work" &&
        git config --unset-all remote.upstream.pushurl)

    # A second fetch URL is the same ambiguity from the other side: only
    # the first is used for fetching, so 'get-url' without --all would
    # report a tidy single URL and hide it.
    (cd "$fixture/work" &&
        git remote set-url --add upstream "$fixture/origin.git" &&
        git config --add remote.upstream.pushurl "$fixture/upstream.git")
    assert_refusal 'release: refuses a remote with two fetch URLs' \
        'does not fetch and push one URL' 'release v9.9.9'
    (cd "$fixture/work" &&
        git config --unset-all remote.upstream.pushurl &&
        git remote set-url --delete upstream "$fixture/origin.git")

    # Zero push URLs is not a clean answer either -- a query that failed,
    # or a git too old for '--all'. A wrapper that fails exactly that one
    # call stands in for both.
    nopush_bin="$SANDBOX/nopush"
    mkdir -p "$nopush_bin"
    ln -sf "$(command -v git)" "$nopush_bin/realgit"
    cat >"$nopush_bin/git" <<'NOPUSH'
#!/bin/sh
if [ "$1" = remote ] && [ "$2" = get-url ] && [ "$3" = --push ]; then
    exit 1
fi
exec "$(dirname "$0")/realgit" "$@"
NOPUSH
    chmod +x "$nopush_bin/git"

    got=$(env -i HOME="$release_home" PATH="$nopush_bin:$PATH" bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release v9.9.9; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'does not fetch and push one URL'*__rc=0)
            fail 'release: refuses when no push URL is reported' \
                'printed the refusal but returned 0' ;;
        *'does not fetch and push one URL'*)
            pass 'release: refuses when no push URL is reported' ;;
        *)  fail 'release: refuses when no push URL is reported' "$got" ;;
    esac

    # A remote URL can carry credentials, and these diagnostics get
    # pasted into issues. Nothing between '//' and '@' may survive.
    (cd "$fixture/work" &&
        git remote set-url upstream 'https://s3cr3t-token@example.invalid/o/r.git' &&
        git remote set-url --push upstream 'https://other@example.invalid/o/r.git')
    got=$(in_fixture 'release v9.9.9')
    case "$got" in
        *s3cr3t*)
            fail 'release: redacts credentials in a remote URL' "$got" ;;
        *'***@example.invalid'*)
            pass 'release: redacts credentials in a remote URL' ;;
        *)  fail 'release: redacts credentials in a remote URL' "$got" ;;
    esac
    (cd "$fixture/work" &&
        git config --unset-all remote.upstream.pushurl &&
        git remote set-url upstream "$fixture/upstream.git")

    # The fork mirror is best-effort, so a split 'origin' warns and is
    # stepped over rather than stopping the release.
    (cd "$fixture/work" &&
        git remote set-url --push origin "$fixture/upstream.git")
    got=$(in_fixture 'release latest')
    case "$got" in
        *'origin does not fetch and push one URL'*)
            pass 'release: leaves a split origin alone, with a warning' ;;
        *)  fail 'release: leaves a split origin alone, with a warning' "$got" ;;
    esac
    (cd "$fixture/work" && git config --unset-all remote.origin.pushurl)

    # An origin whose push destination cannot be read at all is the same
    # unsafe state as one pointing elsewhere, and must not be mirrored to
    # on the strength of not knowing. A wrapper that fails that one
    # query, for that one remote, stands in.
    noorigin_bin="$SANDBOX/noorigin"
    mkdir -p "$noorigin_bin"
    ln -sf "$(command -v git)" "$noorigin_bin/realgit"
    cat >"$noorigin_bin/git" <<'NOORIGIN'
#!/bin/sh
if [ "$1" = remote ] && [ "$2" = get-url ] && [ "$3" = --push ]; then
    for arg in "$@"; do last=$arg; done
    [ "$last" = origin ] && exit 1
fi
exec "$(dirname "$0")/realgit" "$@"
NOORIGIN
    chmod +x "$noorigin_bin/git"

    got=$(env -i HOME="$release_home" PATH="$noorigin_bin:$PATH" bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release v9.9.1" 2>&1 || true)
    case "$got" in
        *'origin does not fetch and push one URL'*)
            pass 'release: an unreadable origin push URL leaves the fork alone' ;;
        *)  fail 'release: an unreadable origin push URL leaves the fork alone' \
                "$got" ;;
    esac

    # An unreadable remote must never read as a clean answer. Point
    # 'upstream' at a path that does not exist and prove each query that
    # guards the tag stops the run rather than shrugging.
    (cd "$fixture/work" &&
        git remote set-url upstream "$fixture/gone.git")
    assert_refusal 'release: stops when the default branch cannot be read' \
        'cannot read the default branch' 'release v9.9.9'

    # With the sync out of the way, the tag-existence query is the next
    # thing to consult that same unreachable remote.
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_NO_SYNC=1 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release v9.9.9; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'cannot read tags from'*__rc=0)
            fail 'release: stops when the remote tags cannot be read' \
                'printed the refusal but returned 0' ;;
        *'cannot read tags from'*)
            pass 'release: stops when the remote tags cannot be read' ;;
        *)  fail 'release: stops when the remote tags cannot be read' "$got" ;;
    esac

    (cd "$fixture/work" &&
        git remote set-url upstream "$fixture/upstream.git")

    # An authority carrying a port is not a host name, and 'gh' takes a
    # host name. Reading the draft from one endpoint while the tag lands
    # on another is the silent-wrong-answer this function exists to
    # avoid, so it refuses -- and RELEASE_GH_HOST is the way through.
    (cd "$fixture/work" &&
        git remote set-url upstream 'ssh://git@ghe.example:8443/o/r.git')
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_NO_SYNC=1 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'needs the GitHub CLI'*)
            skip 'release: refuses a remote host carrying a port' \
                'gh not installed' ;;
        *'port or an IPv6 literal'*__rc=0)
            fail 'release: refuses a remote host carrying a port' \
                'printed the refusal but returned 0' ;;
        *'port or an IPv6 literal'*)
            pass 'release: refuses a remote host carrying a port' ;;
        *)  fail 'release: refuses a remote host carrying a port' "$got" ;;
    esac

    # A conventional 'git' user in an ssh URL is not a credential, and
    # must not be reported as one.
    case "$got" in
        *'embeds credentials'*)
            fail "release: an ssh 'git@' user draws no credential warning" \
                "$got" ;;
        *)  pass "release: an ssh 'git@' user draws no credential warning" ;;
    esac

    # A bracketed IPv6 authority has to survive slug parsing far enough
    # to reach that refusal, and the override behind it. Splitting at the
    # first colon inside the brackets would leave no readable slug and
    # stop the run one message too early.
    (cd "$fixture/work" &&
        git remote set-url upstream 'ssh://git@[2001:db8::1]/o/r.git')
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_NO_SYNC=1 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest" 2>&1 || true)
    case "$got" in
        *'needs the GitHub CLI'*)
            skip 'release: an IPv6 remote reaches the authority refusal' \
                'gh not installed' ;;
        *'cannot read owner/repo'*)
            fail 'release: an IPv6 remote reaches the authority refusal' \
                "$got" ;;
        *'port or an IPv6 literal'*)
            pass 'release: an IPv6 remote reaches the authority refusal' ;;
        *)  fail 'release: an IPv6 remote reaches the authority refusal' "$got" ;;
    esac
    (cd "$fixture/work" &&
        git remote set-url upstream 'ssh://git@ghe.example:8443/o/r.git')

    # With the host named outright it gets past that check, and stops at
    # the next thing it cannot reach rather than at the authority.
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_NO_SYNC=1 \
        RELEASE_GH_HOST=ghe.example bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest" 2>&1 || true)
    case "$got" in
        *'needs the GitHub CLI'*)
            skip 'release: RELEASE_GH_HOST gets past the authority check' \
                'gh not installed' ;;
        *'port or an IPv6 literal'*)
            fail 'release: RELEASE_GH_HOST gets past the authority check' \
                "$got" ;;
        *)  pass 'release: RELEASE_GH_HOST gets past the authority check' ;;
    esac
    (cd "$fixture/work" &&
        git remote set-url upstream "$fixture/upstream.git")

    # A successful query that also writes to stderr -- a redirect notice,
    # a proxy grumble -- must not have that warning parsed as its answer.
    # A wrapper on PATH that chatters on stderr and then defers to the
    # real git reproduces it without needing an unreliable network.
    noisy_bin="$SANDBOX/noisy"
    mkdir -p "$noisy_bin"
    real_git=$(command -v git)
    # shellcheck disable=SC2016  # writing a script; the wrapper expands these
    {
        printf '#!/bin/sh\n'
        printf 'case "$1" in\n'
        printf '    ls-remote) echo "warning: redirecting to https://example.invalid/" >&2 ;;\n'
        printf 'esac\n'
        printf 'exec %s "$@"\n' "$real_git"
    } >"$noisy_bin/git"
    chmod +x "$noisy_bin/git"

    got=$(env -i HOME="$release_home" PATH="$noisy_bin:$PATH" bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release v9.9.6" 2>&1 || true)
    case "$got" in
        *'moved while syncing'*|*'no longer has a branch'*)
            fail 'release: a stderr warning is not parsed as the answer' \
                "$got" ;;
        *)  pass 'release: a stderr warning is not parsed as the answer' ;;
    esac

    # The capture helper writes through dynamic scope, so without local
    # declarations in release() every call would leave four variables --
    # one of them a captured error stream -- in the caller's shell. Run
    # something that reaches a capture, then look for them.
    for shell in bash zsh; do
        if ! command -v "$shell" >/dev/null 2>&1; then
            skip "$shell: release leaves no working variables behind" \
                "$shell not installed"
            continue
        fi

        probe="$SANDBOX/leak-probe-$shell.sh"
        # shellcheck disable=SC2016  # writing a script; the probe expands these
        {
            printf '. "%s/loader.sh"\n' "$REPO_DIR"
            printf 'cd "%s" || exit 1\n' "$fixture/work"
            printf 'release v9.9.5 >/dev/null 2>&1\n'
            printf 'for v in _release_out _release_err _release_err_file'
            printf ' _release_capture_rc; do\n'
            printf '    eval "val=\\${$v-UNSET}"\n'
            printf '    [ "$val" = UNSET ] || printf "%%s " "$v"\n'
            printf 'done\n'
        } >"$probe"

        got=$(env -i HOME="$release_home" PATH="$PATH" "$shell" "$probe" 2>&1)
        if [ -z "$got" ]; then
            pass "$shell: release leaves no working variables behind"
        else
            fail "$shell: release leaves no working variables behind" \
                "left set: $got"
        fi
    done

    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_DRAFTER_POLL=0 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest" 2>&1 || true)
    case "$got" in
        *'RELEASE_DRAFTER_POLL'*)
            pass 'release: refuses a poll interval that would never advance' ;;
        *'needs the GitHub CLI'*)
            skip 'release: refuses a poll interval that would never advance' \
                'gh not installed' ;;
        *)  fail 'release: refuses a poll interval that would never advance' \
                "$got" ;;
    esac

    # '00' is a zero that spells its way past a test for the literal '0',
    # and bash reads a leading zero as octal.
    got=$(env -i HOME="$release_home" PATH="$PATH" RELEASE_DRAFTER_POLL=00 bash \
        --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest" 2>&1 || true)
    case "$got" in
        *'RELEASE_DRAFTER_POLL'*)
            pass 'release: refuses a poll interval written with a leading zero' ;;
        *'needs the GitHub CLI'*)
            skip 'release: refuses a poll interval written with a leading zero' \
                'gh not installed' ;;
        *)  fail 'release: refuses a poll interval written with a leading zero' \
                "$got" ;;
    esac
else
    skip 'release: refusals that need no network' 'git or bash not installed'
fi

# --- a clone root given as a list ------------------------------------------

# LFRELENG_ACTIONS_FORK_PATH accepts several roots, PATH-style, so the
# installer has to record each entry rather than treating the whole
# string as one pathname -- which would rewrite a leading $HOME and
# spell every later entry out in full.
list_home=$(new_home list)
mkdir -p "$list_home/one" "$list_home/two"
HOME="$list_home" "$REPO_DIR/install.sh" --yes \
    --fork-path "$list_home/one:$list_home/two" >/dev/null 2>&1
# shellcheck disable=SC2016  # matching the literal text '$HOME' in the file
if grep -q 'LFRELENG_ACTIONS_FORK_PATH="\$HOME/one:\$HOME/two"' \
    "$list_home/.zshrc"; then
    pass 'install: records every entry of a list against the home directory'
else
    fail 'install: records every entry of a list against the home directory' \
        "$(grep LFRELENG_ACTIONS_FORK_PATH= "$list_home/.zshrc" || true)"
fi

# An inherited list carries a tilde per entry. Expanding the value as one
# string would reach the first entry only, leaving the second to be
# rejected as a relative path.
tilde_home=$(new_home tilde-list)
mkdir -p "$tilde_home/one" "$tilde_home/two"
# shellcheck disable=SC2088  # a literal tilde is exactly what is under test
if HOME="$tilde_home" LFRELENG_ACTIONS_FORK_PATH='~/one:~/two' \
    "$REPO_DIR/install.sh" --yes >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # matching the literal text '$HOME'
    if grep -q 'LFRELENG_ACTIONS_FORK_PATH="\$HOME/one:\$HOME/two"' \
        "$tilde_home/.zshrc"; then
        pass 'install: expands a tilde in every entry of an inherited list'
    else
        fail 'install: expands a tilde in every entry of an inherited list' \
            "$(grep LFRELENG_ACTIONS_FORK_PATH= "$tilde_home/.zshrc" || true)"
    fi
else
    fail 'install: expands a tilde in every entry of an inherited list' \
        'the installer refused the list'
fi

if command -v bash >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # the inner shell expands this, not us
    got=$(env -i HOME="$list_home" PATH="$PATH" bash \
        --rcfile "$list_home/.bashrc" -i -c \
        'printf %s "$LFRELENG_ACTIONS_FORK_PATH"' 2>/dev/null)
    if [ "$got" = "$list_home/one:$list_home/two" ]; then
        pass 'install: a recorded list reads back intact'
    else
        fail 'install: a recorded list reads back intact' \
            "expected '$list_home/one:$list_home/two', got '$got'"
    fi
else
    skip 'install: a recorded list reads back intact' 'bash not installed'
fi

# --- status agrees with itself ---------------------------------------------

# A block in a file this run would not choose is reported as stray, and
# has to answer for the recorded directory too -- naming a stray block
# and then claiming none exists would be a contradiction.
#
# Install without a ZDOTDIR, so the block lands in $HOME/.zshrc, then
# remove the other files it touched and ask for status with ZDOTDIR
# pointing somewhere unmanaged. That makes $HOME/.zshrc the only block
# left, and no longer a target this run would pick.
stray_home=$(new_home stray)
install_into "$stray_home" "$forks" >/dev/null 2>&1
rm -f "$stray_home/.bashrc" "$stray_home/.bash_profile" \
    "$stray_home/.bash_login" "$stray_home/.profile"
mkdir -p "$stray_home/zsh"
got=$(env -i HOME="$stray_home" PATH="$PATH" ZDOTDIR="$stray_home/zsh" \
    "$REPO_DIR/install.sh" --status 2>&1)
case "$got" in
    *'no managed block found'*)
        fail 'status: a stray block answers for the recorded directory' "$got" ;;
    *stray*"$forks"*)
        pass 'status: a stray block answers for the recorded directory' ;;
    *)  fail 'status: a stray block answers for the recorded directory' "$got" ;;
esac

# --- $ZDOTDIR moves zsh's file out of $HOME --------------------------------

zdot_home=$(new_home zdotdir)
mkdir -p "$zdot_home/zsh"
# Give the directory a .zshrc of its own, so the target is chosen because
# ZDOTDIR points at it rather than because the machine happens to carry
# zsh -- the ubuntu-latest image does not.
printf '# custom zshrc\n' >"$zdot_home/zsh/.zshrc"
ZDOTDIR="$zdot_home/zsh" HOME="$zdot_home" "$REPO_DIR/install.sh" \
    --yes --fork-path "$forks" >/dev/null 2>&1
if grep -qxF "$BEGIN_MARK" "$zdot_home/zsh/.zshrc" 2>/dev/null; then
    pass 'install: honours ZDOTDIR'
else
    fail 'install: honours ZDOTDIR'
fi

# The same value at uninstall time reaches it again...
ZDOTDIR="$zdot_home/zsh" HOME="$zdot_home" "$REPO_DIR/install.sh" \
    --uninstall >/dev/null 2>&1
if grep -q 'lfreleng-actions/shell-scripts' "$zdot_home/zsh/.zshrc" 2>/dev/null; then
    fail 'uninstall: honours ZDOTDIR'
else
    pass 'uninstall: honours ZDOTDIR'
fi

# ...and a block in $HOME is still found when ZDOTDIR points elsewhere,
# which is the transition that can be covered.
home_block=$(new_home zdotdir-home)
install_into "$home_block" "$forks" >/dev/null 2>&1
mkdir -p "$home_block/zsh"
ZDOTDIR="$home_block/zsh" HOME="$home_block" "$REPO_DIR/install.sh" \
    --uninstall >/dev/null 2>&1
if grep -q 'lfreleng-actions/shell-scripts' "$home_block/.zshrc"; then
    fail 'uninstall: reaches a home block while ZDOTDIR points elsewhere'
else
    pass 'uninstall: reaches a home block while ZDOTDIR points elsewhere'
fi

# --- release: the 'latest' path, against stub forge tooling ----------------
#
# Everything behind 'gh' -- the drafter wait, the closing probe, draft
# selection -- needs a forge to talk to. Two stubs stand in: a 'gh' that
# serves canned answers from a scripted queue, and a 'git' wrapper whose
# only trick is to report a forge-shaped URL for 'remote get-url', so the
# slug parses while every real operation still runs against the local
# bare repositories.

if command -v git >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 &&
    [ -d "$SANDBOX/fixture/work" ]; then
    stub_bin="$SANDBOX/stub"
    mkdir -p "$stub_bin"
    # Not 'git-something': git treats a neighbouring 'git-foo' on PATH as
    # the subcommand 'git foo' and refuses to exec it directly.
    ln -sf "$(command -v git)" "$stub_bin/realgit"

    cat >"$stub_bin/git" <<'GITSTUB'
#!/bin/sh
# Report a forge-shaped URL, so the slug parses. Everything else is the
# real git, working against the local bare repositories as before.
if [ "$1" = remote ] && [ "$2" = get-url ]; then
    echo 'git@example.invalid:owner/repo.git'
    exit 0
fi
exec "$(dirname "$0")/realgit" "$@"
GITSTUB
    chmod +x "$stub_bin/git"

    cat >"$stub_bin/gh" <<'GHSTUB'
#!/bin/sh
# Canned answers, chosen by the shape of the API path.
#
# GH_RUNS_ACTIVE is a comma-separated queue consumed by the unfiltered
# newest-runs probe, one value per call, the last value repeating. That
# lets a test say "report a run on the second look" and so prove which
# query noticed it.
for arg in "$@"; do
    case "$arg" in
        repos/*/releases*)
            printf '%s\n' "$GH_DRAFTS"
            exit 0
            ;;
        *runs\?per_page=*)
            if [ -s "$GH_RUNS_STATE" ]; then
                queue=$(cat "$GH_RUNS_STATE")
            else
                queue=$GH_RUNS_ACTIVE
            fi
            next=${queue%%,*}
            rest=${queue#*,}
            [ "$rest" = "$queue" ] && rest=$next
            printf '%s\n' "$next"
            printf '%s' "$rest" >"$GH_RUNS_STATE"
            exit 0
            ;;
        *runs\?status=queued*)
            # GH_STATUS_ACTIVE is a per-sweep queue: only the 'queued'
            # query consults it, so one value is consumed per sweep
            # rather than one per status.
            [ -n "${GH_RUNS_FAIL:-}" ] && exit 1
            if [ -n "${GH_STATUS_ACTIVE:-}" ]; then
                if [ -s "$GH_STATUS_STATE" ]; then
                    queue=$(cat "$GH_STATUS_STATE")
                else
                    queue=$GH_STATUS_ACTIVE
                fi
                next=${queue%%,*}
                rest=${queue#*,}
                [ "$rest" = "$queue" ] && rest=$next
                printf '%s\n' "$next"
                printf '%s' "$rest" >"$GH_STATUS_STATE"
                exit 0
            fi
            echo 0
            exit 0
            ;;
        *runs\?status=*)
            # GH_RUNS_FAIL turns this query into a failure, so that the
            # three-strikes abort can be exercised.
            [ -n "${GH_RUNS_FAIL:-}" ] && exit 1
            echo 0
            exit 0
            ;;
        */actions/workflows\?*)
            # The workflow listing. GH_NO_ACTIONS makes it fail, standing
            # in for a token that cannot read Actions -- which GitHub
            # reports as a 404, indistinguishable from absence.
            [ -n "${GH_NO_ACTIONS:-}" ] && exit 1
            printf '%s\n' "${GH_WORKFLOWS-.github/workflows/release-drafter.yaml}"
            exit 0
            ;;
        repos/*)                  echo main; exit 0 ;;
    esac
done
exit 1
GHSTUB
    chmod +x "$stub_bin/gh"

    # $1 is the queue of answers for the unfiltered newest-runs probe.
    # The timeout is short so that a stub of my own making cannot hang
    # the suite for the default ten minutes.
    run_latest() {
        rm -f "$SANDBOX/runs.state"
        env -i HOME="$release_home" PATH="$stub_bin:$PATH" \
            GH_DRAFTS="${2-v9.9.0	Nine	draft}" \
            GH_RUNS_ACTIVE="$1" \
            GH_RUNS_STATE="$SANDBOX/runs.state" \
            RELEASE_DRAFTER_POLL=1 \
            RELEASE_DRAFTER_TIMEOUT=20 \
            bash --rcfile "$release_home/.bashrc" -i -c \
            "cd '$fixture/work' && release latest; echo \"__rc=\$?\"" 2>&1
    }

    got=$(run_latest 0)
    case "$got" in
        *"resolves to tag 'v9.9.0'"*)
            pass 'release: resolves the drafted version through gh' ;;
        *)  fail 'release: resolves the drafted version through gh' "$got" ;;
    esac
    case "$got" in
        *"tagging "*" as 'v9.9.0'"*)
            pass 'release: reaches the tagging step with the drafted version' ;;
        *)  fail 'release: reaches the tagging step with the drafted version' \
                "$got" ;;
    esac

    # The per-status sweep reports idle every time, so only the closing
    # probe can see this run. Answering '1' first and '0' after proves
    # the confirming lap is what caught it.
    got=$(run_latest '1,0')
    case "$got" in
        *'waiting for 1 active'*)
            pass 'release: the closing probe catches a late-created run' ;;
        *)  fail 'release: the closing probe catches a late-created run' "$got" ;;
    esac
    case "$got" in
        *"resolves to tag 'v9.9.0'"*)
            pass 'release: carries on once the late run clears' ;;
        *)  fail 'release: carries on once the late run clears' "$got" ;;
    esac

    # More than one draft is the case the function must refuse rather
    # than guess at.
    got=$(run_latest 0 "v9.9.0	Nine	draft
v8.8.8	Eight	draft")
    case "$got" in
        *'refusing to guess'*__rc=0)
            fail 'release: refuses to guess between two drafts' \
                'printed the refusal but returned 0' ;;
        *'refusing to guess'*)
            pass 'release: refuses to guess between two drafts' ;;
        *)  fail 'release: refuses to guess between two drafts' "$got" ;;
    esac

    # No draft at all is the other half of that refusal.
    got=$(run_latest 0 '')
    case "$got" in
        *'no draft release'*__rc=0)
            fail 'release: refuses when there is no draft' \
                'printed the refusal but returned 0' ;;
        *'no draft release'*)
            pass 'release: refuses when there is no draft' ;;
        *)  fail 'release: refuses when there is no draft' "$got" ;;
    esac

    # A run that clears only after the caller's limit has passed must
    # not then succeed: the deadline is a limit, not a suggestion. The
    # status queue reports a run active for two laps, so the deadline is
    # reached, and idle on the third.
    #
    # Which of the two aborts fires depends on where the second boundary
    # falls, so the assertion is on the property rather than the wording:
    # the run stops, and nothing is tagged. Without the deadline check on
    # the confirmation path it proceeds to tag, so this still catches the
    # regression.
    rm -f "$SANDBOX/runs.state" "$SANDBOX/status.state"
    got=$(env -i HOME="$release_home" PATH="$stub_bin:$PATH" \
        GH_DRAFTS="v9.9.0	Nine	draft" \
        GH_RUNS_ACTIVE=0 \
        GH_STATUS_ACTIVE='1,1,0' \
        GH_RUNS_STATE="$SANDBOX/runs.state" \
        GH_STATUS_STATE="$SANDBOX/status.state" \
        RELEASE_DRAFTER_POLL=1 \
        RELEASE_DRAFTER_TIMEOUT=2 \
        bash --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'tagging '*)
            fail 'release: a run clearing past the deadline does not tag' \
                "$got" ;;
        *__rc=0)
            fail 'release: a run clearing past the deadline does not tag' \
                'returned success past the deadline' ;;
        *aborting*)
            pass 'release: a run clearing past the deadline does not tag' ;;
        *)  fail 'release: a run clearing past the deadline does not tag' "$got" ;;
    esac

    # An initially idle workflow has taken none of the caller's time, so
    # a zero timeout still confirms and proceeds rather than aborting on
    # the confirmation lap.
    rm -f "$SANDBOX/runs.state" "$SANDBOX/status.state"
    got=$(env -i HOME="$release_home" PATH="$stub_bin:$PATH" \
        GH_DRAFTS="v9.9.0	Nine	draft" \
        GH_RUNS_ACTIVE=0 \
        GH_RUNS_STATE="$SANDBOX/runs.state" \
        GH_STATUS_STATE="$SANDBOX/status.state" \
        RELEASE_DRAFTER_POLL=1 \
        RELEASE_DRAFTER_TIMEOUT=0 \
        bash --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest" 2>&1 || true)
    case "$got" in
        *"resolves to tag 'v9.9.0'"*)
            pass 'release: a zero timeout still clears an idle workflow' ;;
        *)  fail 'release: a zero timeout still clears an idle workflow' "$got" ;;
    esac

    # A clock cannot be relied on to advance. It may stop answering, or
    # stick at one value, or step backwards; in every case the wait has
    # to stay bounded, which is why the sleep counter is kept alongside
    # it as a lower bound.
    #
    # Non-interactive, unlike the fixture helpers: an interactive bash
    # ignores SIGTERM, so a regression here could not be bounded by
    # timeout(1) and would hang the suite instead of failing it.
    if command -v timeout >/dev/null 2>&1; then
        for clock_kind in stops sticks; do
            clock_bin="$SANDBOX/clock-$clock_kind"
            mkdir -p "$clock_bin"
            ln -sf "$stub_bin/gh" "$clock_bin/gh"
            ln -sf "$stub_bin/git" "$clock_bin/git"
            ln -sf "$stub_bin/realgit" "$clock_bin/realgit"

            case "$clock_kind" in
                stops)
                    cat >"$clock_bin/date" <<'STOPPEDCLOCK'
#!/bin/sh
# Answers once, then fails: a clock that dies mid-run.
if [ -f "$CLOCK_STATE" ]; then
    exit 1
fi
: >"$CLOCK_STATE"
echo 1000000000
STOPPEDCLOCK
                    ;;
                sticks)
                    cat >"$clock_bin/date" <<'STUCKCLOCK'
#!/bin/sh
# Always answers, always the same: a clock that never advances.
echo 1000000000
STUCKCLOCK
                    ;;
            esac
            chmod +x "$clock_bin/date"

            rm -f "$SANDBOX/runs.state" "$SANDBOX/status.state" \
                "$SANDBOX/clock.state"
            if timeout 60 env -i HOME="$release_home" PATH="$clock_bin:$PATH" \
                GH_DRAFTS="v9.9.0	Nine	draft" \
                GH_RUNS_ACTIVE=0 \
                GH_STATUS_ACTIVE=1 \
                GH_RUNS_STATE="$SANDBOX/runs.state" \
                GH_STATUS_STATE="$SANDBOX/status.state" \
                CLOCK_STATE="$SANDBOX/clock.state" \
                RELEASE_DRAFTER_POLL=1 \
                RELEASE_DRAFTER_TIMEOUT=3 \
                bash -c ". '$REPO_DIR/loader.sh'; cd '$fixture/work' && release latest" \
                >"$SANDBOX/clock.log" 2>&1
            then
                fail "release: a clock that $clock_kind still reaches the deadline" \
                    'the run succeeded, which it should not have'
            elif grep -q 'still running after' "$SANDBOX/clock.log"; then
                pass "release: a clock that $clock_kind still reaches the deadline"
            else
                fail "release: a clock that $clock_kind still reaches the deadline" \
                    "$(cat "$SANDBOX/clock.log")"
            fi
        done
    else
        skip 'release: a clock that misbehaves still reaches the deadline' \
            'timeout(1) not installed to bound the run'
    fi

    # A token that can read the repository but not its Actions gets a
    # 404 from GitHub, which is indistinguishable from the workflow being
    # absent. Reading that as absence would skip the wait altogether, so
    # an unreadable listing has to stop the run instead.
    rm -f "$SANDBOX/runs.state" "$SANDBOX/status.state"
    got=$(env -i HOME="$release_home" PATH="$stub_bin:$PATH" \
        GH_DRAFTS="v9.9.0	Nine	draft" \
        GH_RUNS_ACTIVE=0 \
        GH_NO_ACTIONS=1 \
        GH_RUNS_STATE="$SANDBOX/runs.state" \
        GH_STATUS_STATE="$SANDBOX/status.state" \
        bash --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'tagging '*)
            fail 'release: an unreadable workflow list stops the run' \
                'it tagged without waiting' ;;
        *'cannot list the workflows'*__rc=0)
            fail 'release: an unreadable workflow list stops the run' \
                'printed the refusal but returned 0' ;;
        *'cannot list the workflows'*)
            pass 'release: an unreadable workflow list stops the run' ;;
        *)  fail 'release: an unreadable workflow list stops the run' "$got" ;;
    esac

    # A workflow genuinely absent from a readable listing is a different
    # matter, and carries on without waiting.
    rm -f "$SANDBOX/runs.state" "$SANDBOX/status.state"
    got=$(env -i HOME="$release_home" PATH="$stub_bin:$PATH" \
        GH_DRAFTS="v9.9.0	Nine	draft" \
        GH_RUNS_ACTIVE=0 \
        GH_WORKFLOWS=".github/workflows/testing.yaml" \
        GH_RUNS_STATE="$SANDBOX/runs.state" \
        GH_STATUS_STATE="$SANDBOX/status.state" \
        bash --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest" 2>&1 || true)
    case "$got" in
        *'not waiting'*)
            pass 'release: a workflow absent from the listing is not waited on' ;;
        *)  fail 'release: a workflow absent from the listing is not waited on' \
                "$got" ;;
    esac

    # An unreadable drafter state must never read as an idle one. Three
    # laps of failed queries abort, before anything is tagged.
    rm -f "$SANDBOX/runs.state"
    got=$(env -i HOME="$release_home" PATH="$stub_bin:$PATH" \
        GH_DRAFTS="v9.9.0	Nine	draft" \
        GH_RUNS_ACTIVE=0 \
        GH_RUNS_FAIL=1 \
        GH_RUNS_STATE="$SANDBOX/runs.state" \
        RELEASE_DRAFTER_POLL=1 \
        RELEASE_DRAFTER_TIMEOUT=20 \
        bash --rcfile "$release_home/.bashrc" -i -c \
        "cd '$fixture/work' && release latest; echo \"__rc=\$?\"" 2>&1)
    case "$got" in
        *'cannot read'*'runs on'*__rc=0)
            fail 'release: aborts when the drafter state cannot be read' \
                'printed the refusal but returned 0' ;;
        *'cannot read'*'runs on'*)
            pass 'release: aborts when the drafter state cannot be read' ;;
        *)  fail 'release: aborts when the drafter state cannot be read' "$got" ;;
    esac
    case "$got" in
        *'tagging '*)
            fail 'release: an unreadable drafter state stops short of tagging' \
                "$got" ;;
        *)  pass 'release: an unreadable drafter state stops short of tagging' ;;
    esac
else
    skip 'release: the latest path, against stub forge tooling' \
        'git or bash not installed'
fi

# --- release: the success path, and the push that fails --------------------
#
# Everything above stops before 'git tag -s'. Signing needs a key, so
# these use SSH signing with a throwaway ed25519 pair: fast, needing no
# entropy ceremony and no agent, and enough for git to produce a signed
# annotated tag.

if command -v git >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 &&
    command -v ssh-keygen >/dev/null 2>&1 && [ -d "$SANDBOX/fixture/work" ]; then
    signing_key="$SANDBOX/signing-key"
    signed_up="$SANDBOX/signed-up.git"
    signed="$SANDBOX/signed"

    if ssh-keygen -q -N '' -t ed25519 -C release-test -f "$signing_key" \
        >/dev/null 2>&1 &&
        git init -q --bare -b main "$signed_up" >/dev/null 2>&1 &&
        (
            set -e
            git clone -q "$signed_up" "$signed"
            cd "$signed"
            git config user.name Test
            git config user.email test@example.invalid
            git config commit.gpgsign false
            git config gpg.format ssh
            git config user.signingkey "$signing_key"
            git commit -q --allow-empty -m seed
            git push -q origin main
            git remote rename origin upstream
        ) >/dev/null 2>&1 &&
        git -C "$signed_up" symbolic-ref HEAD refs/heads/main; then

        got=$(env -i HOME="$release_home" PATH="$PATH" bash \
            --rcfile "$release_home/.bashrc" -i -c \
            "cd '$signed' && release --tag v1.0.0; echo \"__rc=\$?\"" 2>&1)

        case "$got" in
            *'pushed signed tag'*__rc=0)
                pass 'release: signs and pushes the tag' ;;
            *'pushed signed tag'*)
                fail 'release: signs and pushes the tag' \
                    'said it pushed but returned non-zero' ;;
            *)  fail 'release: signs and pushes the tag' "$got" ;;
        esac

        if [ -n "$(git -C "$signed" ls-remote --tags "$signed_up" \
            refs/tags/v1.0.0 2>/dev/null)" ]; then
            pass 'release: the tag reaches the remote'
        else
            fail 'release: the tag reaches the remote'
        fi

        if git -C "$signed" cat-file tag v1.0.0 2>/dev/null \
            | grep -q 'BEGIN SSH SIGNATURE'; then
            pass 'release: the tag it pushes is signed and annotated'
        else
            fail 'release: the tag it pushes is signed and annotated' \
                "$(git -C "$signed" cat-file -t v1.0.0 2>&1)"
        fi

        # A tag now on the remote must not be reused, which is the check
        # that would otherwise let a second release overwrite the first.
        got=$(env -i HOME="$release_home" PATH="$PATH" bash \
            --rcfile "$release_home/.bashrc" -i -c \
            "cd '$signed' && release --tag v1.0.0; echo \"__rc=\$?\"" 2>&1)
        case "$got" in
            *'already exists'*__rc=0)
                fail 'release: will not reuse the tag it just pushed' \
                    'printed the refusal but returned 0' ;;
            *'already exists'*)
                pass 'release: will not reuse the tag it just pushed' ;;
            *)  fail 'release: will not reuse the tag it just pushed' "$got" ;;
        esac

        # A push the remote rejects leaves the local tag behind on
        # purpose, with instructions, so the work of signing is not lost.
        printf '#!/bin/sh\nexit 1\n' >"$signed_up/hooks/pre-receive"
        chmod +x "$signed_up/hooks/pre-receive"

        got=$(env -i HOME="$release_home" PATH="$PATH" bash \
            --rcfile "$release_home/.bashrc" -i -c \
            "cd '$signed' && release --tag v1.0.1; echo \"__rc=\$?\"" 2>&1)
        case "$got" in
            *'push failed'*__rc=0)
                fail 'release: a rejected push is reported' \
                    'printed the failure but returned 0' ;;
            *'push failed'*)
                pass 'release: a rejected push is reported' ;;
            *)  fail 'release: a rejected push is reported' "$got" ;;
        esac

        if git -C "$signed" rev-parse -q --verify refs/tags/v1.0.1 >/dev/null; then
            pass 'release: a rejected push keeps the local tag'
        else
            fail 'release: a rejected push keeps the local tag'
        fi

        # The advice has to work for every tag --tag can reach, including
        # one beginning with a dash, which quoting alone would still let
        # git read as options.
        case "$got" in
            *'git tag -d -- '*)
                pass 'release: the cleanup advice ends git option parsing' ;;
            *)  fail 'release: the cleanup advice ends git option parsing' \
                    "$got" ;;
        esac

        rm -f "$signed_up/hooks/pre-receive"
    else
        skip 'release: signs and pushes the tag' \
            'this git or ssh-keygen will not build the signing fixture'
    fi
else
    skip 'release: signs and pushes the tag' \
        'git, bash or ssh-keygen not installed'
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
