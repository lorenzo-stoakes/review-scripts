# review-scripts

**WARNING:** This is very early days, I am using these on a daily basis, and
also bugfixing as I go, so this isn't guaranteed to work on your system or not
have weird bugs. Note that `review-start-*` will insert tags to track bases of
review series in the kernel git tree

A series of scripts to help reviewing of kernel patch series. These are
essentially light wrappers around other tooling to make review faster.

**DISCLAIMER:** I don't guarantee these won't lose you work, destroy your git repos,
            cause lego to fall beneath your bare foot such that you step on it
            or any other such calamities and I disclaim all responsibility for
            such! Use these at your own risk.

Note this will generate ugly local tags to store metadata of the form
review-xxx. Using `review-stop` or `review-clean` will clean these up.

It will also create branches of the form `review/[name]-[version]`. Use
`review-clean` to get rid of these.

## Dependencies

* usual coreutils etc.
* git (>= v2.45)
* b4
* git-delta
* virtme-ng
* neomutt
* ansi2txt
* delta

## Installation

1. Ensure dependencies are installed.
2. Put this directory on your `$PATH`.

It is recommended that you run:

```
git config --global am.threeWay true
```

So that you can resolve conflicts in series when they are applied.

### Hooks

Kernel configuration and build scripts are located in the `hooks/` subdirectory:

* `kernel-config` - run once before build.
* `kernel-config-debug` - run once before build, with debug settings.
* `kernel-build` - run for each build.

These can be adjusted to taste.

## Scripts

**IMPORTANT**: b4 isn't always great at finding all the versions of a
series. Therefore you may need to have separate review names for separate
revisions. You can use `review-diff-pair` to workaround this issue for range
diff comparisons.

* `review-mk` - Build kernel using all system cores, terminating the build and
  all stdout output upon seeing stderr.

* `review-start [name] [head] [msgid] <override>` - Start a review which you're
  naming `name`, which you're basing on revision `head` and where `msgid` is the
  msgid that exists in lore for a message in one of the revisions you intend to
  review. Runs `review-get` on startup to setup review branches. If `override`
  is not empty, ignore any checks for existing series in the tree.

* `review-start-applied [name] [base ref] [head ref] [version] <msgid>` Manually
  start a review where the series has already been applied and exists in the
  tree, from `base ref` to `head ref` at version `version`. From there you can
  use the rest of the review tools as if it were obtained normally. If `msgid`
  is not provided, then it is assumed it is out-of-tree work and a stub value is
  set, meaning scripts that retrieve data from the upstream list will fail.

* `review-get [name]` - Retrieves latest messages for all revisions and updates
  local branches, placing them in `review/name-vN` braanches.

* `review-stop [name]` - Remove tag for review but leave branches around.

* `review-clear [name]` - Clear everything (tag and branches) for the specified
  review.

* `review-clear-branches [name]` - Just clear the branches, leave the review
  active.

* `review-diff [name] <version>` - Provide a side-by-side range-diff between the
  latest revision in the series and the prior one. If `version` specified then
  compare `version - 1` to `version`, otherwise the latest version will be
  compared to previous by default.

* `review-diff-pair [previous name] [current name] <previous version> <current
  version>` - Same as review-diff, except it's comparing ranges across separate
  reviews. Useful for series that b4 loses track of, or RFC -> non-RFC, etc.

* `review-diff-each [name] <version>` - Review each individual patch in the
  series at the specified version (or latest if not specified) using `git show`.

* `review-read [name]` - Retrieve the mail for all versions of the series and
  all replies, and load it in neomutt.

* `review-checkpatch [name] <version>` - Just run `checkpatch.pl` against all
  patches in series.

* `review-check [name] <version>` - Build each patch. Defaults to the latest
  version, unless specified. Afterwards this runs `checkpatch.pl` against each
  patch.

* `review-check-mm-tests [name] <version>` - Build series at specified version
  or if not specified, the latest, compile the mm self tests and then run them
  in this kernel version. **WARNING:** this runs with sudo and R/W with access
  to host file system. Some tests won't work if you don't do this, so don't
  blame me if your filesystem breaks.

* `review-check-mm [name] <version>` - Execute _all_ checks for mm series, from
  easiest checks to hardest, so a checkpatch check first, then self tests check,
  then individual per-patch build test.

