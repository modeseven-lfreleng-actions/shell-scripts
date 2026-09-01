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

# A literal newline. Command substitution strips them, so this is the
# portable way to hold one for the checks below.
newline='
'

PROG=$(basename -- "$0")

# Absolute path to this clone, independent of the caller's directory.
REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

TARGETS=''
STRAYS=''
BLOCK=''
cleanup() {
    [ -n "$TARGETS" ] && rm -f "$TARGETS"
    [ -n "$STRAYS" ] && rm -f "$STRAYS"
    [ -n "$BLOCK" ] && rm -f "$BLOCK"
    return 0
}

# A signal handler that merely tidied up would let the script carry on
# where it left off: Ctrl-C at the prompt would return through the
# 'read' below and install with the default answer, which is the
# opposite of what the person pressing it asked for. Clean up and leave,
# reporting the signal in the exit status as a shell does.
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

fork_path=''
fork_path_set=0
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
            fork_path_set=1
            shift 2
            ;;
        --fork-path=*)
            fork_path=${1#*=}
            fork_path_set=1
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

# Escape the characters that a double-quoted shell assignment would
# otherwise act on, so that a directory holding a literal '$', backtick,
# quote or backslash survives into the start-up file as itself rather
# than as something for the shell to expand -- or run.
escape_literal() {
    printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g'
}

# Re-introduce $HOME as a variable reference, so the block stays valid in
# a start-up file shared between machines with different home directories.
# That reference is the one dollar sign left unescaped. The result is
# meant for use inside double quotes.
portable_path() {
    # shellcheck disable=SC2016  # emitting the text '$HOME', not its value
    case "$1" in
        "$HOME")   printf '%s\n' '$HOME' ;;
        "$HOME"/*) printf '$HOME/%s\n' "$(escape_literal "${1#"$HOME"/}")" ;;
        *)         printf '%s\n' "$(escape_literal "$1")" ;;
    esac
}

# The same, for a value that may be a PATH-style list of directories.
# Encoding the whole string as one pathname would rewrite a leading
# $HOME and leave every later entry spelled out in full, which is worse
# than either extreme: the file then works on one machine and quietly
# searches somebody else's home on the next.
portable_path_list() {
    _ppl_rest=$1
    _ppl_out=''

    while [ -n "$_ppl_rest" ]; do
        case "$_ppl_rest" in
            *:*) _ppl_one=${_ppl_rest%%:*}; _ppl_rest=${_ppl_rest#*:} ;;
            *)   _ppl_one=$_ppl_rest;       _ppl_rest='' ;;
        esac
        [ -n "$_ppl_one" ] || continue

        _ppl_one=$(portable_path "$_ppl_one")
        if [ -z "$_ppl_out" ]; then
            _ppl_out=$_ppl_one
        else
            _ppl_out="$_ppl_out:$_ppl_one"
        fi
    done

    printf '%s\n' "$_ppl_out"
}

# Undo what portable_path_list did, so --status reports the directory
# rather than the shell source that names it. The format is this
# installer's own, so decoding it is a matter of reversing two known
# steps -- no eval, which would hand the contents of somebody's start-up
# file to the shell.
decode_recorded() {
    _dr_rest=$1
    _dr_out=''

    while [ -n "$_dr_rest" ]; do
        case "$_dr_rest" in
            *:*) _dr_one=${_dr_rest%%:*}; _dr_rest=${_dr_rest#*:} ;;
            *)   _dr_one=$_dr_rest;       _dr_rest='' ;;
        esac
        [ -n "$_dr_one" ] || continue

        # The deliberate $HOME reference, which sits unescaped at the
        # start of an entry. A literal dollar there would read '\$'.
        # shellcheck disable=SC2016  # matching the text '$HOME', not its value
        case "$_dr_one" in
            '$HOME')   _dr_one=$HOME ;;
            '$HOME/'*) _dr_one="$HOME/${_dr_one#'$HOME/'}" ;;
        esac

        # Then escape_literal's backslashes, which only ever precede one
        # of \ " $ or a backtick.
        _dr_one=$(printf '%s' "$_dr_one" | sed -e 's/\\\(.\)/\1/g')

        if [ -z "$_dr_out" ]; then
            _dr_out=$_dr_one
        else
            _dr_out="$_dr_out:$_dr_one"
        fi
    done

    printf '%s\n' "$_dr_out"
}

# Run a command for each entry of a PATH-style list, in order.
for_each_root() {
    _fer_cmd=$1
    _fer_rest=$2

    while [ -n "$_fer_rest" ]; do
        case "$_fer_rest" in
            *:*) _fer_one=${_fer_rest%%:*}; _fer_rest=${_fer_rest#*:} ;;
            *)   _fer_one=$_fer_rest;       _fer_rest='' ;;
        esac
        [ -n "$_fer_one" ] || continue
        "$_fer_cmd" "$_fer_one"
    done
}

# Which start-up files to manage, one per line. A shell that is not
# installed is not worth writing a file for; one that is gets the files
# it reads, created when none exists.
#
# bash is the awkward one. It reads ~/.bashrc for interactive non-login
# shells, and, for login shells -- which is what macOS Terminal starts --
# the first of ~/.bash_profile, ~/.bash_login and ~/.profile that exists,
# and no other. Whether any of them reaches ~/.bashrc cannot be settled
# by reading them: a '. ~/.bashrc' can sit in a function nobody calls.
# So manage every one that exists and accept the redundancy -- sourcing
# loader.sh twice re-defines the same functions -- and create
# ~/.bash_profile when none of the three does, since otherwise a login
# shell would read nothing this installer had touched.
profile_targets() {
    if command -v zsh >/dev/null 2>&1 || [ -f "${ZDOTDIR:-$HOME}/.zshrc" ]; then
        printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
    fi

    if command -v bash >/dev/null 2>&1 || [ -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$HOME/.bashrc"

        _pt_login=0
        for _pt_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [ -f "$_pt_file" ]; then
                printf '%s\n' "$_pt_file"
                _pt_login=1
            fi
        done

        if [ "$_pt_login" -eq 0 ]; then
            printf '%s\n' "$HOME/.bash_profile"
        fi
    fi
}

# Every file a block could ever have been written to, whether or not this
# run would choose it. Removal has to be as exhaustive as it can be: an
# earlier version of this installer chose its targets by different rules,
# and a block it left behind still runs.
#
# $ZDOTDIR moves zsh's files out of $HOME entirely, and its value can
# differ between the install and the uninstall. Cover both places. The
# one case that cannot be covered is a $ZDOTDIR set then and unset now:
# nothing here records where it pointed, so --uninstall says how to
# reach that block when it finds none.
candidate_files() {
    printf '%s\n' \
        "$HOME/.zshrc" \
        "$HOME/.zprofile" \
        "$HOME/.bashrc" \
        "$HOME/.bash_profile" \
        "$HOME/.bash_login" \
        "$HOME/.profile"

    if [ -n "${ZDOTDIR:-}" ] && [ "$ZDOTDIR" != "$HOME" ]; then
        printf '%s\n' "$ZDOTDIR/.zshrc" "$ZDOTDIR/.zprofile"
    fi
}

has_block() {
    [ -f "$1" ] || return 1
    grep -qxF "$BEGIN_MARK" "$1" 2>/dev/null
}

# Validate every file in the list at $1 before any of them is written.
# Checking each one as it is reached would see a bad file abort the run
# partway through, leaving some shells with the block and others without
# -- a state nobody asked for and nothing here reports.
#
# $2 selects which files need to be writable: 'all' for an install, which
# touches every target, or 'blocks' for an uninstall, which only rewrites
# the files that carry one.
preflight() {
    _pf_mode=$2

    while IFS= read -r _pf_file; do
        check_markers "$_pf_file"

        if [ "$_pf_mode" = all ] || has_block "$_pf_file"; then
            check_writable "$_pf_file"
        fi
    done <"$1"
}

# Refuse a target that cannot be rewritten in place, or whose directory
# will not hold the backup taken first. Marker checking alone would let
# an unwritable file, or a name that turns out to be a directory, fail
# halfway through the run.
check_writable() {
    _cw_file=$1

    if [ -e "$_cw_file" ] || [ -L "$_cw_file" ]; then
        if [ -d "$_cw_file" ]; then
            die "$_cw_file is a directory, not a start-up file"
        fi
        if [ ! -f "$_cw_file" ]; then
            die "$_cw_file is not a regular file (a dangling symlink, perhaps)"
        fi
        if [ ! -w "$_cw_file" ]; then
            die "$_cw_file is not writable"
        fi
    fi

    _cw_dir=$(dirname -- "$_cw_file")
    if [ ! -d "$_cw_dir" ]; then
        die "$_cw_dir does not exist"
    fi
    if [ ! -w "$_cw_dir" ]; then
        # Needed to create the file, and to put the backup beside it.
        die "$_cw_dir is not writable"
    fi
}

# Refuse to touch a file whose markers do not form one properly ordered
# pair. Counting them is not enough: a closing marker standing before an
# opening one balances, and strip_block would then keep the text above it
# and drop everything below -- which is somebody's start-up file gone.
check_markers() {
    _cm_file=$1
    [ -f "$_cm_file" ] || return 0

    _cm_state=$(awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        BEGIN            { state = "ok" }
        state != "ok"    { next }
        $0 == begin      { if (open || seen) state = "repeated"
                           else { open = 1; seen = 1 }
                           next }
        $0 == end        { if (!open) state = "unopened"
                           else open = 0
                           next }
        END              { if (state == "ok" && open) state = "unclosed"
                           print state }
    ' "$_cm_file")

    case "$_cm_state" in
        ok)       return 0 ;;
        repeated) _cm_why='holds more than one managed block' ;;
        unopened) _cm_why='holds a closing marker before its opening one' ;;
        unclosed) _cm_why='holds an opening marker with no closing one' ;;
        *)        _cm_why='holds markers this installer cannot make sense of' ;;
    esac

    die "$_cm_file $_cm_why; repair it by hand"
}

# Copy stdin to stdout with the managed block, and any blank lines that
# trail the file, removed. Used by --uninstall.
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

# Write $1 with the managed block replaced in place by the contents of
# $2, or appended when $1 carries no block. In place matters: anything a
# person wrote after the block runs after it today, and moving the block
# to the end would silently reorder their start-up file -- putting their
# commands ahead of the variables and functions this block defines.
replace_block() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v blockfile="$2" '
        function flush() { printf "%s", pending; pending = "" }
        function emit(   line) {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
        }
        $0 == begin { flush(); emit(); replaced = 1; inside = 1; next }
        $0 == end   { inside = 0; next }
        inside      { next }
        # Hold blank lines back, so the ones that merely trail the file
        # can be dropped before an appended block and kept after a
        # replaced one.
        /^[[:space:]]*$/ { pending = pending $0 "\n"; next }
        { flush(); print; body = 1 }
        END {
            if (replaced) { flush() }
            else {
                if (body) print ""
                emit()
            }
        }
    ' "$1"
}

emit_block() {
    cat <<EOF
$BEGIN_MARK
# Managed by shell-scripts/install.sh -- re-running the installer rewrites
# this block, and 'install.sh --uninstall' removes it. Edit
# LFRELENG_ACTIONS_FORK_PATH below if your clones move; setting it earlier
# in this file, or in the environment, wins over the value here. It may
# be a PATH-style colon-separated list. LFRELENG_SHELL_SCRIPTS is the
# clone this block was written from; re-run install.sh if it moves.
if [ -z "\${LFRELENG_ACTIONS_FORK_PATH:-}" ]; then
    LFRELENG_ACTIONS_FORK_PATH="$1"
fi
export LFRELENG_ACTIONS_FORK_PATH
LFRELENG_SHELL_SCRIPTS="$2"
export LFRELENG_SHELL_SCRIPTS
# The tools are bash and zsh only, and a login ~/.profile is read by
# other shells too, so check which shell is asking before loading them.
if [ -n "\${BASH_VERSION:-}\${ZSH_VERSION:-}" ] &&
    [ -r "\$LFRELENG_SHELL_SCRIPTS/loader.sh" ]; then
    . "\$LFRELENG_SHELL_SCRIPTS/loader.sh"
fi
$END_MARK
EOF
}

# The value the block records for the clone directory, read back out of
# the first managed block found. Reported by --status, where the variable
# this process inherited says only what the shell that launched it knew,
# which right after an install is the previous answer or none at all.
recorded_fork_path() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { inside = 1; next }
        $0 == end   { inside = 0; next }
        inside && $0 ~ /^[[:space:]]*LFRELENG_ACTIONS_FORK_PATH="/ {
            line = $0
            sub(/^[[:space:]]*LFRELENG_ACTIONS_FORK_PATH="/, "", line)
            sub(/"[[:space:]]*$/, "", line)
            print line
            exit
        }
    ' "$1" 2>/dev/null
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
        # Replace the backup entry rather than writing through it: a
        # symlink sitting at that name, planted or left behind, would
        # otherwise see 'cp' follow it and overwrite whatever it points
        # at, while leaving no backup at all.
        rm -f "$_ic_file$BACKUP_SUFFIX"
        cp -p "$_ic_file" "$_ic_file$BACKUP_SUFFIX"
    else
        # Bring a new file into being under a private umask before
        # writing to it. A permissive umask in the caller's environment
        # would otherwise leave shell configuration group- or
        # world-writable, which is an invitation to have commands run at
        # somebody else's next login. An existing file keeps whatever
        # permissions it already had.
        ( umask 077; : >"$_ic_file" )
    fi

    cat "$_ic_new" >"$_ic_file"
    report "${_ic_verb}d" "$_ic_file"
}

# Collect the targets into a file, so the loops below can read them
# without a pipeline: a pipeline puts the loop in a subshell, where the
# counters it keeps would not survive.
#
# That file is newline-delimited, so a newline in either variable the
# paths are built from would split one file name into two and send this
# script rummaging through files nobody named. Both are checked before a
# single path is emitted -- as is HOME being a usable directory at all,
# since every target hangs off it and this script rewrites executable
# configuration.
case "${HOME:-}" in
    '') die 'HOME is unset or empty; cannot tell which files to manage' ;;
    /*) ;;
    *)  die "HOME is not an absolute path ('$HOME')" ;;
esac
case "$HOME" in
    *"$newline"*) die 'HOME contains a newline; cannot tell which files to manage' ;;
esac
case "${ZDOTDIR:-}" in
    '') ;;
    /*) ;;
    *)  die "ZDOTDIR is not an absolute path ('$ZDOTDIR')" ;;
esac
case "${ZDOTDIR:-}" in
    *"$newline"*) die 'ZDOTDIR contains a newline; cannot tell which files to manage' ;;
esac

TARGETS=$(mktemp "${TMPDIR:-/tmp}/lfreleng-targets.XXXXXX")
profile_targets >"$TARGETS"

# --- status ----------------------------------------------------------------

if [ "$action" = status ]; then
    say "clone:      $REPO_DIR"
    say "start-up files:"

    seen=0
    recorded=''
    while IFS= read -r file; do
        seen=1
        if has_block "$file"; then
            report installed "$file"
            [ -n "$recorded" ] || recorded=$(recorded_fork_path "$file")
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
    # shell landscape changed since install time -- still runs, so name
    # it rather than letting it sit there unaccounted for, and let it
    # answer for the recorded directory when no current target did.
    STRAYS=$(mktemp "${TMPDIR:-/tmp}/lfreleng-strays.XXXXXX")
    candidate_files >"$STRAYS"
    while IFS= read -r file; do
        if has_block "$file" && ! grep -qxF "$file" "$TARGETS"; then
            report stray "$file"
            [ -n "$recorded" ] || recorded=$(recorded_fork_path "$file")
        fi
    done <"$STRAYS"
    rm -f "$STRAYS"

    say "fork path:"
    if [ -n "$recorded" ]; then
        report recorded "$(decode_recorded "$recorded")"
    else
        report recorded '(no managed block found)'
    fi
    report "this shell" "${LFRELENG_ACTIONS_FORK_PATH:-(not set here)}"
    exit 0
fi

# --- uninstall -------------------------------------------------------------

if [ "$action" = uninstall ]; then
    say "Removing the managed block from:"

    # Every candidate, not just this run's targets: see candidate_files.
    candidate_files >"$TARGETS"
    preflight "$TARGETS" blocks

    removed=0
    while IFS= read -r file; do
        has_block "$file" || continue
        removed=1

        if [ "$dry_run" -eq 1 ]; then
            report "would clean" "$file"
            continue
        fi

        tmp=$(mktemp "${TMPDIR:-/tmp}/lfreleng-install.XXXXXX")
        strip_block <"$file" >"$tmp"
        # See install_content: never write through a symlink left at the
        # backup's name.
        rm -f "$file$BACKUP_SUFFIX"
        cp -p "$file" "$file$BACKUP_SUFFIX"
        cat "$tmp" >"$file"
        rm -f "$tmp"
        report cleaned "$file"
    done <"$TARGETS"

    if [ "$removed" -eq 0 ]; then
        say "  (nothing to remove)"
        if [ -z "${ZDOTDIR:-}" ]; then
            say ""
            say "If you installed with ZDOTDIR set, zsh's file lives elsewhere."
            say "Re-run with the same value to reach it:"
            say "  ZDOTDIR=/your/zsh/dir $PROG --uninstall"
        fi
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

# The block is line-oriented, and this path goes into it as surely as the
# clone directory does. A newline in it would split the assignment and,
# worse, could plant a line that reads as one of the markers, after which
# nothing here could parse the block again.
case "$REPO_DIR" in
    *"$newline"*) die "the path to this clone contains a newline: $REPO_DIR" ;;
esac

# The clone root. Its default is the directory this clone sits in, which
# is almost always the answer: people keep their clones side by side.
#
# An inherited value is passed through as it stands. Expanding a tilde
# here would reach only the first entry of a PATH-style list, leaving
# '~/one:~/two' half-absolute and the second entry to be rejected as
# relative; normalise_root expands each entry on its own below.
default_root=$(dirname -- "$REPO_DIR")
if [ -n "${LFRELENG_ACTIONS_FORK_PATH:-}" ]; then
    default_root=$LFRELENG_ACTIONS_FORK_PATH
fi

# Only fall back to the default when --fork-path was absent altogether.
# Testing the value instead would see an explicit empty one -- which is
# a mistake worth reporting -- quietly install the default.
if [ "$fork_path_set" -eq 0 ]; then
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

# The answer may name several directories, PATH-style, because that is
# what LFRELENG_ACTIONS_FORK_PATH accepts. Normalise and check each
# entry on its own, then rebuild the list.
normalise_root() {
    _nr_one=$(expand_tilde "$1")
    # Trim a trailing slash, but not the one that is the whole of the
    # path: '/' is a valid, if eccentric, place to keep clones.
    [ "$_nr_one" = / ] || _nr_one=${_nr_one%/}
    [ -n "$_nr_one" ] || die 'the clone directory cannot be empty'

    case "$_nr_one" in
        /*) ;;
        *)  die "'$_nr_one' is not an absolute path" ;;
    esac

    if [ ! -d "$_nr_one" ]; then
        warn "$PROG: warning: '$_nr_one' does not exist yet;"
        warn "$PROG: warning: 'release <repo>' finds no clones there"
    fi

    if [ -z "$normalised" ]; then
        normalised=$_nr_one
    else
        normalised="$normalised:$_nr_one"
    fi
}

# A newline anywhere in the answer would split the assignment across two
# lines and leave the second half of it as a command for the shell to
# run. Nothing escapes that, so refuse it outright.
case "$fork_path" in
    *"$newline"*) die 'the clone directory cannot contain a newline' ;;
esac

[ -n "$fork_path" ] || die 'the clone directory cannot be empty'
normalised=''
for_each_root normalise_root "$fork_path"
[ -n "$normalised" ] || die 'the clone directory cannot be empty'
fork_path=$normalised

# The clone this block loads from, always as an absolute path.
# Expressing it in terms of $LFRELENG_ACTIONS_FORK_PATH would look
# tidier, but that variable is deliberately overridable and may hold a
# PATH-style list of roots, at which point the derived path names
# nothing and no tools load.
scripts_ref=$(portable_path "$REPO_DIR")
root_ref=$(portable_path_list "$fork_path")

say "clone:      $REPO_DIR"
say "fork path:  $fork_path"
say "start-up files:"

touched=0
BLOCK=$(mktemp "${TMPDIR:-/tmp}/lfreleng-block.XXXXXX")
emit_block "$root_ref" "$scripts_ref" >"$BLOCK"
preflight "$TARGETS" all

while IFS= read -r file; do
    touched=1

    tmp=$(mktemp "${TMPDIR:-/tmp}/lfreleng-install.XXXXXX")
    if [ -f "$file" ]; then
        replace_block "$file" "$BLOCK" >"$tmp"
    else
        cat "$BLOCK" >"$tmp"
    fi

    install_content "$file" "$tmp"
    rm -f "$tmp"
done <"$TARGETS"

rm -f "$BLOCK"
BLOCK=''

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
