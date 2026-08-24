#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# ---------------------------------------------------------------------------
# install.sh -- plumb this repository into bash and zsh
#
# Writes one small, clearly marked block into the caller's shell start-up
# files. The block sets two variables and sources loader.sh, which in turn
# sources every tool under tools/. Nothing is copied anywhere: the shell
# reads the tools straight out of this clone, so 'git pull' is the whole of
# an update.
#
# Re-running is safe. An existing block is replaced in place, never
# appended to, so the tenth run leaves the same file as the first.
#
#   ./install.sh                      install, prompting for the clone root
#   ./install.sh --fork-path DIR      install without prompting
#   ./install.sh --yes                install, accepting the offered default
#   ./install.sh --status             report where the block is installed
#   ./install.sh --uninstall          remove every block this wrote
#   ./install.sh --dry-run            print what would change, change nothing
#
# Written in POSIX shell, and run with /bin/sh, because it has to work
# before anything it installs exists -- including on a macOS whose
# /bin/bash is still 3.2.
# ---------------------------------------------------------------------------

set -eu

BEGIN_MARK='# >>> lfreleng-actions/shell-scripts >>>'
END_MARK='# <<< lfreleng-actions/shell-scripts <<<'
BACKUP_SUFFIX='.lfreleng.bak'

PROG=$(basename -- "$0")

# Absolute path to this clone, independent of the caller's directory.
REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

TARGETS=''
cleanup() {
    [ -n "$TARGETS" ] && rm -f "$TARGETS"
    return 0
}
trap cleanup EXIT HUP INT TERM

fork_path=''
assume_yes=0
dry_run=0
action=install

# Report one file's fate in a fixed-width column, so a run's output lines
# up whatever mix of verbs it produces.
report() {
    printf '  %-11s %s\n' "$1" "$2"
}

say() {
    printf '%s\n' "$*"
}

warn() {
    printf '%s\n' "$*" >&2
}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $PROG [options]

Plumb the lfreleng-actions shell tools into bash and zsh.

Options:
  -p, --fork-path DIR  directory holding your clones of the
                       lfreleng-actions repositories; skips the prompt
  -y, --yes            accept the offered default instead of prompting
  -n, --dry-run        report what would change, change nothing
  -s, --status         report where the block is currently installed
  -u, --uninstall      remove every block this installer wrote
  -h, --help           show this message
EOF
}

# --- argument parsing ------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--fork-path)
            [ $# -ge 2 ] || die "$1 needs a directory"
            fork_path=$2
            shift 2
            ;;
        --fork-path=*)
            fork_path=${1#*=}
            shift
            ;;
        -y|--yes)       assume_yes=1;     shift ;;
        -n|--dry-run)   dry_run=1;        shift ;;
        -s|--status)    action=status;    shift ;;
        -u|--uninstall) action=uninstall; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unexpected argument '$1'" ;;
    esac
done

# --- helpers ---------------------------------------------------------------
#
# POSIX shell has no 'local', so every helper prefixes its variables with
# an underscore to keep them clear of the loop variables at the bottom.

# Turn a leading tilde into $HOME. A tilde only expands unquoted, so
# anything arriving from a prompt or a quoted --fork-path holds it
# literally, and a literal tilde names a directory nobody has.
expand_tilde() {
    # shellcheck disable=SC2088  # matching a literal tilde is the point
    case "$1" in
        '~')   printf '%s\n' "$HOME" ;;
        '~/'*) printf '%s\n' "$HOME/${1#'~/'}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# Re-introduce $HOME as a variable reference, so the block stays valid in
