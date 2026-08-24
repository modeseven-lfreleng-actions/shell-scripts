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
#
# Environment (all optional):
#   LFRELENG_ACTIONS_FORK_PATH  directory holding the caller's clones; the
#                               repository forms search it for a clone of
#                               the named repository. install.sh sets it
#   RELEASE_REPO_ROOT           overrides the above for this function
#                               alone. Either may be a PATH-style
#                               colon-separated list, searched in order,
#                               first match winning
#   RELEASE_NO_SYNC             set to any value to tag HEAD exactly as it
#                               stands, skipping the sync. For tagging a
#                               commit deliberately held back from the
#                               default branch; it removes the only guard
#                               against tagging stale history
#   RELEASE_DRAFTER_WORKFLOW    workflow file to wait on (default
#                               release-drafter.yaml, falling back to
#                               release-drafter.yml when unset)
#   RELEASE_DRAFTER_TIMEOUT     seconds to wait before giving up (600)
#   RELEASE_DRAFTER_POLL        seconds between checks (10)
#
# Naming a tag explicitly calls nothing but 'git'; the 'latest' forms
# additionally need the GitHub CLI ('gh'), authenticated for the remote's
# host, because draft releases are invisible to anonymous callers. Tagging
# runs 'git tag -s', so the caller needs a working signing setup.
#
# Shell compatibility: POSIX-style syntax plus 'local'; works in zsh and bash.
# ---------------------------------------------------------------------------

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
    local want_repo
    want_repo=''
    if [ "$2" = latest ]; then
        want_repo=form
    elif [ -n "$1" ] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        want_repo=implied
    else
        case "$1" in
            ''|*[0-9]*) : ;;
            *)          want_repo=check ;;
        esac
    fi

    if [ -n "$want_repo" ]; then
        local roots rest root name candidate found stray bypath sub_remote

        # Tolerate the trailing slash that filename completion leaves
        # behind, so 'release python-test-action/ latest' still works.
        name=${1%/}
        found=''
        stray=''
        bypath=''
        if [ -z "$name" ]; then
            echo "release: usage: release [<repo>] <tag|latest> [remote]" >&2
            echo "release:        release <repo> [remote]  (outside a clone)" >&2
            return 2
        fi

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
                while [ -n "$rest" ]; do
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
                # A digitless word that names no clone: an unusual tag,
                # but the caller's to make. Fall through and tag it.
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
                    echo "release: (install.sh does this for you)" >&2
                else
                    echo "release: no clone of '$name' under:" >&2
                    printf '%s\n' "$roots" | tr ':' '\n' | sed 's/^/release:   /' >&2
                    echo "release: set RELEASE_REPO_ROOT to search elsewhere" >&2
                fi
                if [ "$want_repo" = implied ]; then
                    # Spell out the reading, because the caller may have
                    # typed a version and forgotten to cd first.
                    echo "release: ('$name' was read as a repository name: the" >&2
                    echo "release: current directory is not inside a repository)" >&2
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
            echo "release:   release $name latest   releases that clone" >&2
            echo "release:   cd out of this repository and repeat" >&2
            echo "release: or name a version, which always holds a digit" >&2
            return 1
        else
            # 'latest' second means the remote is third; an implied
            # 'latest' leaves the remote second.
            if [ "$2" = latest ]; then
                sub_remote="$3"
            else
                sub_remote="$2"
            fi

            echo "release: working in $found"
            ( cd "$found" >/dev/null && release latest "$sub_remote" )
            return $?
        fi
    fi

    local tag="$1"
    local remote="$2"

    # 1. Require a tag name.
    if [ -z "$tag" ]; then
        echo "release: usage: release [<repo>] <tag|latest> [remote]" >&2
        echo "release:        release <repo> [remote]  (outside a clone)" >&2
        return 2
    fi

    # 2. Must be inside a working tree; a tag needs a commit to point at.
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "release: not inside a git repository" >&2
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

    # 4. Bring the checkout in line with the source of truth BEFORE
    #    anything else looks at HEAD. This is the step that stops a stale
    #    clone from tagging week-old history while the draft describes
    #    commits the tag does not contain; without it, correctness rests
    #    on the caller having remembered to pull first.
    local sync_src sync_branch synced current target origin_tip cand
    synced=0
    sync_src=''

    # The sync always follows the upstream-then-origin rule, even when a
    # remote was named on the command line: an explicit remote says where
    # the tag is published, not which history is authoritative.
    if [ -n "${RELEASE_NO_SYNC:-}" ]; then
        echo "release: RELEASE_NO_SYNC set; tagging HEAD without syncing" >&2
    elif git remote get-url upstream >/dev/null 2>&1; then
        sync_src=upstream
    elif git remote get-url origin >/dev/null 2>&1; then
        sync_src=origin
    else
        # Only reachable when an explicit remote named something else;
        # step 3 has already rejected the no-remotes case.
        echo "release: warning: no 'upstream' or 'origin' remote to sync from" >&2
    fi

    if [ -n "$sync_src" ]; then
        # Resolve the source remote's default branch: its symbolic HEAD
        # first (set by clone, or by 'git remote set-head'), then a local
        # probe, then ask the remote itself.
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
        if [ -z "$sync_branch" ]; then
            # Nothing cached locally: a remote added but never fetched.
            sync_branch=$(git ls-remote --symref "$sync_src" HEAD 2>/dev/null \
                | awk '$1 == "ref:" {
                           sub("^refs/heads/", "", $2)
                           print $2
                           exit
                       }')
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
        current=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
        if [ "$current" != "$sync_branch" ] && [ "$tag" != latest ]; then
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
        if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null \
            || ! git diff --cached --quiet --ignore-submodules HEAD 2>/dev/null; then
            if [ "$current" != "$sync_branch" ]; then
                echo "release: working tree is dirty, and '$sync_branch' has to be" >&2
                echo "release: checked out to cut this release; commit or stash first" >&2
            else
                echo "release: working tree is dirty; commit or stash first" >&2
            fi
            return 1
        fi

        if ! git fetch --prune "$sync_src"; then
            echo "release: failed to fetch from '$sync_src'" >&2
            return 1
        fi

        # Switch to the default branch, creating it from the source remote
        # when this clone has never had it locally. After the fetch, so
        # there is something to branch from.
        if [ "$current" != "$sync_branch" ]; then
            if git show-ref --verify --quiet "refs/heads/${sync_branch}"; then
                if ! git checkout "$sync_branch"; then
                    echo "release: failed to check out '$sync_branch'" >&2
                    return 1
                fi
            elif ! git checkout -b "$sync_branch" "${sync_src}/${sync_branch}"; then
                echo "release: failed to create '$sync_branch' from" >&2
                echo "release: ${sync_src}/${sync_branch}" >&2
                return 1
            fi
            echo "release: switched from ${current:-a detached HEAD} to '$sync_branch'"
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
                echo "release:   git reset --hard ${sync_src}/${sync_branch}" >&2
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
            if ! git fetch --quiet origin "$sync_branch" 2>/dev/null; then
                echo "release: warning: cannot fetch '$sync_branch' from origin;" >&2
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
    fi

    # 5. 'latest' is not a tag name but an instruction: take the version
    #    from the repository's one and only draft release. release-drafter
    #    maintains that draft, so its tag_name is the version the next
    #    release is meant to carry, and re-typing it by hand is the step
    #    that gets it wrong. To tag something literally named 'latest',
    #    use plain git: git tag -s latest -m latest && git push <remote> latest
    if [ "$tag" = latest ]; then
        local url host slug probe wf wf_name interval timeout
        local waited fails announced active drafts count title
        local default_branch remote_head head_sha

        # gh carries the authentication; draft releases are invisible to
        # anonymous callers, and a wrong answer here tags the wrong commit.
        if ! command -v gh >/dev/null 2>&1; then
            echo "release: 'latest' needs the GitHub CLI (gh)" >&2
            echo "release: install gh, or name the tag explicitly" >&2
            return 1
        fi

        # Derive host and owner/repo from the remote this function already
        # resolved, rather than letting gh apply its own (different)
        # remote-selection rule to the working directory.
        url=$(git remote get-url "$remote" 2>/dev/null)
        host=$(printf '%s\n' "$url" | sed -E \
            -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
            -e 's#^[^/@]*@##' \
            -e 's#[:/].*$##')
        slug=$(printf '%s\n' "$url" | sed -E \
            -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
            -e 's#^[^/@]*@##' \
            -e 's#^([^/:]*):([0-9]+)/#\1/#' \
            -e 's#^[^/:]*[:/]##' \
            -e 's#\.git/?$##' \
            -e 's#/$##')

        case "$slug" in
            */*/*|*/|/*|'') slug='' ;;
        esac
        if [ -z "$slug" ] || [ -z "$host" ]; then
            echo "release: cannot read owner/repo from '$remote' ($url)" >&2
            return 1
        fi

        # One probe call proves the host, the slug and the credentials all
        # work before anything slower runs, and yields the default branch
        # used by the sanity check further down.
        if ! probe=$(gh api --hostname "$host" "repos/$slug" \
                --jq '.default_branch' 2>&1); then
            echo "release: cannot query $slug on $host" >&2
            printf '%s\n' "$probe" | sed 's/^/release: /' >&2
            echo "release: check 'gh auth status --hostname $host'" >&2
            return 1
        fi
        default_branch="$probe"

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
        interval=${RELEASE_DRAFTER_POLL:-10}
        timeout=${RELEASE_DRAFTER_TIMEOUT:-600}

        if ! gh api --hostname "$host" \
                "repos/$slug/actions/workflows/$wf" --silent >/dev/null 2>&1; then
            wf=''
            if [ -z "${RELEASE_DRAFTER_WORKFLOW:-}" ] && \
               gh api --hostname "$host" \
                   "repos/$slug/actions/workflows/release-drafter.yml" \
                   --silent >/dev/null 2>&1; then
                wf=release-drafter.yml
                wf_name="$wf"
            else
                echo "release: no in-repo '$wf_name' on $slug; not waiting" >&2
            fi
        fi

        waited=0
        fails=0
        announced=0
        while [ -n "$wf" ]; do
            active=$(gh api --hostname "$host" \
                "repos/$slug/actions/workflows/$wf/runs?per_page=100&exclude_pull_requests=true" \
                --jq '[.workflow_runs[]
                       | select(.status != "completed")
                       | select(.path | startswith(".github/workflows/"))]
                      | length' 2>/dev/null)

            if [ -z "$active" ]; then
                # Never treat an unreadable answer as "nothing running":
                # that is precisely the race this step exists to avoid.
                fails=$((fails + 1))
                if [ "$fails" -ge 3 ]; then
                    echo "release: cannot read '$wf' runs on $slug; aborting" >&2
                    return 1
                fi
            else
                fails=0
                if [ "$active" -eq 0 ]; then
                    break
                fi
                if [ "$announced" -eq 0 ]; then
                    echo "release: waiting for $active active '$wf' run(s) on $slug"
                    announced=1
                fi
            fi

            if [ "$waited" -ge "$timeout" ]; then
                echo "release: '$wf' still running after ${timeout}s; aborting" >&2
                echo "release: retry later, or raise RELEASE_DRAFTER_TIMEOUT" >&2
                return 1
            fi
            sleep "$interval"
            waited=$((waited + interval))
        done
        if [ "$announced" -eq 1 ]; then
            echo "release: '$wf' idle after ${waited}s"
        fi

        # 5b. Read the drafts only now, so the answer reflects the settled
        #     state rather than whatever the draft held mid-run.
        if ! drafts=$(gh api --hostname "$host" --paginate \
                "repos/$slug/releases?per_page=100" \
                --jq '.[] | select(.draft) | [.tag_name, .name] | @tsv' 2>&1); then
            echo "release: cannot list releases for $slug" >&2
            printf '%s\n' "$drafts" | sed 's/^/release: /' >&2
            return 1
        fi

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
        head_sha=$(git rev-parse HEAD 2>/dev/null)
        remote_head=$(git ls-remote "$remote" "refs/heads/$default_branch" 2>/dev/null | cut -f1)
        if [ -n "$remote_head" ] && [ "$remote_head" != "$head_sha" ]; then
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
    if [ -n "$(git ls-remote --tags "$remote" "refs/tags/$tag" 2>/dev/null)" ]; then
        echo "release: tag '$tag' already exists on '$remote'" >&2
        return 1
    fi

    # 7. Warn (but do not refuse) when tracked files are modified: the tag
    #    records HEAD, so those changes would not be part of the release.
    #    Only reachable when the sync was skipped; it refuses outright.
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "release: warning: tracked files are modified; tagging HEAD anyway" >&2
    fi

    # 8. Tag, then push only if signing succeeded. Chaining on success
    #    rather than unconditionally matters: a cancelled or failed GPG
    #    signature must not be followed by a push.
    echo "release: tagging $(git rev-parse --short HEAD) as '$tag'"
    git tag -s -a "$tag" -m "$tag" || return

    if ! git push "$remote" "refs/tags/$tag"; then
        echo "release: push failed; the local tag '$tag' was kept" >&2
        echo "release: retry with  git push $remote refs/tags/$tag" >&2
        echo "release: remove with git tag -d $tag" >&2
        return 1
    fi

    echo "release: pushed signed tag '$tag' to '$remote'"
}
