# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# shellcheck shell=bash
# ---------------------------------------------------------------------------
# release() -- sync from the source of truth, then push a signed git tag
#
# Sourced into interactive shells by ../loader.sh. The README documents
# every calling form, the environment variables below and the reasoning
# behind each refusal; this header is the short version.
#
#   release v0.1.2                 tag + push to the resolved remote
#   release v0.1.2 origin          tag + push to a named remote
#   release latest                 tag the version held by the draft
#   release latest origin          the same, against a named remote
#   release .github latest         as above, in that clone
#   release .github latest origin  as above, named remote
#   release .github                as above, from outside any clone
#   release --tag <tag> [remote]   tag a literal name, whatever it holds
#
# '--tag' is the way out of the two ambiguities the other forms have to
# guess at: a word holding a slash reads as a path to a clone, because
# 'release other/repo' should not put a tag named after somebody else's
# repository on the one under foot -- so a legitimate tag such as
# 'release/1.2' needs saying outright. A tag literally named 'latest'
# needs the same.
#
# Environment (all optional):
#   LFRELENG_ACTIONS_FORK_PATH  directory holding the caller's clones; the
#                               repository forms search it for a clone of
#                               the named repository. install.sh sets it
#   RELEASE_REPO_ROOT           overrides the above for this function
#                               alone. Either may be a PATH-style
#                               colon-separated list, searched in order,
#                               first match winning
#   RELEASE_NO_SYNC             set to a non-empty value to tag HEAD
#                               exactly as it stands, skipping the sync.
#                               For tagging a commit deliberately held
#                               back from the default branch; it removes
#                               the only guard against tagging stale
#                               history, so an empty value leaves the
#                               sync on rather than off
#   RELEASE_DRAFTER_WORKFLOW    workflow file to wait on (default
#                               release-drafter.yaml, falling back to
#                               release-drafter.yml when unset)
#   RELEASE_DRAFTER_TIMEOUT     seconds to wait before giving up (600)
#   RELEASE_DRAFTER_POLL        seconds between checks (10)
#   RELEASE_GH_HOST             host name to pass to 'gh', when the
#                               remote's authority is not one -- a
#                               GitHub Enterprise instance reached on a
#                               non-default port, say
#
# Naming a tag explicitly calls nothing but 'git'; the 'latest' forms
# additionally need the GitHub CLI ('gh'), authenticated for the remote's
# host, because draft releases are invisible to anonymous callers. Tagging
# runs 'git tag -s', so the caller needs a working signing setup.
#
# Shell compatibility: POSIX-style syntax plus 'local'; works in zsh and bash.
# ---------------------------------------------------------------------------

# Hide any credentials embedded in a remote URL before it reaches a
# terminal or a CI log. 'https://token@host/owner/repo' is a real and
# common shape, and the places that print a URL here are precisely the
# places where something has gone wrong and the output gets pasted into
# an issue.
#
# The match is deliberately unanchored: git's own diagnostics carry the
# URL mid-line ('fatal: unable to access '\''https://...'\''...'), and
# this filter is fed whole captured error streams as well as bare URLs.
# Only URLs carrying a scheme are touched: the 'git@' of an scp-style
# address is a user name, not a secret, and blanking it would make the
# message harder to read for no gain.
_release_redact() {
    sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]@]*@#\1***@#g'
}

_release_redact_url() {
    printf '%s\n' "$1" | _release_redact
}

# Quote a value for a command line this function prints for the caller to
# copy. Remote, branch and tag names are freer than they look, and a name
# holding a semicolon would turn recovery advice into two commands. Left
# alone when it needs nothing, so the usual case stays readable.
_release_quote() {
    case "$1" in
        ''|*[!A-Za-z0-9._/@+-]*)
            printf "'%s'\n" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Whether the current directory sits in a working tree that has
# something to tag. A bare repository answers 'false' here and exits 0,
# so the exit status alone would let one through.
_release_in_worktree() {
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]
}

# Run a command, keeping its two output streams apart, and return its own
# exit status. Sets _release_out to stdout and _release_err to stderr.
#
# '$(cmd 2>&1)' is the tempting shorthand, and wrong for every query here
# that gets parsed: a successful call that also emits a transport warning
# -- a redirect notice, a deprecation, a proxy grumble -- would hand the
# caller a warning line where it expected a SHA, and the comparison that
# follows would report a branch as moved and refuse a good release.
_release_capture() {
    _release_err_file=$(mktemp "${TMPDIR:-/tmp}/release-capture.XXXXXX") || {
        _release_out=''
        _release_err='release: cannot create a temporary file'
        return 1
    }

    _release_out=''
    _release_err=''

    # The assignment sits in a condition, so that a failing command does
    # not end a caller's shell that runs with 'set -e' before its status
    # has been captured -- which is the whole point of this helper.
    if _release_out=$("$@" 2>"$_release_err_file"); then
        _release_capture_rc=0
    else
        _release_capture_rc=$?
    fi

    _release_err=$(cat "$_release_err_file" 2>/dev/null) || _release_err=''
    rm -f "$_release_err_file"

    return "$_release_capture_rc"
}