* `review-mm-tests <--vma-tests-only> <--mm-tests-only>` - Build/run VMA tests
  and/or memory management self tests, but _no review has to be active_, this
  will simply be run against the current kernel tree for convenience.

* `review-mm-tests-arm64` - Builds/runs mm selftests in an arm64
  environment. **NOTE: slow**. Possibly buggy. But it does work kinda :)

* `review-mbox [name]` - Retrieves an mbox of all mails associated with series,
  and saves it into the local directory as `review_[name].mbx`.

* `review-patches [name] <version>` - Retrieves all the patches in the series
  and saves them locally as a series of *.patch files (minus the cover patch),
  optionally at the specified version, if not specified then the latest.

* `review-build` - Simple script to configure and build the kernel using the
  configuration/build hooks.

* `review-rebuild` - Same as `review-build` but runs `review-reconfig` first,
  resetting the config and rebuilding the kernel from scratch.

* `review-rebuild-debug` - Same as `review-rebuild` but uses
  `review-reconfig-debug` to build a kernel with extra debug checks.

* `review-config` - Simple script to configure the kernel using the
  configuration hook.

* `review-config-debug` Same as `review-config`, but sets additional debug
  options that might slow things down quite a bit.

* `review-reconfig` - Same as `review-config` only run a `make mrproper` first to
  clear existing configuration.

* `review-reconfig-debug` - Same as `review-config-debug` only run a `make
  mrproper` first to clear existing configuration.

* `review-rebase [name] [new_base] <version>` - Rebase the review branch on to
  new_base, either at the specified version, or if not specified the latest. See
  `review-rebase-branch` for further details.

* `review-rebase-branch [branch] [old_base] [new_base] <nopause>` - Rebase
  `branch` from `old_base` to `new_base`. This assumes you're dealing with an
  often-rebased repo (which kernel development repos/branches often are), so
  tries to do this with a cherry-pick. Since conflicts can arise, we have 2 ways
  of dealing with it - manually, where an error message indicates user can
  manually give up on it (see `review-rebase-abort`) or continue applying steps
  after cherry-pick resolutions applied (see
  `review-rebase-continue`). Alternatively, if able to (`nopause` param is
  unset), the script will pause and allow resolution in the background, and can
  be resumed via `fg`.

* `review-rebase-abort [branch] [old_base] [new_base]` - Aborts an ongoing
  cherry-pick rebase started by `review-rebase` or `review-rebase-branch` -
  cleaning up the mess created.

* `review-rebase-continue [branch] [old_base] [new_base]` - Continues an ongoing
  cherry-pick rebase started by `review-rebase` or `review-rebase-branch` -
  performing the final steps to apply the rebase.

* `review-vng [args...]` - Execute virtme-ng with sensible configuration options
  for development - verbose output for dmesg logs, panic-on-warning,oops and a
  configuration that is known-working with mm selftests.

* `review-vng-debug [args...]` - Same as `review-vng` but with more noise useful
  for debugging.

* `review-ls` - Lists all review branches in a kernel tree.

* `review-build-commits <commit from> <commit to>` - Build all commits in a
  range (if `commit from` or `commit to` is not specified, they default to
  `HEAD` - so executing without parameters checks current commit) ensuring that
  no individual commit breaks the build.

* `review-build-commits-pedantic <commit from> <commit to>` - Like
  `review-build-commits` only builds each commit against an allnoconfig, a
  normal debug build, a clang/rust build, a nommu build and an arm64 build to
  truly exercise the series.

* `review-clean` - Clear all configurations for all architectures and restore
  `review-config` afterwards.

* `review-mm <--vma-tests-only> <--mm-tests-only>` - Run `review-mm-tests`,
  passing parameters on to it and `review-build-commits-pedantic` to check the
  _current commit_ against these tests and all builds.

## Credit

