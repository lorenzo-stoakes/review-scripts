#!/bin/bash
set -e; set -o pipefail

# Courtesty of https://stackoverflow.com/a/246128
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function say()
{
	echo -e "$@" >&2
}

function fatal()
{
	say "$@"
	exit 1
}

function error()
{
	fatal "ERROR: $@"
}

function warn()
{
	say "WARNING: $@"
}

function usage()
{
	fatal "usage: $(basename $0) $@"
}

function rev_exists()
{
	git rev-parse --verify -q $1 >/dev/null
}

function tree_clean()
{
	git diff-index --quiet HEAD --
}

function get_ref()
{
	local ref=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires ref parameter"
	fi

	git rev-parse --abbrev-ref $ref
}

function get_ref_hash()
{
	git rev-parse $1
}

function get_branch()
{
	local ref=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires ref parameter"
	fi

	hash=$(get_ref_hash $ref)

	# The points-at gets the tag, then dereferences the tag to a commit hash
	# with ^{commit}, then looks up the branch in refs/heads/.
	git for-each-ref --format='%(refname:short)' \
	    --points-at "$hash^{commit}" refs/heads/ 2>/dev/null | head -1
}

# Look up a branch name from a specified ref. If one exists there, output that,
# otherwise output the tag.
#
# Params:
#	$1 - ref name.
function ref_to_maybe_branch()
{
	local ref=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires ref parameter"
	fi

	branch=$(get_branch $ref)
	if [[ -n "$branch" ]]; then
		echo $branch
	else
		echo $ref
	fi
}

function get_curr_ref()
{
	get_ref HEAD
}

function show_rev_summary()
{
	git --no-pager log --oneline -n1
}

# Retrieve the contents of the tag's message.
#
# Params:
#	$1 - tag name.
function get_tag_msg()
{
	local tag=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires tag parameter"
	fi

	git tag -ln $tag | awk '{print $2}'
}

# Pushes directory onto pushd stack without outputting anything.
#
# Params:
# 	$1 - directory to add to pushd stack.
function push()
{
	pushd $1 >/dev/null
}

# Pops directory off pushd stack without outputting anything.
function pop()
{
	popd &>/dev/null || true
}

# Is this a kernel directory?
function is_kernel_dir()
{
	[[ -e MAINTAINERS ]]
}

# Traverse to root of kernel directory tree. pop will restore previous
# directory.
function push_kernel_root_dir()
{
	push .

	while [[ $PWD != "/" ]] && ! is_kernel_dir; do
		cd ..
	done

	if [[ $PWD == "/" ]]; then
		error "not in a kernel tree"
	fi
}

# Check if environment is sane for review commands in general, and enter the
# root of the kernel directory if we are indeed in one.
function check_prep()
{
	push_kernel_root_dir

	if ! tree_clean; then
		error "changes in tree, aborting"
	fi
}

# Create a temporary directory, and set a trap so it is always cleaned up.
# Outputs the temporary directory name.
function get_temp_dir()
{
	local tmpdir="$(mktemp -d)"

	# Just in case, as we are about to rm -f $tmpdir/*
	if [[ -z "$tmpdir" ]]; then
		error "empty temporary directory??"
	fi

	echo "$tmpdir"
}

# Clean up the directory on exit. Assumes no subdirectories, so we can delete
# safely.
#
# Params:
#	$1 - name of directory to clean up on exit.
function cleanup_dir_on_exit()
{
	local dir=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires dir parameter"
	fi

	if [[ -z "$dir" ]]; then
		error "empty directory specified"
	fi

	if ! [[ -d "$dir" ]]; then
		error "directory '$dir' does not exist"
	fi

	# Ensure we clean up after ourselves.
	# We avoid rm -rf in case for safety.
	trap "rm -f $dir/*; rmdir $dir" EXIT
}

# Get the tag name used to figure out the base commit for this review.
#
# Params:
#	$1 - the name given to the review.
function get_review_tag()
{
	local name=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires name parameter"
	fi

	echo "review-$name-base"
}

# Retrieve the msgid we stored for the review.
#
# Params:
#	$1 - the name given to the review.
function get_review_msgid()
{
	local name=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires name parameter"
	fi

	local tag="$(get_review_tag $name)"
	get_tag_msg $tag
}

# Determine the name we assign to the downloaded mbox based on review name.
#
# Params:
#	$1 - the name given to this review.
function get_mbox_filename()
{
	local name=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires name parameter"
	fi

	echo "review-$name.mbx"
}