# a start-up file shared between machines with different home directories.
# The result is meant for use inside double quotes.
portable_path() {
    # shellcheck disable=SC2016  # emitting the text '$HOME', not its value
    case "$1" in
        "$HOME")   printf '%s\n' '$HOME' ;;
        "$HOME"/*) printf '%s\n' "\$HOME/${1#"$HOME"/}" ;;
        *)         printf '%s\n' "$1" ;;
    esac
}

# Which start-up files to manage, one per line. A shell that is not
# installed is not worth writing a file for; one that is gets its
# interactive rc file, created when absent.
#
# bash reads ~/.bashrc for interactive non-login shells and ~/.bash_profile
# for login shells. On macOS, Terminal starts login shells, so a
# ~/.bash_profile that does not pull in ~/.bashrc would never see the
# block. Manage that file too when it exists and stands alone.
profile_targets() {
    if command -v zsh >/dev/null 2>&1 || [ -f "${ZDOTDIR:-$HOME}/.zshrc" ]; then
        printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
    fi

    if command -v bash >/dev/null 2>&1 || [ -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$HOME/.bashrc"

        if [ -f "$HOME/.bash_profile" ] &&
            ! grep -q '\.bashrc' "$HOME/.bash_profile" 2>/dev/null; then
            printf '%s\n' "$HOME/.bash_profile"
        fi
    fi
}

# Every file a block could ever have been written to, whether or not this
# run would choose it. Removal has to be exhaustive: a ~/.bash_profile
# that gained a line sourcing ~/.bashrc since install time drops out of
# profile_targets, and its block would otherwise be orphaned there.
candidate_files() {
    printf '%s\n' \
        "${ZDOTDIR:-$HOME}/.zshrc" \
        "${ZDOTDIR:-$HOME}/.zprofile" \
        "$HOME/.bashrc" \
        "$HOME/.bash_profile" \
        "$HOME/.bash_login" \
        "$HOME/.profile"
}

has_block() {
    [ -f "$1" ] || return 1
    grep -qxF "$BEGIN_MARK" "$1" 2>/dev/null
}

# Refuse to touch a file whose markers do not pair up: a hand-edit that
# deleted one of them would otherwise see this script swallow, or
# duplicate, a chunk of somebody's start-up file.
check_markers() {
    _cm_file=$1
    [ -f "$_cm_file" ] || return 0

    _cm_open=$(grep -cxF "$BEGIN_MARK" "$_cm_file" 2>/dev/null || true)
    _cm_close=$(grep -cxF "$END_MARK" "$_cm_file" 2>/dev/null || true)

    if [ "$_cm_open" != "$_cm_close" ] || [ "$_cm_open" -gt 1 ]; then
        die "$_cm_file holds $_cm_open opening and $_cm_close closing markers; repair it by hand"
    fi
}

# Copy stdin to stdout with the managed block, and any blank lines that
# trail the file, removed.
strip_block() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { inside = 1; next }
        $0 == end   { inside = 0; next }
        inside      { next }
        # Hold blank lines back until something follows them, so blank
        # lines inside the file survive and blank lines at its end do not.
        /^[[:space:]]*$/ { pending = pending $0 "\n"; next }
        { printf "%s", pending; pending = ""; print }
    '
}

emit_block() {
    cat <<EOF
$BEGIN_MARK
# Managed by shell-scripts/install.sh -- re-running the installer rewrites
# this block, and 'install.sh --uninstall' removes it. Edit
# LFRELENG_ACTIONS_FORK_PATH below if your clones move; setting it earlier
# in this file, or in the environment, wins over the value here.
if [ -z "\${LFRELENG_ACTIONS_FORK_PATH:-}" ]; then
    LFRELENG_ACTIONS_FORK_PATH="$1"
fi
export LFRELENG_ACTIONS_FORK_PATH
LFRELENG_SHELL_SCRIPTS="$2"
export LFRELENG_SHELL_SCRIPTS
if [ -r "\$LFRELENG_SHELL_SCRIPTS/loader.sh" ]; then
    . "\$LFRELENG_SHELL_SCRIPTS/loader.sh"
fi
$END_MARK
EOF
}

# Replace a file's contents without replacing the file: many people keep
# their start-up files as symlinks into a dotfiles repository, and a
# rename would swap the link for a plain file.
install_content() {
    _ic_file=$1
    _ic_new=$2
    _ic_verb=update

    if [ ! -f "$_ic_file" ]; then
        _ic_verb=create
    elif cmp -s "$_ic_new" "$_ic_file"; then
        report unchanged "$_ic_file"
        return 0
    fi

    if [ "$dry_run" -eq 1 ]; then
        report "would $_ic_verb" "$_ic_file"
        return 0
    fi

    if [ -f "$_ic_file" ]; then
        cp -p "$_ic_file" "$_ic_file$BACKUP_SUFFIX"
    fi

    cat "$_ic_new" >"$_ic_file"
    report "${_ic_verb}d" "$_ic_file"
}

# Collect the targets into a file, so the loops below can read them
# without a pipeline: a pipeline puts the loop in a subshell, where the
# counters it keeps would not survive.
TARGETS=$(mktemp "${TMPDIR:-/tmp}/lfreleng-targets.XXXXXX")
profile_targets >"$TARGETS"

# --- status ----------------------------------------------------------------

if [ "$action" = status ]; then
    say "clone:      $REPO_DIR"
    say "fork path:  ${LFRELENG_ACTIONS_FORK_PATH:-(not set in this shell)}"
    say "start-up files:"

    seen=0
    while IFS= read -r file; do
        seen=1
        if has_block "$file"; then
            report installed "$file"
        elif [ -f "$file" ]; then
            report absent "$file"
        else
            report "no file" "$file"
        fi
    done <"$TARGETS"

    if [ "$seen" -eq 0 ]; then
        say "  (found neither bash nor zsh, and no start-up file for either)"
    fi

    # A block left in a file this run would not choose -- because the
    # shell landscape changed since install time -- still runs, so name it
    # rather than letting it sit there unaccounted for.
    candidate_files | while IFS= read -r file; do
        if has_block "$file" && ! grep -qxF "$file" "$TARGETS"; then
            report stray "$file"
        fi
    done
    exit 0
fi

# --- uninstall -------------------------------------------------------------

if [ "$action" = uninstall ]; then
    say "Removing the managed block from:"

    # Every candidate, not just this run's targets: see candidate_files.
    candidate_files >"$TARGETS"

    removed=0
    while IFS= read -r file; do
        has_block "$file" || continue
        check_markers "$file"
        removed=1

        if [ "$dry_run" -eq 1 ]; then
            report "would clean" "$file"
            continue
        fi

        tmp=$(mktemp "${TMPDIR:-/tmp}/lfreleng-install.XXXXXX")
        strip_block <"$file" >"$tmp"
        cp -p "$file" "$file$BACKUP_SUFFIX"
        cat "$tmp" >"$file"
        rm -f "$tmp"
        report cleaned "$file"
    done <"$TARGETS"

    if [ "$removed" -eq 0 ]; then
        say "  (nothing to remove)"
    elif [ "$dry_run" -eq 1 ]; then
        say ""
        say "Dry run: nothing was written."
    else
        say ""
        say "Backups kept alongside each file as *$BACKUP_SUFFIX."
        say "Open a new shell, or run 'exec \$SHELL -l', to drop the tools."
    fi
    exit 0
fi

# --- install ---------------------------------------------------------------

[ -r "$REPO_DIR/loader.sh" ] || die "no loader.sh beside $PROG in $REPO_DIR"

# The clone root. Its default is the directory this clone sits in, which
# is almost always the answer: people keep their clones side by side.
default_root=$(dirname -- "$REPO_DIR")
if [ -n "${LFRELENG_ACTIONS_FORK_PATH:-}" ]; then
    default_root=$(expand_tilde "$LFRELENG_ACTIONS_FORK_PATH")
fi

if [ -z "$fork_path" ]; then
    if [ "$assume_yes" -eq 1 ] || [ ! -t 0 ]; then
        fork_path=$default_root
    else
        cat <<EOF
The 'release' tool can act on a repository by name -- 'release .github',
say -- instead of making you find and cd into its clone first. To do that
it needs to know one thing: the directory you keep those clones in.

That directory is recorded as LFRELENG_ACTIONS_FORK_PATH. Future tools in
this repository will read it too, so it is the only setting to keep track
of. You can change it later by editing the block this installer writes.

EOF
        printf 'Directory holding your clones [%s]: ' "$default_root"
        IFS= read -r reply || reply=''
        fork_path=${reply:-$default_root}
    fi
fi

fork_path=$(expand_tilde "$fork_path")
fork_path=${fork_path%/}
[ -n "$fork_path" ] || die 'the clone directory cannot be empty'

case "$fork_path" in
    /*) ;;
    *)  die "'$fork_path' is not an absolute path" ;;
esac

if [ ! -d "$fork_path" ]; then
    warn "$PROG: warning: '$fork_path' does not exist yet;"
    warn "$PROG: warning: 'release <repo>' finds no clones until it does"
fi

# When this clone lives under the clone root, express it in terms of the
# root, so moving the whole tree stays a one-line edit rather than two.
case "$REPO_DIR" in
    "$fork_path"/*)
        scripts_ref="\$LFRELENG_ACTIONS_FORK_PATH/${REPO_DIR#"$fork_path"/}"
        ;;
    *)
        scripts_ref=$(portable_path "$REPO_DIR")
        ;;
esac
root_ref=$(portable_path "$fork_path")

say "clone:      $REPO_DIR"
say "fork path:  $fork_path"
say "start-up files:"

touched=0
while IFS= read -r file; do
    check_markers "$file"
    touched=1

    tmp=$(mktemp "${TMPDIR:-/tmp}/lfreleng-install.XXXXXX")
    if [ -f "$file" ]; then
        strip_block <"$file" >"$tmp"
        # strip_block drops trailing blank lines, so a file with anything
        # left in it needs exactly one separator before the block.
        if [ -s "$tmp" ]; then
            printf '\n' >>"$tmp"
        fi
    fi
    emit_block "$root_ref" "$scripts_ref" >>"$tmp"

    install_content "$file" "$tmp"
    rm -f "$tmp"
done <"$TARGETS"

if [ "$touched" -eq 0 ]; then
    die 'found neither bash nor zsh, and no start-up file for either'
fi

say ""
if [ "$dry_run" -eq 1 ]; then
    say "Dry run: nothing was written."
else
    say "Done. Open a new shell, or run 'exec \$SHELL -l', to pick up the tools."
    say "Updating later is just 'git pull' in this clone; no re-install needed."
fi