Thanks to [Tomáš Janoušek](https://genserver.social/users/liskin) for his
incredible
[article](https://work.lisk.in/2023/10/19/side-by-side-git-range-diff.html) on
implementing the side-by-side diff for git range-diff.

I include his `git-range-diff-delta-preproc` helper script under the MIT license.

## Example

## Start review, fixup conflict, grab again

```
# Start review, grab series
]$ review-start procmap_query mm-unstable 20250804231552.1217132-1-surenb@google.com
--- retrieving data for [procmap_query]... ---
Grabbing thread from lore.kernel.org/all/20250804231552.1217132-1-surenb@google.com/t.mbox.gz
...
Applying: selftests/proc: test PROCMAP_QUERY ioctl while vma is concurrently modified
Applying: fs/proc/task_mmu: factor out proc_maps_private fields used by PROCMAP_QUERY
Using index info to reconstruct a base tree...
M	fs/proc/internal.h
M	fs/proc/task_mmu.c
Falling back to patching base and 3-way merge...
Auto-merging fs/proc/internal.h
Auto-merging fs/proc/task_mmu.c
CONFLICT (content): Merge conflict in fs/proc/task_mmu.c
Patch failed at 0002 fs/proc/task_mmu: factor out proc_maps_private fields used by PROCMAP_QUERY
error: Failed to merge in the changes.
hint: Use 'git am --show-current-patch=diff' to see the failed patch
hint: When you have resolved this problem, run "git am --continue".
hint: If you prefer to skip this patch, run "git am --skip" instead.
hint: To restore the original branch and stop patching, run "git am --abort".
hint: Disable this message with "git config set advice.mergeConflict false"

WARNING: shazam failed, if due to conflict, please resolve and re-run command.
$ # fix conflict
$ git am --continue
$ review-get
...
Unable to find revision 1
b4 cannot find version 1, deleting branch 'review/procmap_query-v1'
Deleted branch review/procmap_query-v1 (was c617a4dd7102).
$ git branch | grep review
  review/procmap_query-v2
  review/procmap_query-v3
* review/procmap_query-v4
```

Now all versions of the series, apart from the one b4 can't find (v1) are in
branches.

```
$ review-diff procmap_query
```

![screenshot of side-by-side ranged diff](screenshot_diff.png)

Now I can check that all patches in the latest revision pass checkpatch.pl:

```
$ review-checkpatch procmap_query
--- retrieving data for [procmap_query]... ---
Grabbing thread from lore.kernel.org/all/20250804231552.1217132-1-surenb@google.com/t.mbox.gz
Checking for newer revisions
Grabbing search results from lore.kernel.org
  Added from v3: 4 patches
  Added from v4: 4 patches
23 messages in the thread
Saved /tmp/tmp.DNbDXaXVd5/review-procmap_query.mbx
--- ...retrieving data for [procmap_query] ---
Analyzing 23 messages in the thread
Looking for additional code-review trailers on lore.kernel.org
Analyzing 9 code-review messages
Checking attestation on all messages, may take a moment...
---
  [PATCH v4 1/3] selftests/proc: test PROCMAP_QUERY ioctl while vma is concurrently modified
    ● checkpatch.pl: passed all checks
  [PATCH v4 2/3] fs/proc/task_mmu: factor out proc_maps_private fields used by PROCMAP_QUERY
    ● checkpatch.pl: passed all checks
  [PATCH v4 3/3] fs/proc/task_mmu: execute PROCMAP_QUERY ioctl under per-vma locks
    + Reviewed-by: Vlastimil Babka <vbabka@suse.cz>
    ● checkpatch.pl: passed all checks
  ---
  NOTE: install dkimpy for DKIM signature verification
---
Total patches: 3
---
Cover: ./v4_20250808_surenb_execute_procmap_query_ioctl_under_per_vma_lock.cover
 Link: https://lore.kernel.org/r/20250808152850.2580887-1-surenb@google.com
 Base: using specified base-commit c2144e09b922d422346a44d72b674bf61dbd84c0
       git checkout -b v4_20250808_surenb_google_com c2144e09b922d422346a44d72b674bf61dbd84c0
       git am ./v4_20250808_surenb_execute_procmap_query_ioctl_under_per_vma_lock.mbx
```

Build test every commit in latest revision:

```
$ review-check procmap_query
<kernel build automatically performed for every commit in series>
```

Read all mails in the thread:

```
$ review-read procmap_query
```

![screenshot of reading mail direct](screenshot_read.png)

Run all the mm self-tests at the latest version:

```
$ review-check-mm-tests
< test results >
```
