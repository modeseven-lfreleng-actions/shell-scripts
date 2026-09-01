# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# shellcheck shell=bash
# ---------------------------------------------------------------------------
# loader.sh -- source every tool in this repository into the current shell
#
# Sourced, never executed. install.sh writes a small managed block into the
# caller's shell start-up files that sets LFRELENG_SHELL_SCRIPTS to this
# clone and then sources this file; sourcing it by hand works too:
#
#     . /path/to/shell-scripts/loader.sh
#
# Everything matching tools/*.sh is sourced in name order, so a tool added
# to the repository is picked up by the next shell with no re-install.
# Set LFRELENG_SHELL_SCRIPTS_SKIP to a space-separated list of tool names
# (the file name without its .sh suffix) to leave individual tools out,
# which is the escape hatch when a tool's name collides with something
# already in the caller's environment:
#
#     export LFRELENG_SHELL_SCRIPTS_SKIP="release"
#
# Shell compatibility: POSIX-style syntax plus 'local'; works in zsh and bash.
# ---------------------------------------------------------------------------

_lfreleng_load_tools() {
    local root file name

    # zsh aborts on a glob that matches nothing, where bash leaves the
    # pattern unexpanded for the [ -r ] test below to reject. Ask zsh for
    # the bash behaviour, scoped to this function.
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt local_options null_glob
    fi

    root=$1
    [ -d "$root/tools" ] || return 0

    for file in "$root"/tools/*.sh; do
        [ -r "$file" ] || continue

        name=${file##*/}
        name=${name%.sh}

        # Whole-word match against a padded list, rather than splitting
        # it: zsh does not word-split unquoted parameters the way bash
        # does, and padding sidesteps the difference. Skipping 'release'
        # therefore leaves a future 'release-notes' alone.
        case " ${LFRELENG_SHELL_SCRIPTS_SKIP:-} " in
            *" $name "*) continue ;;
        esac

        # shellcheck disable=SC1090  # path is known only at runtime
        . "$file"
    done
}

# Locate this clone. The managed block sets LFRELENG_SHELL_SCRIPTS, which
# is authoritative; the fallbacks exist so that sourcing this file by hand
# also works. Each shell spells "the file currently being sourced"
# differently, and neither spelling parses in the other, so both sit
# behind a version guard.
if [ -z "${LFRELENG_SHELL_SCRIPTS:-}" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
        # ${(%):-%x} is zsh's name for the file being sourced, and :A:h
        # makes it absolute and takes the directory. Neither spelling is
        # bash, hence the guard above and the suppressions here.
        # shellcheck disable=SC2296,SC2298
        LFRELENG_SHELL_SCRIPTS=${${(%):-%x}:A:h}
        export LFRELENG_SHELL_SCRIPTS
    elif [ -n "${BASH_VERSION:-}" ]; then
        LFRELENG_SHELL_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        export LFRELENG_SHELL_SCRIPTS
    fi
fi

if [ -n "${LFRELENG_SHELL_SCRIPTS:-}" ]; then
    _lfreleng_load_tools "$LFRELENG_SHELL_SCRIPTS"
else
    echo "lfreleng shell-scripts: cannot locate the clone; set" >&2
    echo "lfreleng shell-scripts: LFRELENG_SHELL_SCRIPTS and re-source" >&2
fi

# Leave nothing behind but the tools themselves.
unset -f _lfreleng_load_tools
