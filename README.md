<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🐚 Shell Scripts

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/shell-scripts) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/shell-scripts/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/shell-scripts)
<!-- prettier-ignore-end -->

Shell tools for the people who maintain the `lfreleng-actions`
repositories. Each tool is a shell function that an interactive shell
sources at start-up, so it runs in the caller's own shell rather than a
subprocess, and can act on the current directory.

Everything here runs under both **bash** and **zsh**, on Linux and macOS.
The installer plumbs the whole collection in at once, and picks up new
tools as they arrive.

## Tools

<!-- markdownlint-disable MD013 -->

| Tool                  | Summary                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------- |
| [`release`](#release) | Sync a clone with its source of truth, then push a signed tag that publishes the release |

<!-- markdownlint-enable MD013 -->

## Requirements

- `bash` (3.2 or newer, so macOS's own `/bin/bash` qualifies) or `zsh`
- `/bin/sh`, `awk`, `sed` and `git`, which every supported platform ships
- Individual tools may need more; see each tool's own section

## Installation

Clone the repository, then run the installer:

```bash
git clone https://github.com/lfreleng-actions/shell-scripts.git
cd shell-scripts
./install.sh
```

The installer asks one question: which directory holds your clones of the
`lfreleng-actions` repositories. It offers the directory this clone sits
in, which answers the question for most people. Tools read that answer
back from `LFRELENG_ACTIONS_FORK_PATH` to find a clone by repository name.

Open a new shell, or run `exec $SHELL -l`, to pick up the tools.

Non-interactive installs skip the question:

```bash
./install.sh --fork-path "$HOME/Repositories/lfreleng-actions"
./install.sh --yes          # accept the offered default
./install.sh --dry-run      # report what would change, change nothing
```

### What the installer writes

One block, between two marker comments, in each shell start-up file it
manages:

<!-- markdownlint-disable MD046 -->

```sh
# >>> lfreleng-actions/shell-scripts >>>
# Managed by shell-scripts/install.sh -- ...
if [ -z "${LFRELENG_ACTIONS_FORK_PATH:-}" ]; then
    LFRELENG_ACTIONS_FORK_PATH="$HOME/Repositories/lfreleng-actions"
fi
export LFRELENG_ACTIONS_FORK_PATH
LFRELENG_SHELL_SCRIPTS="$LFRELENG_ACTIONS_FORK_PATH/shell-scripts"
export LFRELENG_SHELL_SCRIPTS
if [ -r "$LFRELENG_SHELL_SCRIPTS/loader.sh" ]; then
    . "$LFRELENG_SHELL_SCRIPTS/loader.sh"
fi
# <<< lfreleng-actions/shell-scripts <<<
```

<!-- markdownlint-enable MD046 -->

That block is the entire footprint. The installer copies nothing into
`~/.local`, `/usr/local`, or anywhere else: the shell reads the tools
straight out of the clone. The files it lands in are:

<!-- markdownlint-disable MD013 -->

| File              | When                                                                   |
| ----------------- | ---------------------------------------------------------------------- |
| `~/.zshrc`        | the machine has zsh, or the file exists already                        |
| `~/.bashrc`       | the machine has bash, or the file exists already                       |
| `~/.bash_profile` | it exists and does not itself source `~/.bashrc`, as on macOS Terminal |

<!-- markdownlint-enable MD013 -->

The installer honours `$ZDOTDIR` when you set it. Before changing a file
it copies it to `<file>.lfreleng.bak`, and it refuses to touch a file
whose markers someone half-deleted by hand.

Re-running the installer replaces the block rather than appending a second
one, so run it as often as you like — after a `git pull`, or to change the
recorded directory.

### Updating

```bash
cd shell-scripts && git pull
```

New shells pick the changes up. Because the block sources the clone
directly, tools added to the repository appear without a re-install;
re-run `./install.sh` to change the recorded directory, and for nothing
else.

### Checking the installation

```bash
./install.sh --status
```

This reports the clone in use, the recorded directory, and which start-up
files carry the block. A block in a file that the installer would no
longer choose shows as `stray`.

### Uninstalling

```bash
./install.sh --uninstall
```

This removes the block from every start-up file that carries one, keeping
a `.lfreleng.bak` copy of each. Delete the clone afterwards and nothing
remains.

### Leaving a tool out

Should a tool's name collide with something already in your environment,
name it in `LFRELENG_SHELL_SCRIPTS_SKIP` before the block runs:

```sh
export LFRELENG_SHELL_SCRIPTS_SKIP="release"
```

The value is a space-separated list of tool names, matched whole, so
skipping `release` would leave a future `release-notes` alone.

---

## release

Sync a clone with its source of truth, then create a signed, annotated tag
and push it — which is what publishes the release that `release-drafter`
has been assembling.

<!-- markdownlint-disable MD013 -->

```console
$ release verify-release-schema-action
release: working in ~/Repositories/lfreleng-actions/verify-release-schema-action
release: switched from ci/add-openssf-scorecard to 'main'
release: fast-forwarded 'main' to upstream/main
release: draft 'v0.5.0' on lfreleng-actions/verify-release-schema-action resolves to tag 'v0.5.0'
release: tagging 5c025c3 as 'v0.5.0'
release: pushed signed tag 'v0.5.0' to 'upstream'
```

<!-- markdownlint-enable MD013 -->

### Calling forms

<!-- markdownlint-disable MD013 -->

| Command                          | Effect                                                     |
| -------------------------------- | ---------------------------------------------------------- |
| `release <repo>`                 | From outside any clone: find that clone and release it     |
| `release <repo> latest`          | The same, from anywhere, including inside another clone    |
| `release <repo> latest <remote>` | The same, publishing to a named remote                     |
| `release latest`                 | Release the current clone at the version the draft carries |
| `release latest <remote>`        | The same, publishing to a named remote                     |
| `release v1.2.3`                 | Tag the current clone with a version you name yourself     |
| `release v1.2.3 <remote>`        | The same, publishing to a named remote                     |

<!-- markdownlint-enable MD013 -->

`release <repo>` is the short form, and covers most days: standing
anywhere that is not itself a git repository, a bare word cannot be a
version to tag, so it reads as a repository name, and `release` assumes
`latest`. Inside a clone the older reading stands — a bare word is the
version to tag — which is why the three-word form exists.

A first word holding a slash counts as a path to the clone, so a pasted or
tab-completed directory works as well as a bare repository name.

No `release <repo> <tag>` form exists, by design: nothing tells it apart
from `release <tag> <remote>`. To tag a named version in another clone,
`cd` there first.

### What `latest` means

`latest` asks GitHub which version the repository holds in draft, rather
than trusting the version typed at the prompt. `release-drafter` keeps a
single draft per repository and stores the next version in its `tag_name`,
which makes that draft the authority. Given no draft, or more than one,
the function names what it found and stops instead of guessing.

Before reading the draft it waits for the repository's **own**
`release-drafter` workflow runs to finish. A tag pushed while a run is
mid-flight races the draft that run is rewriting, and the published release
then carries notes one merge out of date. The organisation ruleset injects
a second, same-named drafter workflow from `<org>/.github` that runs on
open pull requests; those runs never touch this repository's draft, so the
wait ignores them.

### Syncing

A tag records whatever `HEAD` points at, and a clone left alone for a week
points at week-old history: the tag then names a commit the release notes
do not describe, and the release ships a tree nobody meant to publish.

Every run starts by fetching the source of truth, fast-forwarding the
default branch onto it, and mirroring that branch to the `origin` fork
when `origin` is a different remote. The fast-forward is strict: it
reports local commits that never reached the source remote, and drops
none of them.

The sync steps aside, with a warning, when `HEAD` sits somewhere other than
the source remote's default branch **and** you named a version explicitly.
Tagging a maintenance branch is a legitimate, if rarer, act, and the
checkout should not move out from under it. `latest` is different — the
draft describes the default branch, so `release` checks that branch out
first, which is what lets `release <repo>` work against a clone left
sitting on whatever feature branch was in hand.

Uncommitted work stops the run instead. Stashing on the caller's behalf
would leave changes parked somewhere they did not put them.

### What it refuses to do

- Run outside a git repository, unless the first word names a clone
- Tag a digitless word that also names a clone, which is the repository
  form typed from inside some other repository
- Sync, or switch branches, over uncommitted work
- Discard local commits to sync
- Reuse a tag that already exists, locally or on the remote
- Push after signing the tag failed
- Guess, when `latest` matches no draft release, or more than one
- Push while `release-drafter` is still updating the draft

### Environment

<!-- markdownlint-disable MD013 -->

| Variable                     | Default                | Meaning                                                        |
| ---------------------------- | ---------------------- | -------------------------------------------------------------- |
| `LFRELENG_ACTIONS_FORK_PATH` | set by `install.sh`    | Directory holding your clones; searched for a named repository |
| `RELEASE_REPO_ROOT`          | unset                  | Overrides the above for this tool alone                        |
| `RELEASE_NO_SYNC`            | unset                  | Any value tags `HEAD` as it stands, skipping the sync          |
| `RELEASE_DRAFTER_WORKFLOW`   | `release-drafter.yaml` | Workflow file to wait on, falling back to `.yml` when unset    |
| `RELEASE_DRAFTER_TIMEOUT`    | `600`                  | Seconds to wait for that workflow before giving up             |
| `RELEASE_DRAFTER_POLL`       | `10`                   | Seconds between checks                                         |

<!-- markdownlint-enable MD013 -->

Either directory variable may be a `PATH`-style colon-separated list,
searched in order, first match winning. A leading `~` expands, since
`export VAR="~/Repositories"` stores a literal tilde rather than your home
directory.

### What `release` needs

- `git`
- `gh`, the GitHub CLI, which the `latest` forms need, authenticated for
  the remote's host: draft releases are invisible to anonymous callers.
  Check with `gh auth status`
- A working tag-signing setup, because the tool runs `git tag -s`:

  ```bash
  git config --get user.signingkey
  git config --get gpg.format      # empty output means OpenPGP
  gpg --card-status                # for a YubiKey or other smartcard
  ```

  A per-repository override in `.git/config` beats the global setting, and
  is a common cause of `No private key found for public key ...`. Inspect
  one clone with `git config --local --list`.

---

## Adding a tool

Drop a file in `tools/`, named after the function it defines:

```sh
tools/my-tool.sh    ->    my-tool
```

The loader sources everything matching `tools/*.sh` in name order, so
nothing needs registering. A tool should:

- carry the SPDX header and a `# shellcheck shell=bash` directive
- define functions, and nothing else, at source time — the file runs in
  every new interactive shell, so work done at the top level is a delay
  the whole team pays for
- stick to POSIX syntax plus `local`, which is the intersection of bash
  and zsh. In particular, unquoted parameters do not word-split in zsh,
  and each shell spells arrays differently
- report failures as `my-tool: ...` on stderr and `return` non-zero, never
  `exit`, which would close the caller's shell

Add a row to the [Tools](#tools) table and a section below, then run
`prek run --all-files` before opening a pull request.

## Notes

Tools live in the caller's shell by design. A tool that ran in a
subprocess and nowhere else would be a script on `$PATH` instead, and
these need to change directory, read shell state, or fail without taking
the shell down with them.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/shell-scripts/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/shell-scripts/main.svg
