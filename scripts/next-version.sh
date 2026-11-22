#!/usr/bin/env bash
# Print the version the next release gets: <major>.<minor>.<patch>.
#
# <major>.<minor> comes from the VERSION file; edit that file to bump it.
# <patch> is chosen here: one more than the highest existing git tag
# v<major>.<minor>.<patch>, or 0 if there is none yet. CI calls this for
# every release; see docs/development.md.
set -euo pipefail
cd "$(dirname "$0")/.."  # run from the repository root

base="$(tr -d '[:space:]' <VERSION)"
if [[ ! "$base" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain <major>.<minor>, found '$base'" >&2
    exit 1
fi

next=0
while read -r tag; do
    # Only exact v<base>.<number> tags count; anything else is ignored.
    [[ "$tag" == "v$base."* ]] || continue
    patch="${tag#"v$base."}"
    [[ "$patch" =~ ^[0-9]+$ ]] || continue
    ((10#$patch >= next)) && next=$((10#$patch + 1))
done < <(git tag --list)
echo "$base.$next"
