#!/usr/bin/env bash
# YAPF formatter, adapted from ray.
#
# Usage:
#    # Do work and commit your work.

#    # Format files that differ from origin/master.
#    bash format.sh

#    # Commit changed files with message 'Run yapf and pylint'
#
#
# YAPF + Clang formatter (if installed). This script formats all changed files from the last mergebase.
# You are encouraged to run this locally before pushing changes for review.

# Cause the script to exit if a single command fails
set -eo pipefail

# this stops git rev-parse from failing if we run this from the .git directory
builtin cd "$(dirname "${BASH_SOURCE:-$0}")"
ROOT="$(git rev-parse --show-toplevel)"
builtin cd "$ROOT" || exit 1

YAPF_VERSION=$(yapf --version | awk '{print $2}')
PYLINT_VERSION=$(pylint --version | head -n 1 | awk '{print $2}')
PYLINT_QUOTES_VERSION=$(pip list | grep pylint-quotes | awk '{print $2}')
MYPY_VERSION=$(mypy --version | awk '{print $2}')
BLACK_VERSION=$(black --version | head -n 1 | awk '{print $2}')

# # params: tool name, tool version, required version
tool_version_check() {
    if [[ $2 != $3 ]]; then
        echo "Wrong $1 version installed: $3 is required, not $2."
        exit 1
    fi
}

tool_version_check "yapf" $YAPF_VERSION "$(grep yapf requirements-dev.txt | cut -d'=' -f3)"
tool_version_check "pylint" $PYLINT_VERSION "$(grep "pylint==" requirements-dev.txt | cut -d'=' -f3)"
tool_version_check "pylint-quotes" $PYLINT_QUOTES_VERSION "$(grep "pylint-quotes==" requirements-dev.txt | cut -d'=' -f3)"
tool_version_check "mypy" "$MYPY_VERSION" "$(grep mypy requirements-dev.txt | cut -d'=' -f3)"
tool_version_check "black" "$BLACK_VERSION" "$(grep black requirements-dev.txt | cut -d'=' -f3)"

YAPF_FLAGS=(
    '--recursive'
    '--parallel'
)

YAPF_EXCLUDES=(
    '--exclude' 'build/**'
    '--exclude' 'sky/skylet/providers/ibm/**'
)

ISORT_YAPF_EXCLUDES=(
    '--sg' 'build/**'
    '--sg' 'sky/skylet/providers/ibm/**'
)

BLACK_INCLUDES=(
    'sky/skylet/providers/ibm'
)

PYLINT_FLAGS=(
    '--load-plugins'  'pylint_quotes'
)

# Format specified files
format() {
    yapf --in-place "${YAPF_FLAGS[@]}" "$@"
}

# Format files that differ from main branch. Ignores dirs that are not slated
# for autoformat yet.
format_changed() {
    # The `if` guard ensures that the list of filenames is not empty, which
    # could cause yapf to receive 0 positional arguments, making it hang
    # waiting for STDIN.
    #
    # `diff-filter=ACM` and $MERGEBASE is to ensure we only format files that
    # exist on both branches.
    MERGEBASE="$(git merge-base origin/master HEAD)"

    if ! git diff --diff-filter=ACM --quiet --exit-code "$MERGEBASE" -- '*.py' '*.pyi' &>/dev/null; then
        git diff --name-only --diff-filter=ACM "$MERGEBASE" -- '*.py' '*.pyi' | \
            tr '\n' '\0' | xargs -P 5 -0 \
            yapf --in-place "${YAPF_EXCLUDES[@]}" "${YAPF_FLAGS[@]}"
    fi

}

# Format all files
format_all() {
    yapf --in-place "${YAPF_FLAGS[@]}" "${YAPF_EXCLUDES[@]}" sky tests examples llm
}

echo 'SkyPilot Black:'
black "${BLACK_INCLUDES[@]}"

## This flag formats individual files. --files *must* be the first command line
## arg to use this option.
if [[ "$1" == '--files' ]]; then
   format "${@:2}"
   # If `--all` is passed, then any further arguments are ignored and the
   # entire python directory is formatted.
elif [[ "$1" == '--all' ]]; then
   format_all
else
   # Format only the files that changed in last commit.
   format_changed
fi
echo 'SkyPilot yapf: Done'

echo 'SkyPilot isort:'
isort sky tests examples llm docs "${ISORT_YAPF_EXCLUDES[@]}"

isort --profile black -l 88 -m 3 "sky/skylet/providers/ibm"


# Run mypy
# TODO(zhwu): When more of the codebase is typed properly, the mypy flags
# should be set to do a more stringent check.
echo 'SkyPilot mypy:'
mypy $(cat tests/mypy_files.txt)

# Run Pylint
echo 'Sky Pylint:'
if [[ "$1" == '--files' ]]; then
    # If --files is passed, filter to files within sky/ and examples/ and pass to pylint.
    pylint "${PYLINT_FLAGS[@]}" "${@:2}"
elif [[ "$1" == '--all' ]]; then
    # Pylint entire sky and examples directories.
    pylint "${PYLINT_FLAGS[@]}" sky examples
else
    # Pylint only files in sky/ and examples/ that have changed in last commit.
    changed_files=$(git diff --name-only --diff-filter=ACM "$MERGEBASE" -- 'sky/*.py' 'sky/*.pyi' 'examples/*.py' 'examples/*.pyi')
    if [[ -n "$changed_files" ]]; then
        echo "$changed_files" | tr '\n' '\0' | xargs -0 pylint "${PYLINT_FLAGS[@]}"
    else
        echo 'Pylint skipped: no files changed in sky/.'
    fi
fi

# Lint and format the dashboard
echo "SkyPilot Dashboard linting and formatting:"
if ! npm -v || ! node -v; then
    echo "npm or node is not installed, please install them first"
    # Don't fail the script if npm or node is not installed
    # because it's not required for all users
else
    npm --prefix sky/dashboard install
    npm --prefix sky/dashboard run lint
    npm --prefix sky/dashboard run format
    echo "SkyPilot Dashboard linting and formatting: Done"
    echo
fi

if ! git diff --quiet &>/dev/null; then
    echo 'Reformatted files. Please review and stage the changes.'
    echo 'Changes not staged for commit:'
    echo
    git --no-pager diff --name-only

    exit 1
fi