# Retrieve the mbox for the specified msgid including all revisions and store in
# the specified temporary directory.
#
# Params:
#	$1 - the name given to this review.
#	$2 - msgid to retrieve.
#	$3 - dir to put it in.
#	$4 - try to be vaguely quiet (optional).
#
# Outputs path to mbox on exit.
function retrieve_mbox()
{
	local name="$1"
	local msgid=$2
	local dir=$3
	local quiet=$4

	if [[ $# -lt 3 ]]; then
		error "$FUNCNAME() requires name, msgid, dir parameters"
	fi

	local mbox_filename="$(get_mbox_filename $name)"

	# It's noisy anyway, so add prefix/suffix.
	if [[ -z "$quiet" ]]; then
		echo "--- retrieving data for [$name]... ---" >&2
		b4 mbox -c $msgid -o $dir -n ${mbox_filename}
	else
		b4 -q mbox -c  $msgid -o $dir -n ${mbox_filename}
	fi

	if [[ -z "$quiet" ]]; then
		echo "--- ...retrieving data for [$name] ---" >&2
	fi

	echo "$dir/${mbox_filename}"
}

__latest_revision_regex="\[PATCH.*\]|\[PATCH RFC.+\]|\[RFC PATCH.+\]|\[RFC.+\]"

function __get_latest_revision()
{
	local mbox_path=$1

	# The below won't retrieve v1, so we must wrap this operation.

	# A bit horrible, but does the job...
	grep -Ei "${__latest_revision_regex}" ${mbox_path} | \
		grep -Eio 'v[0-9]+' | \
		sed -nE 's/v([0-9]+)/\1/pi' | \
		sort -nr | \
		head -n1
}

# Figure out the latest revision number from an mbox of all revisions.
#
# Params:
#	$1 - path to the mbox file.
#
# Outputs the latest revision as an integer.
function get_latest_revision()
{
	local mbox_path=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires mbox path"
	fi

	revision="$(__get_latest_revision ${mbox_path})"
	if [[ -z "$revision" ]]; then
		# OK this could be v1.
		if grep -Eqi "${__latest_revision_regex}" "${mbox_path}"; then
			revision=1
		else
			error "Cannot determine revision in '${mbox_path}'"
		fi
	fi

	echo $revision
}

# Get the branch name used for review.
#
# Params:
# 	$1 - the name given to the review.
#	$2 - the version number.
function get_review_branch()
{
	local name=$1
	local ver=$2

	if [[ $# -lt 2 ]]; then
		error "$FUNCNAME() requires name, version parameters"
	fi

	echo "review/$name-v$ver"
}

# b4 shazam the specified version of the series into the current branch.
#
# Params:
#	$1 - the revision the user was previously on.
#	$2 - the path to the mbox containing the series-es.
#	$3 - the version to shazam.
function shazam_at_version()
{
	local prev_rev=$1
	local mbox_path=$2
	local ver=$3

	if [[ $# -lt 3 ]]; then
		error "$FUNCNAME() requires prev_rev, mbox path, version parameters"
	fi

	# b4 doesn't give an exit status
	# and... not return an error code. Let's pipe its output into a
	# temporary file so we can figure out if this happens.
	tmpfile=$(mktemp)

	# Highly recommended to set am.threeWay for this.

	say "--- apply patches for [$name] at version [$ver]..."
	if ! b4 shazam -m "${mbox_path}" -v $ver 2>&1 | tee $tmpfile >&2; then
		echo >&2 # Extra line to separate out from noise.
		warn "shazam failed, if due to conflict, please resolve and re-run command"
		rm $tmpfile
		exit 1
	fi
	say "--- ...apply patches for [$name] at version [$ver]"

	# Anyway this at least means we can ignore these cases.
	if grep -q "Unable to find revision" $tmpfile; then
		branch=$(get_curr_ref)
		say "b4 cannot find version $ver, deleting branch '$branch'"
		git checkout -q $prev_rev
		git branch -D $branch
	fi

	rm $tmpfile
}

# Retrieve all review branches belong to a given review name.
#
# Params:
#	$1 - the name given to the review.
function get_review_branches()
{
	local name=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires name parameter"
	fi

	git for-each-ref --format='%(refname:short)' refs/heads/ | \
		grep -E "^review/$name-v[0-9]+$"
}

# Clear down review branches for specified name.
#
# Params:
#	$1 - the name given to the review.
#	$2 - ref to return to should we find ourselves on a review branch
function clear_review_branches()
{
	local name=$1
	local return_branch=$2

	if [[ $# -lt 2 ]]; then
		error "$FUNCNAME() requires name, return_branch parameters"
	fi
	return_branch="$(ref_to_maybe_branch $return_branch)"

	local branches="$(get_review_branches $name)"
	# If we're on one of the review branches, need to move off.
	if [[ $branches =~ "$(get_curr_ref)" ]]; then
		if rev_exists $return_branch; then
			git checkout -q $return_branch
		fi
	fi

	if [[ -n "$branches" ]]; then
		git branch -Df $branches
	else
		true
	fi
}

# Determine if the review has started or not.
#
# Params:
#	$1 - the name given to the review.
function has_review_started()
{
	local name=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires name parameter"
	fi

	local tag="$(get_review_tag $name)"

	rev_exists $tag
}

# Extract an mbox from a larger mbox at a specific version.
#
# Params:
# 	$1 - larger mbox path.
#	$2 - directory to place files in.
#	$3 - filename for extracted mbox.
#	$4 - version to extract.
#
# Outputs the path of the mbox file.
function extract_version_mbox()
{
	local mbox_path=$1
	local dir=$2
	local filename=$3
	local version=$4

	if [[ $# -lt 4 ]]; then
		error "$FUNCNAME() requires mbox_path, dir, filename, version parameters"
	fi

	say "--- extracting mbox at version [$version]..."
	b4 -q am -m "${mbox_path}" -o "$dir" -n "${filename}" -v $version
	say "--- ..extracting mbox at version [$version]"

	echo "$dir/$filename"
}

# Extract the git range-diff command b4 diff _would_ use if -n weren't
# specified, then outputs its parameters.
#
# Params:
#	$1 - the path of the mbox containing the previous version.
#	$2 - the path of the mbox containing the current version.
#
# Outputs git range-diff parameters.
function get_range_diff_params()
{
	local prev_path=$1
	local curr_path=$2

	if [[ $# -lt 2 ]]; then
		error "$FUNCNAME() requires prev_path, curr_path parameters"
	fi

	# b4 outputs this to stderr so have to fiddle around here. We use tee as
	# errors might occur too and we want them displayed.
	tmpfile=$(mktemp)
	b4 diff -n -m "${prev_path}" "${curr_path}" 2>&1 | tee $tmpfile >&2

	# Retrieve the final line containing the command and trim whitespace.
	output=$(tail -n1 $tmpfile | awk '{$1=$1};1' | sed 's/git range-diff //')
	rm $tmpfile

	if [[ $output =~ "Could" ]]; then
		echo ""
	else
		echo $output
	fi
}

# Used to make the git range-diff command 'fancy' - customise if needed.
function __fancy_range_diff()
{
	# We lose line numbers unfortunately.
	git -c pager.range-diff='
        git-range-diff-delta-preproc \
        | delta \
                --side-by-side \
                --file-style=omit \
                --line-numbers-left-format="" \
                --line-numbers-right-format="│ " \
                --hunk-header-style=syntax \
        ' range-diff $@
}

# Perform a fancy looking side-by-side ranged diff of the
#
# Params:
#	$1 - the path of the mbox containing the previous version.
#	$2 - the path of the mbox containing the current version.
function fancy_range_diff_b4()
{
	local prev_path=$1
	local curr_path=$2

	if [[ $# -lt 2 ]]; then
		error "$FUNCNAME() requires prev_path, curr_path parameters"
	fi

	# We have to hack a bit here - we can't tell b4 to use a specific pager,
	# so instead get it to tell us the git range-diff command, which we
	# extract then adjust to do what we want.
	local params=$(get_range_diff_params "${prev_path}" "${curr_path}")

	if [[ -n "$params" ]]; then
		__fancy_range_diff $params
	else
		return 1
	fi
}

# Perform a ranged diff across two separate larger mboxes at different versions.
# A larger mbox can contain multiple versions.
#
# Params:
#	$1 - the name given to the previous series review.
#	$2 - the name given to the current series review.
#	$3 - the path of the mbox containing the previous series to compare.
#	$4 - the path of the mbox containing the current series to compare.
#	$5 - the temporary directory in which to store files.
#	$6 - the version of the previous series to compare.
#	$7 - the version of the current series to compare.
function review_range_diff()
{
	local prev_name=$1
	local curr_name=$2
	local prev_mbox_path=$3
	local curr_mbox_path=$4
	local tmpdir=$5
	local prev_version=$6
	local curr_version=$7

	if [[ $# -lt 7 ]]; then
		error "$FUNCNAME() requires prev_name, curr_name, prev_mbox_path, curr_mbox_path, tmpdir, prev_version, curr_version parameters"
	fi

	local prev_branch=$(get_review_branch $prev_name $prev_version)
	if ! rev_exists $prev_branch; then
		error "Cannot find branch '${prev_branch}' for '${prev_name}' at version ${prev_version}"
	fi

	local curr_branch=$(get_review_branch $curr_name $curr_version)
	if ! rev_exists $curr_branch; then
		error "Cannot find branch '${curr_branch}' for '${curr_name}' at version ${curr_version}"
	fi

	local prev_filename="review-${prev_name}-v${prev_version}.mbx"
	local curr_filename="review-${curr_name}-v${curr_version}.mbx"

	local could_use_b4="yes"
	local prev_path
	local curr_path

	if [[ "${prev_mbox_path}" == "stub" ]] || [[ "${curr_mbox_path}" == "stub" ]]; then
		could_use_b4="no"
	else
		prev_path=$(extract_version_mbox "${prev_mbox_path}" "$tmpdir" "${prev_filename}" "${prev_version}")
		curr_path=$(extract_version_mbox "${curr_mbox_path}" "$tmpdir" "${curr_filename}" "${curr_version}")
	fi

	if [[ "${could_use_b4}" == "no" ]] || ! fancy_range_diff_b4 "${prev_path}" "${curr_path}"; then
		warn "Unable to use b4 diff to perform range-diff, trying to use local review branches"

		local prev_tag="$(get_review_tag ${prev_name})"
		local curr_tag="$(get_review_tag ${curr_name})"
		local prev_hash="$(get_ref_hash $prev_tag)"
		local curr_hash="$(get_ref_hash $prev_tag)"
		if [[ "$prev_hash" != "$curr_hash" ]]; then
			warn "bases differ, this may be broken"
		fi

		__fancy_range_diff ${prev_tag}..${prev_branch} ${curr_tag}..${curr_branch}
	fi
}

function checkpatch_range()
{
	local mbox_path=$1
	local version=$2

	if [[ $# -lt 2 ]]; then
		error "$FUNCNAME() requires mbox_path, version parameters"
	fi

	# b4 won't return an error if checkpatch fails, so we have to manually
	# pick this up, so put stderr into temporary logfile for us to grep.
	tmpfile=$(mktemp)

	if ! b4 am -k -m "${mbox_path}" -v ${version} -o - 2>&1 >/dev/null | tee $tmpfile >&2; then
		rm $tmpfile
		exit 1
	fi

	fail=""
	# Hack - we lock for the unicode char indicating an error.
	if grep "●" $tmpfile | grep -qE 'WARNING|ERROR'; then
		fail="fail"
	fi

	rm $tmpfile
	if [[ -n "$fail" ]]; then
		exit 1
	else
		exit 0
	fi
}

function build_run_vma_tests()
{
	push tools/testing/vma
	make clean
	make -j $(nproc)
	./vma
	pop
}

function build_mm_tests()
{
	push tools/testing/selftests/mm
	make clean
	make -j $(nproc)
	pop
}

# Run with sensible defaults that work for mm-tests.
function vng_run()
{
	vng --overlay-rwdir /mnt -m 4G -p 2 \
	    --append "nokaslr" \
	    --append "no_hash_pointers" $@
}

function vng_run_debug()
{
	vng_run -v  \
		--append "panic_on_warn=1" \
		--append "panic_on_oops=1" $@
}

function __run_mm_tests()
{
	# Execute the tests using virtme-ng. We use the overlay rwdir for some
	# of the hugetlb tests that need access to /mnt.
	vng_run_debug --cwd tools/testing/selftests/mm \
		      ${script_dir}/hooks/mm-tests
}

# Execute mm tests using virtme-ng.
function run_mm_tests()
{
	tmpfile=$(mktemp)
	(__run_mm_tests 2>&1 || true) | tee $tmpfile
	# For some reason the mm tests given an exit code even if FAIL=0 so
	# account for this. Sometimes it gives no exit code with FAIL>0. Go
	# figure. Either way, we have to figure this out ourselves.
	if ! grep "^# SUMMARY:" $tmpfile | grep -q "FAIL=0"; then
		say # Add space.
		say "--- not ok output..."
		grep "not ok" $tmpfile >&2
		say "-- ...not ok output --"
		rm $tmpfile
		exit 1
	fi

	rm $tmpfile
}

# Extract patches from an mbox from a larger mbox at a specific version.
#
# Params:
# 	$1 - larger mbox path.
#	$2 - directory to place files in.
#	$3 - temporary directory to extract to.
#	$4 - version to extract.
#
# Outputs the path of the mbox file.
function extract_mbox_patches()
{
	local mbox_path=$1
	local dir=$2
	local tmpdir=$3
	local version=$4

	if [[ $# -lt 4 ]]; then
		error "$FUNCNAME() requires mbox_path, dir, tmpdir, version parameters"
	fi

	say "--- retrieving patches for [$name]..."
	b4 -q am -M -m "${mbox_path}" -o "$tmpdir" -n "mail" -v $version --no-cover
	say "--- ...retrieving patches for [$name]"

	mailpath="$tmpdir/mail.maildir"
	for file in $mailpath/new/*.eml; do
		mv "$file" "$dir/$(basename ${file%.eml}).patch"
	done
	rmdir $mailpath/new
	rmdir $mailpath/cur
	rmdir $mailpath/tmp
	rmdir $mailpath
}

# Check whether a given series may have already been applied by grepping commits
# for a reference to that msgid (typically included in a Link tag).
#
# Params:
#	$1 - msgid of series.
function check_already_applied()
{
	local msgid=$1
	local head=$2

	if [[ $# -lt 2 ]]; then
		error "$FUNCNAME() requires msgid, head parameters"
	fi

	found=$(git --no-pager log --oneline HEAD~1000..HEAD --grep="$msgid" -n1 $head)

	if [[ -n "$found" ]]; then
		say "$found"
		error "Found specified msgid in tree, run review-start-applied instead"
	fi
}

# Generate temporary 8 character word.
function gen_temp_word()
{
	cat /dev/urandom | tr -cd 'a-z0-9' | head -c 8 || true
}

# Is this a valid msgid, or is this a stub entry for an off-list series?
#
# Params:
#	$1 - msgid of series.
function is_valid_msgid()
{
	local msgid=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires msgid parameter"
	fi

	[[ "$msgid" != "stub" ]]
}

# Manually checkpatch a series using the local script.
#
# Params:
#	$1 - the name given to the series review.
function checkpatch_range_manual()
{
	local name=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires name parameter"
	fi

	# TODO
}

# Perform a build for every commit in the specified range.
#
# Params:
#	$1 - config script to use in hooks/ directory.
#	$2 - the commit from which we should build, inclusively.
#	$3 - the commit to which we should build, inclusively.
#	$@ - (remaining params, optional) - parameters to pass to make command.
function do_per_commit_build()
{
	local config=$1
	local from=$2
	local to=$3

	if [[ $# -lt 3 ]]; then
		error "$FUNCNAME() requires config, from, to parameters"
	fi

	# Shift other parameter so we can pass parameters to the build.
	shift 3

	echo "---- BUILDING using $config... ----"

	git checkout -q $to
	make clean
	${script_dir}/hooks/$config

	cmd="review-mk $@"
	git rebase --exec "$cmd" $from

	echo "---- BUILD using $config succeeded :) ----"
}

function __get_arm64_prefix()
{
	echo "aarch64-linux-gnu-"
}

function __get_riscv_prefix()
{
	echo "riscv64-linux-gnu-"
}

# Determine the compiler collection prefix to use for specified arch.
#
# Params:
#	$1 - the architecture we want the prefix for.
function get_compiler_prefix()
{
	local arch=$1
	local cmd="__get_${arch}_prefix"
	local prefix=$($cmd)

	echo $prefix
}

# Determine if we have a compiler collection for specified arch.
#
# Params:
#	$1 - the architecture we wish to check for.
function has_compiler()
{
	local arch=$1
	local prefix=$(get_compiler_prefix $arch)

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires arch parameter"
	fi

	which ${prefix}gcc &>/dev/null
}

# Assert that we have a compiler collection for specified arch.
#
# Params:
#	$1 - the architecture we wish to check for.
function assert_has_compiler()
{
	local arch=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires arch parameter"
	fi

	if ! has_compiler $arch; then
		error "Cannot find $arch compiler tools with prefix $prefix"
		exit 1
	fi
}

# Determine the kernel build options to pass to make for cross-compilation of a
# specified architecture.
#
# Params:
#	$1 - the architecture we want to build for.
function get_arch_make_opts()
{
	local arch=$1

	if [[ $# -lt 1 ]]; then
		error "$FUNCNAME() requires arch parameter"
	fi

	assert_has_compiler $arch
	local prefix=$(get_compiler_prefix $arch)

	echo "ARCH=$arch CROSS_COMPILE=$prefix"
}

# Simply drop all module options from kernel config.
function config_disable_modules()
{
	make $@ mod2noconfig || true
}
