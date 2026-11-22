#!/usr/bin/env bash
# Test scripts/next-version.sh against a throwaway git repository.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/next-version.sh"

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
mkdir "$repo/scripts"
cp "$script" "$repo/scripts/"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
    commit -q --allow-empty -m init

failures=0
# expect <VERSION contents> <expected output> [tags...]
expect() {
    local base="$1" want="$2" got
    shift 2
    git -C "$repo" tag --list | xargs -r git -C "$repo" tag -d >/dev/null
    for t in "$@"; do git -C "$repo" tag "$t"; done
    printf '%s\n' "$base" >"$repo/VERSION"
    got="$(bash "$repo/scripts/next-version.sh" 2>&1)" || got="error"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: VERSION=$base tags=[$*]: got '$got', want '$want'" >&2
        failures=$((failures + 1))
    fi
}

expect 0.1 0.1.0                                  # no tags yet
expect 0.1 0.1.1 v0.1.0
expect 0.1 0.1.11 v0.1.0 v0.1.9 v0.1.10           # numeric, not alphabetic, order
expect 0.2 0.2.0 v0.1.0 v0.1.7                    # bumped base starts at 0
expect 0.1 0.1.3 v0.1.2 v0.10.5 v0.11.9 v1.0.1.0  # other series don't count
expect 0.1 0.1.1 v0.1.0 v0.1.x v0.1.2-rc1 nightly # malformed tags are ignored
expect 1.0 1.0.1 v1.0.0 v10.0.5
expect 0.1 0.1.9 v0.1.08                          # leading zero is not octal
expect banana error
expect 0.1.2 error

if ((failures)); then exit 1; fi
echo "next-version tests passed"