release() {
    # Sync the checkout with its source of truth, then create a signed,
    # annotated tag and push it to that same source of truth (`upstream`
    # if configured, otherwise `origin`).
    #
    #   release v0.0.2                  tag + push to the resolved remote
    #   release v0.0.2 origin           tag + push to a named remote
    #   release latest                  tag the current draft's version
    #   release latest origin           the same, against a named remote
    #   release <repo> latest [remote]  the same, in a clone found under
    #                                   $LFRELENG_ACTIONS_FORK_PATH
    #   release <repo> [remote]         the same, when the current
    #                                   directory is not inside a
    #                                   repository: 'latest' is assumed
    #   release --tag <tag> [remote]    tag exactly that name, whether it
    #                                   holds a slash or reads as a
    #                                   keyword
    #
    # Refuses to:
    #   - run outside a git repository
    #   - tag a digitless word that names a clone, which is the repository
    #     form typed from inside some other repository
    #   - sync, or switch branches, over uncommitted work
    #   - discard local commits to sync
    #   - reuse a tag that already exists locally or on the remote
    #   - push when signing the tag fails
    #   - guess when 'latest' matches zero or several draft releases
    #   - push while release-drafter is still updating the draft
    #   - act on a named repository it cannot find a clone of

    # 0. Repository form: 'release <repo> [latest] [remote]'. Everything
    #    below works on the current directory, so rather than teach each
    #    step about a path, cd into the clone inside a SUBSHELL and
    #    re-enter. The subshell is the point: the caller's directory, and
    #    any shell state the cd would disturb, survive untouched. The
    #    recursion is bounded, because the inner call is always given
    #    'latest' first and a remote, never a repository, second.
    #
    #    Three ways in, distinguished by $want_repo:
    #
    #      form     'latest' sits in second position, naming the first
    #               word as a repository.
    #      implied  the current directory is not inside a repository at
    #               all, so the first word cannot be a version to tag and
    #               there is nothing to tag it against. A repository name
    #               is the only reading left, and promoting its draft the
    #               only thing 'release' could be being asked to do.
    #      check    a bare word inside a repository is a version to tag,
    #               which is also how a mistyped repository form arrives:
    #               'release gha-workflow-linter' from inside some other
    #               clone would sign and push a tag named after a
    #               repository. No version lacks a digit, so a digitless
    #               word that ALSO names a clone is a mistake worth
    #               stopping; a digitless word that names nothing (say
    #               'nightly') is left alone and tagged as asked.

    # Take copies of the arguments first. Every form here has optional
    # trailing words, and this function runs in the caller's shell, where
    # 'set -u' turns a bare $2 into an error rather than an empty string.
    local arg1 arg2 arg3 argc want_repo maxargs force_tag resolve_draft

    # _release_capture assigns these. Declaring them here keeps its
    # dynamically scoped writes inside this function: without it, every
    # call would leave four variables -- one of them a captured error
    # stream -- sitting in the caller's interactive shell.
    local _release_out _release_err _release_err_file _release_capture_rc

    arg1=${1-}
    arg2=${2-}
    arg3=${3-}
    argc=$#
    force_tag=0

    # '--tag' says the next word is a version and nothing else, which is
    # the way out of the two ambiguities this function otherwise has to
    # guess at: a tag holding a slash ('release/1.2' is a legitimate git
    # tag) would read as a path to a clone, and a tag literally named
    # 'latest' would read as the keyword.
    if [ "$arg1" = --tag ]; then
        force_tag=1
        arg1=$arg2
        arg2=$arg3
        arg3=''
        argc=$((argc - 1))
        if [ -z "$arg1" ]; then
            echo "release: --tag needs a version to tag" >&2
            echo "release: usage: release --tag <tag> [remote]" >&2
            return 2
        fi
    fi

    want_repo=''
    if [ "$force_tag" -eq 1 ]; then
        # Named outright; none of the readings below apply.
        :
    elif [ "$arg1" = latest ]; then
        # 'latest' is this function's own keyword, never a repository
        # name -- including in the recursive call the repository forms
        # make. A clone that happens to be called 'latest' must not
        # capture the documented 'release latest' form.
        :
    elif [ "$arg2" = latest ]; then
        want_repo=form
    else
        case "$arg1" in
            '') : ;;
            */*)
                # A slash makes it a path to a clone, whatever else the
                # word holds. No version is spelled with one, and the
                # digit test below would otherwise read 'other/repo2' as
                # a version and put a signed tag named after somebody
                # else's clone on whatever is under foot.
                want_repo=path
                ;;
            *)
                if ! _release_in_worktree; then
                    want_repo=implied
                else
                    case "$arg1" in
                        *[0-9]*) : ;;
                        *)       want_repo=check ;;
                    esac
                fi
                ;;
        esac
    fi

    # Only the repository-plus-'latest' form takes a third word. Silently
    # ignoring a fourth would see 'release v1.2.3 origin typo' sign and
    # push a tag as though the typo had never been typed.
    if [ "$want_repo" = form ]; then
        maxargs=3
    else
        maxargs=2
    fi
    if [ "$argc" -gt "$maxargs" ]; then
        echo "release: too many arguments ($argc)" >&2
        echo "release: usage: release [<repo>] <tag|latest> [remote]" >&2
        echo "release:        release <repo> [remote]  (outside a clone)" >&2
        echo "release:        release --tag <tag> [remote]  (literal tag)" >&2
        return 2
    fi

    if [ -n "$want_repo" ]; then
        local roots rest root name candidate found stray bypath sub_remote

        # Trim the trailing slash that filename completion leaves behind.
        # A word whose only slash is that one is genuinely ambiguous --
        # completing 'repo/' in a directory holding it means './repo',
        # while typing it from habit means the clone called 'repo' --
        # so it is tried as a path first and then under the roots. A
        # slash anywhere else makes it a path and nothing else.
        name=${arg1%/}
        found=''
        stray=''
        bypath=''
        if [ -z "$name" ]; then
            echo "release: usage: release [<repo>] <tag|latest> [remote]" >&2
            echo "release:        release <repo> [remote]  (outside a clone)" >&2
        echo "release:        release --tag <tag> [remote]  (literal tag)" >&2
            return 2
        fi

        # A word whose only slash is that trailing one is genuinely
        # ambiguous -- completing 'repo/' in a directory holding it means
        # './repo', while typing it from habit means the clone called
        # 'repo' -- so try it as a path here, and let the roots search
        # below have it if that finds nothing. A slash anywhere else
        # makes it a path and nothing else.
        case "$name" in
            */*) : ;;
            *)
                if [ "$arg1" != "$name" ] && [ -e "$name/.git" ]; then
                    found="$name"
                fi
                ;;
        esac

        case "$name" in
            */*)
                # Anything holding a slash is already a path; honour it
                # instead of appending it to the roots, which is what a
                # pasted or completed directory arrives as.
                bypath=yes
                if [ -e "$name/.git" ]; then
                    found="$name"
                elif [ -d "$name" ]; then
                    stray="$name"
                fi
                ;;
            *)
                # Where to look for a clone named '$name'.
                # RELEASE_REPO_ROOT overrides for this function alone;
                # otherwise the one variable install.sh writes into the
                # caller's shell start-up file. Either may be a
                # PATH-style list. Neither has a built-in default: a
                # guess at somebody else's directory layout would either
                # miss, or -- worse -- find a same-named clone that is
                # not the one meant.
                roots=${RELEASE_REPO_ROOT:-${LFRELENG_ACTIONS_FORK_PATH:-}}
                rest="$roots"

                # Split the PATH-style list with parameter expansion rather
                # than word splitting: zsh does not split unquoted
                # parameters the way bash does, and this has to behave the
                # same in both.
                while [ -z "$found" ] && [ -n "$rest" ]; do
                    case "$rest" in
                        *:*) root=${rest%%:*}; rest=${rest#*:} ;;
                        *)   root="$rest";     rest='' ;;
                    esac
                    [ -z "$root" ] && continue

                    # A tilde written inside quotes is a literal
                    # character, not the home directory, and
                    # export VAR="~/somewhere" is the usual way that
                    # mistake reaches this loop. Expand it here rather
                    # than reporting a directory that plainly exists as
                    # missing.
                    # shellcheck disable=SC2088  # matching a literal tilde is the point
                    case "$root" in
                        '~')   root="$HOME" ;;
                        '~/'*) root="$HOME/${root#'~/'}" ;;
                    esac

                    candidate="${root%/}/$name"
                    if [ -e "$candidate/.git" ]; then
                        found="$candidate"
                        break
                    fi
                    if [ -z "$stray" ] && [ -d "$candidate" ]; then
                        stray="$candidate"
                    fi
                done
                ;;
        esac

        if [ -z "$found" ]; then
            if [ "$want_repo" = check ]; then
                # A digitless bare word that names no clone: an unusual
                # tag, but the caller's to make. Fall through and tag it.
                # Only a bare word, though -- anything path-shaped that
                # resolves to nothing is a typo, and signing 'other/repo'
                # onto the clone under foot is not a service to anyone.
                :
            else
                if [ -n "$stray" ]; then
                    echo "release: '$stray' is not a git clone" >&2
                elif [ -n "$bypath" ]; then
                    echo "release: no clone at '$name'" >&2
                elif [ -z "$roots" ]; then
                    echo "release: '$name' names no clone, because no search" >&2
                    echo "release: root is configured. Set the directory that" >&2
                    echo "release: holds your clones, e.g." >&2
                    echo "release:   export LFRELENG_ACTIONS_FORK_PATH=\"\$HOME/Repositories\"" >&2
                    echo "release: (install.sh does this for you), or set" >&2
                    echo "release:   export RELEASE_REPO_ROOT=\"\$HOME/Repositories\"" >&2
                    echo "release: to point this tool alone somewhere else" >&2
                else
                    echo "release: no clone of '$name' under:" >&2
                    printf '%s\n' "$roots" | tr ':' '\n' | sed 's/^/release:   /' >&2
                    echo "release: set RELEASE_REPO_ROOT to search elsewhere" >&2
                fi
                if [ "$want_repo" = implied ]; then
                    # Spell out the reading, because the caller may have
                    # typed a version and forgotten to cd first -- or be
                    # standing in a bare repository, which looks like
                    # "not a repository" to the test that chose this
                    # reading and is worth naming outright.
                    echo "release: ('$name' was read as a repository name: the" >&2
                    if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
                        echo "release: current directory is a bare repository, which has" >&2
                        echo "release: no working tree to cut a release from)" >&2
                    else
                        echo "release: current directory is not inside a repository)" >&2
                    fi
                fi
                return 1
            fi
        elif [ "$want_repo" = check ]; then
            # Inside one repository, holding the name of another. Tagging
            # would put a signed tag called '$name' on whatever is under
            # foot, so name both readings and let the caller pick one.
            echo "release: '$name' names a clone at" >&2
            echo "release:   $found" >&2
            echo "release: but the current directory is inside" >&2
            echo "release:   $(git rev-parse --show-toplevel 2>/dev/null)" >&2
            echo "release: refusing to tag '$name' here by accident. Either:" >&2
            echo "release:   release $(_release_quote "$name") latest   releases that clone" >&2
            echo "release:   cd out of this repository and repeat" >&2
            echo "release: or name a version, which always holds a digit" >&2
            return 1
        else
            # 'latest' second means the remote is third; an implied
            # 'latest' leaves the remote second.
            if [ "$arg2" = latest ]; then
                sub_remote="$arg3"
            else
                sub_remote="$arg2"
            fi

            echo "release: working in $found"
            # Clear CDPATH. '$found' can be relative -- a completed
            # 'repo/' resolves to './repo' -- and a CDPATH entry holding
            # a directory of the same name would send this into the
            # wrong clone, which the recursive call would then tag. The
            # subshell keeps the change to itself.
            ( CDPATH=''; cd "$found" >/dev/null && release latest "$sub_remote" )
            return $?
        fi
    fi

    local tag="$arg1"
    local remote="$arg2"

    # Whether to go and ask GitHub for the drafted version. 'latest' is
    # the keyword unless --tag said it was a name.
    if [ "$force_tag" -eq 0 ] && [ "$tag" = latest ]; then
        resolve_draft=1
    else
        resolve_draft=0
    fi

    # 1. Require a tag name.
    if [ -z "$tag" ]; then
        echo "release: usage: release [<repo>] <tag|latest> [remote]" >&2
        echo "release:        release <repo> [remote]  (outside a clone)" >&2
        echo "release:        release --tag <tag> [remote]  (literal tag)" >&2
        return 2
    fi

    # 2. Must be inside a working tree; a tag needs a commit to point at,
    #    and a bare repository has no tree to read one from.
    if ! _release_in_worktree; then
        if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
            echo "release: this is a bare repository; there is no working" >&2
            echo "release: tree here to cut a release from" >&2
        else
            echo "release: not inside a git repository" >&2
        fi
        return 1
    fi

    # 3. Pick the remote to publish to: `upstream` when the clone has one,
    #    otherwise `origin`. An explicit second argument always wins, so a
    #    fork can be tagged deliberately.
    if [ -n "$remote" ]; then
        if ! git remote get-url "$remote" >/dev/null 2>&1; then
            echo "release: no remote named '$remote'" >&2
            return 1
        fi
    elif git remote get-url upstream >/dev/null 2>&1; then
        remote=upstream
    elif git remote get-url origin >/dev/null 2>&1; then
        remote=origin
    else
        echo "release: no 'upstream' or 'origin' remote configured" >&2
        return 1
    fi

    # A remote can fetch from one URL and push to another -- or to
    # several. Everything below reads one destination and writes another:
    # the draft, the default branch and the existing tags come from the
    # fetch URL, while the tag lands wherever push sends it. Publishing a
    # release that does not describe the repository this function
    # inspected is worse than refusing, so require exactly one URL doing
    # both jobs. 'get-url --push' alone would report only the first of
    # several pushurls and miss the multi-destination case entirely.
    local fetch_urls push_urls fetch_count push_count fetch_url
    fetch_urls=$(git remote get-url --all "$remote" 2>/dev/null) || fetch_urls=''
    push_urls=$(git remote get-url --push --all "$remote" 2>/dev/null) || push_urls=''
    fetch_count=$(printf '%s\n' "$fetch_urls" | grep -c '[^[:space:]]' || true)
    push_count=$(printf '%s\n' "$push_urls" | grep -c '[^[:space:]]' || true)

    # Exactly one URL on each side, and the same one. Reading only the
    # first of each would let a remote carrying several 'url' entries
    # through, and testing only for 'more than one' would let zero
    # through -- a query that failed, or a git too old for '--all'. An
    # unanswered question is not a clean answer: the function would sign
    # the tag and discover the problem at the push, leaving behind the
    # local tag this check exists to prevent.
    if [ "$fetch_count" -ne 1 ] || [ "$push_count" -ne 1 ] \
        || [ "$push_urls" != "$fetch_urls" ]; then
        echo "release: remote '$remote' does not fetch and push one URL:" >&2

        if [ "$fetch_count" -eq 0 ]; then
            echo "release:   fetch  (none reported)" >&2
        else
            printf '%s\n' "$fetch_urls" | while IFS= read -r one; do
                [ -n "$one" ] || continue
                echo "release:   fetch  $(_release_redact_url "$one")" >&2
            done
        fi

        if [ "$push_count" -eq 0 ]; then
            echo "release:   push   (none reported)" >&2
        else
            printf '%s\n' "$push_urls" | while IFS= read -r one; do
                [ -n "$one" ] || continue
                echo "release:   push   $(_release_redact_url "$one")" >&2
            done
        fi

        echo "release: a release read from one and pushed to another would" >&2
        echo "release: not describe what it tagged; name a single-URL remote" >&2
        return 1
    fi
    fetch_url=$fetch_urls

    # Credentials in a remote URL are not this tool's business to police,
    # and git anonymises them in its own output -- 'To github.com:o/r'
    # from a 'git@github.com:o/r' remote, and 'unable to access
    # https://host/...' from a tokenful one. Every diagnostic this
    # function re-prints goes through _release_redact as well. Say so
    # anyway: the guarantee rests on git's behaviour rather than on
    # anything here, and a credential helper keeps the secret out of the
    # config file in the first place.
    #
    # 'git' as the user in an ssh URL is the convention, not a secret, so
    # it draws no warning -- only the redaction, which costs nothing.
    case "$fetch_url" in
        *://git@*) : ;;
        *)
            if [ "$(_release_redact_url "$fetch_url")" != "$fetch_url" ]; then
                echo "release: warning: remote '$remote' embeds credentials in its URL;" >&2
                echo "release: warning: consider a credential helper instead" >&2
            fi
            ;;
    esac

    # 4. Bring the checkout in line with the source of truth BEFORE
    #    anything else looks at HEAD. This is the step that stops a stale
    #    clone from tagging week-old history while the draft describes
    #    commits the tag does not contain; without it, correctness rests
    #    on the caller having remembered to pull first.
    local sync_src sync_branch synced current target origin_tip cand
    local origin_fetch origin_push origin_push_count origin_fetch_count sync_tip
    synced=0
    sync_src=''

    # The sync always follows the upstream-then-origin rule, even when a
    # remote was named on the command line: an explicit remote says where
    # the tag is published, not which history is authoritative.
    #
    # An empty RELEASE_NO_SYNC leaves the sync on. Skipping it removes
    # the only guard against tagging stale history, and 'VAR=' is far
    # more often a variable someone cleared than a deliberate request.
    if [ -n "${RELEASE_NO_SYNC:-}" ]; then
        echo "release: RELEASE_NO_SYNC set; tagging HEAD without syncing" >&2
    elif git remote get-url upstream >/dev/null 2>&1; then
        sync_src=upstream
    elif git remote get-url origin >/dev/null 2>&1; then
        sync_src=origin
    elif [ -n "$remote" ]; then
        # No remote by either conventional name, but the caller named
        # one and it is the only history this clone has. Sync from it.
        # The rule above exists to stop 'release <tag> origin' taking
        # the fork as authoritative while an upstream exists -- not to
        # leave a single-remote clone unsynced and tag whatever age of
        # HEAD happens to be checked out.
        sync_src=$remote
    else
        # Not reachable: step 3 refuses a clone with no remotes at all.
        # Refuse rather than skip, so that a future change which makes it
        # reachable cannot quietly tag stale history.
        echo "release: no remote to sync from; set RELEASE_NO_SYNC to tag" >&2
        echo "release: HEAD exactly as it stands" >&2
        return 1
    fi

    if [ -n "$sync_src" ]; then
        # Resolve the source remote's default branch. Ask the remote
        # first: refs/remotes/<remote>/HEAD is a local ref that survives
        # the remote renaming its default branch, and syncing to the old
        # name would tag history the release is not meant to describe.
        #
        # Read the answer and its exit status separately. Piping into awk
        # would report awk's status, making a failed query look exactly
        # like a remote that reports no symbolic HEAD -- and the cached
        # ladder below would then answer from the very ref this call
        # exists to distrust.
        if ! _release_capture git ls-remote --symref "$sync_src" HEAD; then
            echo "release: cannot read the default branch from '$sync_src'" >&2
            printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
            echo "release: what this clone has cached could name a branch the" >&2
            echo "release: remote has since renamed, so this stops instead" >&2
            return 1
        fi

        sync_branch=$(printf '%s\n' "$_release_out" \
            | awk '$1 == "ref:" {
                       sub("^refs/heads/", "", $2)
                       print $2
                       exit
                   }')
        if [ -n "$sync_branch" ]; then
            # The clone's own idea of the default branch is brought into
            # step after the fetch below, not here: 'git remote set-head'
            # needs the remote-tracking ref to exist, and a branch the
            # server has only just renamed to has none yet -- which is
            # precisely the case worth correcting.
            :
        else
            # The remote answered, and reported no symbolic HEAD. Fall
            # back to what is cached, then to the usual names.
            sync_branch=$(git symbolic-ref --quiet --short \
                "refs/remotes/${sync_src}/HEAD" 2>/dev/null \
                | sed "s|^${sync_src}/||")
            if [ -z "$sync_branch" ]; then
                git remote set-head "$sync_src" -a >/dev/null 2>&1 || true
                sync_branch=$(git symbolic-ref --quiet --short \
                    "refs/remotes/${sync_src}/HEAD" 2>/dev/null \
                    | sed "s|^${sync_src}/||")
            fi
            if [ -z "$sync_branch" ]; then
                for cand in main master trunk; do
                    if git show-ref --verify --quiet \
                        "refs/remotes/${sync_src}/${cand}"; then
                        sync_branch=$cand
                        break
                    fi
                done
            fi
        fi
        if [ -z "$sync_branch" ]; then
            echo "release: cannot determine the default branch on '$sync_src'" >&2
            return 1
        fi

        # Tagging a maintenance branch, or a detached HEAD, with a version
        # named explicitly is deliberate: syncing would move the checkout
        # out from under it, so leave it alone and say so. 'latest' is
        # different. The draft is composed from what has landed on the
        # default branch, so that branch is where the release has to be cut
        # from, and sitting on a feature branch is just where the day's
        # work left the clone -- switch to it rather than sending the
        # caller away to do it by hand.
        # A detached HEAD has no symbolic ref, and git says so with a
        # non-zero status. This function runs in the caller's shell,
        # where 'set -e' would take that as a reason to end the session
        # rather than to warn and carry on, which is what the next few
        # lines exist to do.
        current=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || current=''
        if [ "$current" != "$sync_branch" ] && [ "$resolve_draft" -eq 0 ]; then
            echo "release: warning: on '${current:-detached HEAD}', not '$sync_branch';" >&2
            echo "release: warning: skipping the sync and tagging HEAD as it stands" >&2
            sync_src=''
        fi
    fi

    if [ -n "$sync_src" ]; then
        # A tag records HEAD, so uncommitted work is not in the release
        # whatever the tree looks like on screen; and a branch switch
        # would either drag those changes across or refuse halfway. This
        # is the one case the caller has to settle first -- stashing on
        # their behalf would leave work parked somewhere they did not put
        # it, so say what is wrong and stop.
        #
        # --ignore-submodules=none, explicitly. Leaving the option off
        # does not mean "look at everything": it means "do as
        # diff.ignoreSubmodules says", and a clone configured with 'all'
        # would hide a staged gitlink as thoroughly as the option this
        # replaced. A moved submodule pointer sitting in the index is
        # uncommitted work by any reading.
        #
        # An unborn HEAD -- a clone with no commits -- has nothing to diff
        # against, and asking anyway reports every empty repository as
        # dirty. There the index is the only thing that can hold work.
        if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
            if ! git diff --quiet --ignore-submodules=none HEAD 2>/dev/null \
                || ! git diff --cached --quiet --ignore-submodules=none HEAD 2>/dev/null; then
                if [ "$current" != "$sync_branch" ]; then
                    echo "release: working tree is dirty, and '$sync_branch' has to be" >&2
                    echo "release: checked out to cut this release; commit or stash first" >&2
                else
                    echo "release: working tree is dirty; commit or stash first" >&2
                fi
                return 1
            fi
        elif [ -n "$(git ls-files --cached 2>/dev/null)" ]; then
            echo "release: this clone has no commits yet, and files are staged;" >&2
            echo "release: commit or unstage them first" >&2
            return 1
        fi

        # Untracked files are invisible to 'git diff', and a checkout
        # carries them across rather than leaving them on the branch they
        # were made on -- or refuses halfway, when one of them shadows a
        # file the target branch tracks. Neither belongs in a release cut
        # from someone else's clone, so refuse whenever the switch is
        # actually needed. Files that .gitignore covers do not count:
        # build output is not the caller's work.
        if [ "$current" != "$sync_branch" ] \
            || ! git show-ref --verify --quiet "refs/heads/${sync_branch}"; then
            local untracked
            untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
            if [ -n "$untracked" ]; then
                echo "release: '$sync_branch' has to be checked out to cut this" >&2
                echo "release: release, and these untracked files would come too:" >&2
                printf '%s\n' "$untracked" | sed 's/^/release:   /' >&2
                echo "release: commit, remove or ignore them first" >&2
                return 1
            fi
        fi

        if ! git fetch --prune "$sync_src"; then
            echo "release: failed to fetch from '$sync_src'" >&2
            return 1
        fi

        # Now that the tracking refs are current, leave the clone's own
        # idea of the default branch matching the answer the remote gave,
        # so that other tools see what this one did. A failure here
        # changes nothing about the release: sync_branch came from the
        # remote, not from this ref.
        git remote set-head "$sync_src" "$sync_branch" >/dev/null 2>&1 || true

        # Switch to the default branch, creating it from the source remote
        # when this clone has never had it locally. After the fetch, so
        # there is something to branch from.
        #
        # The name in HEAD is not proof the branch exists: a clone with no
        # commits sits on an unborn 'main', where symbolic-ref answers
        # 'main' and refs/heads/main does not exist. Comparing names alone
        # would skip the creation and leave every later 'git rev-parse
        # HEAD' to fail, so the ref is checked as well.
        if [ "$current" != "$sync_branch" ] \
            || ! git show-ref --verify --quiet "refs/heads/${sync_branch}"; then
            if git show-ref --verify --quiet "refs/heads/${sync_branch}"; then
                if ! git checkout "$sync_branch"; then
                    echo "release: failed to check out '$sync_branch'" >&2
                    return 1
                fi
                echo "release: switched from ${current:-a detached HEAD} to '$sync_branch'"
            elif ! git checkout -b "$sync_branch" "${sync_src}/${sync_branch}"; then
                echo "release: failed to create '$sync_branch' from" >&2
                echo "release: ${sync_src}/${sync_branch}" >&2
                return 1
            elif [ "$current" = "$sync_branch" ]; then
                echo "release: created '$sync_branch' from ${sync_src}/${sync_branch}"
            else
                echo "release: switched from ${current:-a detached HEAD} to '$sync_branch'"
            fi
        fi

        if ! target=$(git rev-parse --verify \
            "refs/remotes/${sync_src}/${sync_branch}" 2>/dev/null); then
            echo "release: cannot resolve ${sync_src}/${sync_branch}" >&2
            return 1
        fi

        if [ "$(git rev-parse HEAD)" = "$target" ]; then
            echo "release: '$sync_branch' already matches ${sync_src}/${sync_branch}"
        else
            # Fast-forward only, never a reset: the next step signs a tag
            # and pushes it, so commits that never reached the source
            # remote are treated as a sign the clone is not in the state
            # the caller believes, and are reported rather than dropped.
            if ! git merge-base --is-ancestor HEAD "$target"; then
                echo "release: local '$sync_branch' holds commits that are not on" >&2
                echo "release: ${sync_src}/${sync_branch}:" >&2
                git --no-pager log --oneline "${target}..HEAD" 2>/dev/null \
                    | sed 's/^/release:   /' >&2
                echo "release: resolve manually, e.g." >&2
                echo "release:   git reset --hard $(_release_quote "${sync_src}/${sync_branch}")" >&2
                return 1
            fi
            if ! git merge --ff-only "$target"; then
                echo "release: failed to fast-forward '$sync_branch' to ${sync_src}/${sync_branch}" >&2
                return 1
            fi
            echo "release: fast-forwarded '$sync_branch' to ${sync_src}/${sync_branch}"
        fi
        synced=1

        # Mirror the branch to the fork. Nothing about the
        # tag depends on this -- the tag is cut from local history that
        # now matches the source of truth -- so a fork that cannot be
        # updated is reported and stepped over rather than being allowed
        # to block the release.
        if [ "$sync_src" != origin ] && git remote get-url origin >/dev/null 2>&1; then
            # 'origin' gets the same single-URL treatment as the release
            # remote, and for the same reason: reading one repository and
            # writing another, or several, or not knowing where the push
            # would land at all, makes the comparison below meaningless.
            # The mirror is best-effort, though, so this warns and steps
            # over rather than stopping the release.
            origin_fetch=$(git remote get-url --all origin 2>/dev/null) || origin_fetch=''
            origin_push=$(git remote get-url --push --all origin 2>/dev/null) || origin_push=''
            origin_fetch_count=$(printf '%s\n' "$origin_fetch" \
                | grep -c '[^[:space:]]' || true)
            origin_push_count=$(printf '%s\n' "$origin_push" \
                | grep -c '[^[:space:]]' || true)

            if [ "$origin_fetch_count" -ne 1 ] || [ "$origin_push_count" -ne 1 ] \
                || [ "$origin_push" != "$origin_fetch" ]; then
                echo "release: warning: origin does not fetch and push one URL;" >&2
                echo "release: warning: fork left as it is" >&2
            # Fetch the whole remote rather than the one branch. Naming
            # the branch makes the fetch itself fail when the fork does
            # not carry it yet, which is precisely the case the
            # create-the-branch path below exists to handle, and would
            # leave that path unreachable.
            elif ! git fetch --quiet --prune origin 2>/dev/null; then
                echo "release: warning: cannot fetch from origin;" >&2
                echo "release: warning: fork left as it is" >&2
            else
                origin_tip=$(git rev-parse --verify --quiet \
                    "refs/remotes/origin/${sync_branch}" 2>/dev/null) || origin_tip=''
                if [ "$origin_tip" = "$target" ]; then
                    :
                elif [ -z "$origin_tip" ]; then
                    if ! git push origin "$sync_branch"; then
                        echo "release: warning: failed to create origin/${sync_branch}" >&2
                    fi
                elif ! git merge-base --is-ancestor "$origin_tip" "$target"; then
                    echo "release: warning: origin/${sync_branch} has diverged from" >&2
                    echo "release: warning: ${sync_src}/${sync_branch}; fork left as it is," >&2
                    echo "release: warning: because updating it would rewind history" >&2
                elif ! git push --force-with-lease="${sync_branch}:${origin_tip}" \
                    origin "$sync_branch"; then
                    echo "release: warning: failed to update origin/${sync_branch}" >&2
                fi
            fi
        fi

        # Prove the branch has not moved on since the fetch. 'latest'
        # runs its own version of this check further down, against the
        # branch the draft describes and after the drafter has settled;
        # an explicit version has no such moment, and without this it
        # could sign the tip as it stood a few seconds ago while a merge
        # landed in between -- which is exactly the stale-history case
        # this whole step exists to prevent.
        if [ "$resolve_draft" -eq 0 ]; then
            if ! _release_capture git ls-remote "$sync_src" \
                "refs/heads/$sync_branch"; then
                echo "release: cannot re-read ${sync_src}/${sync_branch}" >&2
                printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
                echo "release: refusing to tag without proving it is current" >&2
                return 1
            fi
            sync_tip=$(printf '%s\n' "$_release_out" | cut -f1)
            if [ -z "$sync_tip" ]; then
                echo "release: ${sync_src} no longer has a branch" >&2
                echo "release: '${sync_branch}'; it was deleted or renamed" >&2
                echo "release: while this ran, so what was fetched is not" >&2
                echo "release: what the source of truth now holds" >&2
                return 1
            fi
            if [ "$sync_tip" != "$(git rev-parse HEAD)" ]; then
                echo "release: ${sync_src}/${sync_branch} moved while syncing" >&2
                echo "release:   HEAD                       $(git rev-parse HEAD)" >&2
                echo "release:   ${sync_src}/${sync_branch} $sync_tip" >&2
                echo "release: re-run to sync and tag the newer tip" >&2
                return 1
            fi
        fi
    fi

    # 5. 'latest' is not a tag name but an instruction: take the version
    #    from the repository's one and only draft release. release-drafter
    #    maintains that draft, so its tag_name is the version the next
    #    release is meant to carry, and re-typing it by hand is the step
    #    that gets it wrong. To tag something literally named 'latest',
    #    say so outright: release --tag latest
    if [ "$resolve_draft" -eq 1 ]; then
        local url host slug wf wf_name interval timeout authority
        local waited fails announced active drafts count title state
        local fails_this_lap remaining nap start now one slept elapsed
        local confirmed_idle wf_paths newline
        local idle_streak confirm_nap
        local default_branch remote_head head_sha

        # gh carries the authentication; draft releases are invisible to
        # anonymous callers, and a wrong answer here tags the wrong commit.
        if ! command -v gh >/dev/null 2>&1; then
            echo "release: 'latest' needs the GitHub CLI (gh)" >&2
            echo "release: install gh, or name the tag explicitly" >&2
            return 1
        fi

        # Settle the poll settings before anything slower runs. Both feed
        # arithmetic and 'sleep' further down: a zero interval leaves
        # 'waited' at zero and polls forever, and a non-numeric one makes
        # the timeout comparison error out on every lap, which also never
        # ends. A leading zero is refused along with them -- '00' is a
        # zero that spells its way past a test for '0', and bash reads
        # '08' as an invalid octal number.
        interval=${RELEASE_DRAFTER_POLL:-10}
        timeout=${RELEASE_DRAFTER_TIMEOUT:-600}
        case "$interval" in
            ''|*[!0-9]*|0*)
                echo "release: RELEASE_DRAFTER_POLL must be a positive integer" >&2
                echo "release: without a leading zero (got '$interval')" >&2
                return 2
                ;;
        esac
        case "$timeout" in
            0) : ;;
            ''|*[!0-9]*|0*)
                echo "release: RELEASE_DRAFTER_TIMEOUT must be a whole number" >&2
                echo "release: of seconds without a leading zero (got '$timeout')" >&2
                return 2
                ;;
        esac

        # Derive host and owner/repo from the remote this function already
        # resolved, rather than letting gh apply its own (different)
        # remote-selection rule to the working directory.
        #
        # A bracketed IPv6 authority is removed before the host-and-port
        # rule in the slug expression, which would otherwise split it at
        # the first colon inside the brackets and leave nothing readable
        # -- and the caller would never reach the RELEASE_GH_HOST
        # override that exists for exactly such a remote.
        url=$(git remote get-url "$remote" 2>/dev/null) || url=''
        host=$(printf '%s\n' "$url" | sed -E \
            -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
            -e 's#^[^/@]*@##' \
            -e 's#[:/].*$##')
        slug=$(printf '%s\n' "$url" | sed -E \
            -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
            -e 's#^[^/@]*@##' \
            -e 's#^\[[^]]*\](:[0-9]+)?##' \
            -e 's#^([^/:]*):([0-9]+)/#\1/#' \
            -e 's#^[^/:]*[:/]##' \
            -e 's#\.git/?$##' \
            -e 's#/$##')

        case "$slug" in
            */*/*|*/|/*|'') slug='' ;;
        esac
        if [ -z "$slug" ] || [ -z "$host" ]; then
            echo "release: cannot read owner/repo from remote '$remote'" >&2
            echo "release: ($(_release_redact_url "$url"))" >&2
            return 1
        fi

        # An authority carrying a port, or an IPv6 literal, is not a host
        # name, and 'gh' is addressed by host name here. Passing the bare
        # name through would query a different endpoint from the one the
        # remote points at -- a GitHub Enterprise instance on :8443 would
        # be asked for its drafts on :443 -- and answer confidently from
        # the wrong place. Say so instead, and offer the override.
        if [ -n "${RELEASE_GH_HOST:-}" ]; then
            host=$RELEASE_GH_HOST
        else
            case "$url" in
                *://*)
                    authority=$(printf '%s\n' "$url" | sed -E \
                        -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
                        -e 's#^[^/@]*@##' \
                        -e 's#/.*$##')
                    case "$authority" in
                        *:*|'['*)
                            echo "release: remote '$remote' points at '$authority'," >&2
                            echo "release: which carries a port or an IPv6 literal." >&2
                            echo "release: 'gh' is addressed by host name alone, so" >&2
                            echo "release: 'latest' would read the draft from a" >&2
                            echo "release: different endpoint than the tag lands on." >&2
                            echo "release: Set RELEASE_GH_HOST to the host 'gh' knows," >&2
                            echo "release: or name the version instead of 'latest'" >&2
                            return 1
                            ;;
                    esac
                    ;;
            esac
        fi

        # One probe call proves the host, the slug and the credentials all
        # work before anything slower runs, and yields the default branch
        # used by the sanity check further down.
        if ! _release_capture gh api --hostname "$host" "repos/$slug" \
                --jq '.default_branch'; then
            echo "release: cannot query $slug on $host" >&2
            printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
            echo "release: check 'gh auth status --hostname $host'" >&2
            return 1
        fi
        default_branch="$_release_out"

        # 5a. Wait for the repository's OWN release-drafter workflow to go
        #     quiet. Pushing a tag while a run is mid-flight races the draft
        #     it is rewriting, and the published release then carries notes
        #     that are one merge out of date.
        #
        #     Only the in-repo workflow counts. The organisation ruleset
        #     injects a same-named workflow from <org>/.github that runs on
        #     open pull requests; its runs report a fully-qualified path
        #     ("<org>/.github/.github/workflows/release-drafter.yaml@ref"),
        #     so addressing the workflow by bare filename excludes it, and
        #     the startswith() guard below excludes it a second time.
        wf=${RELEASE_DRAFTER_WORKFLOW:-release-drafter.yaml}
        wf_name="$wf"

        # A literal newline, for matching whole lines of the workflow
        # listing below. Command substitution strips them, so this is the
        # portable way to hold one.
        newline='
'

        # Establish whether the workflow exists by listing them, rather
        # than probing one by name. A 404 on a single workflow proves
        # nothing: GitHub answers 404 rather than 403 for a resource the
        # token may not see, so a credential that can read the repository
        # but not its Actions would make every workflow look absent and
        # skip the wait entirely -- reinstating the race this whole step
        # exists to prevent.
        #
        # One listing answers all of it: that Actions is readable at all
        # with these credentials, and which spelling is present.
        if ! _release_capture gh api --hostname "$host" --paginate \
                "repos/$slug/actions/workflows?per_page=100" \
                --jq '.workflows[].path'; then
            echo "release: cannot list the workflows on $slug" >&2
            printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
            echo "release: without that, an absent '$wf_name' cannot be told" >&2
            echo "release: from one this token may not see; retry rather than" >&2
            echo "release: race the draft" >&2
            return 1
        fi
        wf_paths=$_release_out

        case "$newline$wf_paths$newline" in
            *"${newline}.github/workflows/${wf}${newline}"*)
                : ;;
            *)
                # Absent under that name. Try the other spelling, unless
                # the caller named one, in which case they meant that one.
                wf=''
                if [ -n "${RELEASE_DRAFTER_WORKFLOW:-}" ]; then
                    echo "release: no in-repo '$wf_name' on $slug; not waiting" >&2
                else
                    case "$newline$wf_paths$newline" in
                        *"${newline}.github/workflows/release-drafter.yml${newline}"*)
                            wf=release-drafter.yml
                            wf_name="$wf"
                            ;;
                        *)
                            echo "release: no in-repo '$wf_name' or" >&2
                            echo "release: 'release-drafter.yml' on $slug; not waiting" >&2
                            ;;
                    esac
                fi
                ;;
        esac

        # Measure the wait by the clock where it can be trusted, and by
        # the time actually slept where it cannot. Each lap also spends
        # time in several API calls, which the sleep counter alone would
        # miss, so both are kept and the larger wins.
        waited=0
        slept=0
        confirmed_idle=0
        start=$(date +%s 2>/dev/null) || start=''
        case "$start" in
            ''|*[!0-9]*) start='' ;;
        esac
        fails=0
        announced=0
        idle_streak=0
        while [ -n "$wf" ]; do
            # Ask for each unfinished status by name rather than reading
            # a page of recent runs and filtering: a queued run sitting
            # behind a hundred newer completed ones would fall off the
            # end of that page and read as idle.
            #
            # Five queries are not one snapshot, and a run that moves
            # between them could slip through the gap. The order below is
            # what closes that: it follows the lifecycle, earliest stage
            # first. A run only ever moves forward, so one that changes
            # status mid-sweep lands in a bucket not yet counted, and a
            # run that finishes mid-sweep is one there was no reason to
            # wait for.
            active=0
            fails_this_lap=0
            for state in requested pending waiting queued in_progress; do
                # Status first, then shape. Reading stdout alone would
                # let a failed call that happened to print a digit pass
                # for an answer, which is the one mistake this whole
                # step exists to avoid.
                if ! _release_capture gh api --hostname "$host" \
                        "repos/$slug/actions/workflows/$wf/runs?status=$state&per_page=100&exclude_pull_requests=true" \
                        --jq '[.workflow_runs[]
                               | select(.path | startswith(".github/workflows/"))]
                              | length'; then
                    fails_this_lap=1
                    continue
                fi

                count=$_release_out
                case "$count" in
                    ''|*[!0-9]*) fails_this_lap=1 ;;
                    *)           active=$((active + count)) ;;
                esac
            done

            # The sweep above cannot see a run created after its own
            # 'requested' query: that run sits in a bucket already
            # counted and is missed. On the confirming lap, add one
            # unfiltered look at the newest runs, which is a single
            # request and so has no internal ordering to fall through --
            # and a run created moments ago is the newest thing there is,
            # so a newest-first page must hold it.
            #
            # The per-status sweep stays for the opposite case: a run
            # queued long ago, sitting behind more than a page of newer
            # completed ones. Neither query answers both questions.
            if [ "$fails_this_lap" -eq 0 ] && [ "$active" -eq 0 ] \
                && [ "$idle_streak" -ge 1 ]; then
                if ! _release_capture gh api --hostname "$host" \
                        "repos/$slug/actions/workflows/$wf/runs?per_page=30&exclude_pull_requests=true" \
                        --jq '[.workflow_runs[]
                               | select(.status != "completed")
                               | select(.path | startswith(".github/workflows/"))]
                              | length'; then
                    fails_this_lap=1
                else
                    case "$_release_out" in
                        ''|*[!0-9]*) fails_this_lap=1 ;;
                        *)           active=$((active + _release_out)) ;;
                    esac
                fi
            fi

            if [ "$fails_this_lap" -eq 1 ]; then
                # Never treat an unreadable answer as "nothing running":
                # that is precisely the race this step exists to avoid.
                fails=$((fails + 1))
                idle_streak=0
                if [ "$fails" -ge 3 ]; then
                    echo "release: cannot read '$wf' runs on $slug; aborting" >&2
                    return 1
                fi
            elif [ "$active" -eq 0 ]; then
                fails=0
                # Lifecycle ordering catches a run that MOVES mid-sweep;
                # the closing probe above catches one CREATED mid-sweep.
                # Requiring two idle laps in a row, a short pause apart,
                # means both questions have been asked twice. What is
                # left is the gap between the last query and reading the
                # draft, which nothing short of a lock on the drafter
                # could close.
                idle_streak=$((idle_streak + 1))
                confirmed_idle=0
                if [ "$idle_streak" -ge 2 ]; then
                    confirmed_idle=1
                fi
            else
                fails=0
                idle_streak=0
                if [ "$announced" -eq 0 ]; then
                    echo "release: waiting for $active active '$wf' run(s) on $slug"
                    announced=1
                fi
            fi

            # Elapsed time, by two measures. The sleep counter is a lower
            # bound that no clock can undermine; the clock can only raise
            # it. Taking the larger keeps the deadline reachable whether
            # the clock stops answering, sticks at one value, or steps
            # backwards -- and still measures the time spent in the API
            # calls, which the sleep counter alone would miss.
            if [ -n "$start" ]; then
                now=''
                if now=$(date +%s 2>/dev/null); then
                    case "$now" in
                        ''|*[!0-9]*) now='' ;;
                    esac
                fi

                if [ -n "$now" ]; then
                    elapsed=$((now - start))
                else
                    # Stopped answering; stop asking.
                    start=''
                    elapsed=0
                fi
            else
                elapsed=0
            fi

            if [ "$elapsed" -gt "$slept" ]; then
                waited=$elapsed
            else
                waited=$slept
            fi

            # The deadline, once a run has actually been waited on.
            # 'announced' is exactly "a run was seen active"; an
            # initially idle workflow has taken none of the caller's
            # time, so RELEASE_DRAFTER_TIMEOUT=0 still confirms and
            # proceeds. Checked here, before the confirmed-idle exit as
            # well as before another lap, so that neither route can
            # succeed past the limit: the confirmation pause is short,
            # but a limit that a short pause can step over is not one.
            if [ "$announced" -eq 1 ] && [ "$waited" -ge "$timeout" ]; then
                if [ "$confirmed_idle" -eq 1 ] || [ "$idle_streak" -ge 1 ]; then
                    echo "release: '$wf' cleared only after ${waited}s, past the" >&2
                    echo "release: ${timeout}s limit; aborting. Retry now -- it will" >&2
                    echo "release: find the workflow idle -- or raise" >&2
                    echo "release: RELEASE_DRAFTER_TIMEOUT" >&2
                else
                    echo "release: '$wf' still running after ${waited}s; aborting" >&2
                    echo "release: retry later, or raise RELEASE_DRAFTER_TIMEOUT" >&2
                fi
                return 1
            fi

            if [ "$confirmed_idle" -eq 1 ]; then
                break
            fi

            if [ "$idle_streak" -ge 1 ]; then
                # Pausing to confirm an idle answer, not waiting on a
                # run. Kept short, and counted towards the deadline like
                # any other sleep, so the clock-independent lower bound
                # stays honest.
                confirm_nap=$interval
                if [ "$confirm_nap" -gt 3 ]; then
                    confirm_nap=3
                fi
                sleep "$confirm_nap"
                slept=$((slept + confirm_nap))
                continue
            fi

            if [ "$waited" -ge "$timeout" ]; then
                echo "release: '$wf' still running after ${waited}s; aborting" >&2
                echo "release: retry later, or raise RELEASE_DRAFTER_TIMEOUT" >&2
                return 1
            fi

            # Never sleep past the deadline. Sleeping a full interval
            # regardless would see RELEASE_DRAFTER_TIMEOUT=1 wake nine
            # seconds late, having promised otherwise.
            remaining=$((timeout - waited))
            nap=$interval
            if [ "$nap" -gt "$remaining" ]; then
                nap=$remaining
            fi
            sleep "$nap"
            slept=$((slept + nap))
        done
        if [ "$announced" -eq 1 ]; then
            echo "release: '$wf' idle after ${waited}s"
        fi

        # 5b. Read the drafts only now, so the answer reflects the settled
        #     state rather than whatever the draft held mid-run.
        # Emit a constant third field so that every draft contributes a
        # non-blank line. A draft with neither a tag nor a title would
        # otherwise produce an empty row, drop out of the count below,
        # and let a second draft slip past the refusal to guess.
        if ! _release_capture gh api --hostname "$host" --paginate \
                "repos/$slug/releases?per_page=100" \
                --jq '.[] | select(.draft) | [.tag_name, .name, "draft"] | @tsv'; then
            echo "release: cannot list releases for $slug" >&2
            printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
            return 1
        fi
        drafts="$_release_out"

        # grep -c prints 0 and exits non-zero when nothing matches, so
        # swallow the status rather than letting it stand as a failure.
        count=$(printf '%s\n' "$drafts" | grep -c '[^[:space:]]' || true)
        if [ "$count" -eq 0 ]; then
            echo "release: no draft release on $slug" >&2
            echo "release: drafts need write access to be visible; check" >&2
            echo "release: 'gh auth status --hostname $host'" >&2
            return 1
        fi
        if [ "$count" -gt 1 ]; then
            echo "release: $slug has $count draft releases; refusing to guess:" >&2
            printf '%s\n' "$drafts" | awk -F '\t' '
                /[^[:space:]]/ {
                    title = ($2 == "" ? "(untitled)" : $2)
                    name  = ($1 == "" ? "(no tag)"   : $1)
                    printf "release:   %s (tag: %s)\n", title, name
                }' >&2
            echo "release: name the wanted tag explicitly, e.g. release <tag>" >&2
            return 1
        fi

        tag=$(printf '%s\n' "$drafts" | sed -n '1p' | cut -f1)
        title=$(printf '%s\n' "$drafts" | sed -n '1p' | cut -f2)
        if [ -z "$tag" ]; then
            echo "release: draft release '${title:-(untitled)}' has no tag name" >&2
            return 1
        fi
        echo "release: draft '${title:-$tag}' on $slug resolves to tag '$tag'"

        # 5c. release-drafter composes the draft from what has landed on the
        #     default branch, so tagging any other commit publishes notes
        #     that do not describe the tagged tree. After the sync in step 4
        #     HEAD is that branch's tip -- unless a merge landed while the
        #     wait above was running, which moves the draft past the commit
        #     about to be tagged, and is worth another lap rather than a
        #     wrong release.
        head_sha=$(git rev-parse HEAD 2>/dev/null) || head_sha=''

        # Read the remote tip in two steps. Piping straight into 'cut'
        # reports cut's status, so an authentication or network failure
        # would arrive as an empty answer and quietly skip the check
        # below -- the last guard standing between a stale HEAD and a
        # signed, pushed tag. Treat an unreadable remote as a reason to
        # stop, not as a clean bill of health.
        if ! _release_capture git ls-remote "$remote" \
                "refs/heads/$default_branch"; then
            echo "release: cannot read $remote/$default_branch" >&2
            printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
            return 1
        fi
        remote_head=$(printf '%s\n' "$_release_out" | cut -f1)
        if [ -z "$remote_head" ]; then
            echo "release: '$remote' has no branch '$default_branch', which is" >&2
            echo "release: what the draft describes" >&2
            return 1
        fi

        if [ "$remote_head" != "$head_sha" ]; then
            if [ "$synced" -eq 1 ]; then
                echo "release: $remote/$default_branch moved while the draft settled" >&2
                echo "release:   HEAD                    $head_sha" >&2
                echo "release:   $remote/$default_branch $remote_head" >&2
                echo "release: re-run to sync and tag the newer tip" >&2
                return 1
            fi
            echo "release: warning: HEAD is not the tip of $remote/$default_branch," >&2
            echo "release: warning: which is what the draft describes" >&2
        fi
    fi

    # 6. Refuse to reuse a tag. The remote is checked as well as the local
    #    repository: a release tagged from another clone exists there and
    #    not here, and the push would fail confusingly late.
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "release: tag '$tag' already exists locally" >&2
        return 1
    fi
    # Read the status, not just the output. An unreadable remote gives an
    # empty answer, which reads as 'the tag is free' -- and the next step
    # signs a tag that the push then fails to deliver, leaving a local tag
    # behind that blocks the retry.
    if ! _release_capture git ls-remote --tags "$remote" "refs/tags/$tag"; then
        echo "release: cannot read tags from '$remote'" >&2
        printf '%s\n' "$_release_err" | _release_redact | sed 's/^/release: /' >&2
        echo "release: refusing to sign a tag without proving '$tag' is free" >&2
        return 1
    fi
    if [ -n "$_release_out" ]; then
        echo "release: tag '$tag' already exists on '$remote'" >&2
        return 1
    fi

    # 7. A tag needs a commit to point at. The sync guarantees one, but
    #    it is skipped for an explicit version on a side branch and by
    #    RELEASE_NO_SYNC, and a clone with no commits reaches here with
    #    an unborn HEAD. Say so plainly: without this, 'diff-index'
    #    below fails and reports the empty repository as modified, then
    #    'git tag' fails again in git's own words.
    if ! git rev-parse -q --verify HEAD >/dev/null 2>&1; then
        echo "release: this clone has no commits, so there is nothing to tag" >&2
        return 1
    fi

    #    Warn (but do not refuse) when tracked files are modified: the tag
    #    records HEAD, so those changes would not be part of the release.
    #    Only reachable when the sync was skipped; it refuses outright.
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "release: warning: tracked files are modified; tagging HEAD anyway" >&2
    fi

    # 8. Tag, then push only if signing succeeded. Chaining on success
    #    rather than unconditionally matters: a cancelled or failed GPG
    #    signature must not be followed by a push.
    echo "release: tagging $(git rev-parse --short HEAD) as '$tag'"
    # Options first, then '--': a tag name is not guaranteed to be safe
    # in the argument position, and git reporting 'unknown switch' for a
    # name it would have rejected anyway helps nobody.
    git tag -s -a -m "$tag" -- "$tag" || return

    if ! git push "$remote" "refs/tags/$tag"; then
        echo "release: push failed; the local tag '$tag' was kept" >&2
        echo "release: retry with  git push $(_release_quote "$remote") $(_release_quote "refs/tags/$tag")" >&2
        # '--' as well as the quoting: a tag beginning with a dash is
        # reachable through --tag, and quoting stops the shell splitting
        # the word without stopping git reading it as options.
        echo "release: remove with git tag -d -- $(_release_quote "$tag")" >&2
        return 1
    fi

    echo "release: pushed signed tag '$tag' to '$remote'"
}
