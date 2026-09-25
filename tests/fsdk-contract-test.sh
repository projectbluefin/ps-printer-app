#!/usr/bin/env bash
#
# Regression test for tests/fsdk-contract.sh.
#
# A contract check that never fails is not a check, and the invariants it
# guards are only broken by mistakes no one makes on purpose. So every check is
# exercised twice here: once against this repository's real graph, which has to
# pass, and once against a scratch copy of it with one invariant broken, which
# has to fail with the expected message.
#
# No BuildStream, no container runtime and no network: the graph checks are fed
# the element list `bst show --format '%{name}'` would print.
#
# Usage: tests/fsdk-contract-test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
check="$script_dir/fsdk-contract.sh"

scratch=""
tree=""

cleanup() {
  [[ -n "$scratch" ]] && rm -rf "$scratch"
}
trap cleanup EXIT
scratch="$(mktemp -d)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A scratch copy of everything the checker reads, with the checker in it.
new_tree() {
  rm -rf "$scratch/tree"
  mkdir -p "$scratch/tree/tests"
  cp -a "$repo_root/elements" "$repo_root/patches" "$scratch/tree/"
  cp -a "$repo_root/rockcraft.yaml" "$repo_root/snap" "$scratch/tree/"
  cp "$check" "$scratch/tree/tests/"
  tree="$scratch/tree"
}

# The element list the printing base gives the resolved graph. `--deps all` is
# a set, so the checks below are about which elements are in the closure and
# where they come from, not how often they are reached.
cat >"$scratch/graph" <<'GRAPH'
oci/ps-printer-app.bst
printer-app/application.bst
printer-app/core-runtime.bst
printer-app/core-stack.bst
printer-app/foomatic-ps-ppds.bst
printer-app/hplip-ps.bst
printer-app/pyppd.bst
printer-app/runtime-files.bst
printer-app/version.bst
fsdk-containers.bst:printing/base.bst
fsdk-containers.bst:printing/foomatic-db.bst
fsdk-containers.bst:printing/pappl.bst
fsdk-containers.bst:printing/pappl-retrofit.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/cups-daemon-only.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/cups-filters.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/libcupsfilters.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/libppd.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/ghostscript.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/avahi-printing.bst
fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
fsdk-containers.bst:freedesktop-sdk.bst:components/python3.bst
GRAPH

# expect_pass DESCRIPTION [COMMAND...]
expect_pass() {
  local description="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$description should have passed"
  fi
  echo "  ok: $description"
}

# expect_fail DESCRIPTION EXPECTED_MESSAGE [COMMAND...]
expect_fail() {
  local description="$1" expected="$2"
  shift 2
  local output status=0
  output="$("$@" 2>&1)" || status=$?
  if ((status == 0)); then
    fail "$description should have failed but passed"
  fi
  if ! grep -qF -- "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "$description failed without saying why (expected: $expected)"
  fi
  echo "  ok: $description"
}

echo "== The real graph holds the contract =="
expect_pass 'this repository passes its own contract check' "$check"
expect_pass 'the resolved graph has one CUPS owner' "$check" --graph "$scratch/graph"
expect_pass 'the graph is accepted on stdin' bash -c "'$check' --graph - < '$scratch/graph'"

echo "== Broken declarations are rejected =="
new_tree

# A second FSDK junction would be a second CUPS.
cat >"$tree/elements/freedesktop-sdk.bst" <<'ELEMENT'
kind: junction

sources:
  - kind: git_repo
    url: gitlab:freedesktop-sdk/freedesktop-sdk.git
    track: freedesktop-sdk-26.08*
    ref: freedesktop-sdk-26.08rc.1-0-ge076d4978ee6945763486f6ebd755d189460e4e7
ELEMENT
expect_fail 'a second FSDK junction is rejected' 'junctions FSDK itself' "$tree/tests/fsdk-contract.sh"
rm "$tree/elements/freedesktop-sdk.bst"

# FSDK reached without the junction prefix is the same second CUPS through the
# back door: it resolves against a different project, so different key.
printf '  - freedesktop-sdk.bst:components/cups-daemon-only.bst\n' >>"$tree/elements/printer-app/core-stack.bst"
expect_fail 'a direct FSDK reference is rejected' 'FSDK referenced outside the fsdk-containers junction' "$tree/tests/fsdk-contract.sh"
new_tree

# An unpinned junction tracks whatever upstream main is today.
sed -i 's/^\( *\)ref: 8a02f5e18b6d89c5558d2371212a5489e86c3ea2$/\1ref: main/' "$tree/elements/fsdk-containers.bst"
expect_fail 'an unpinned junction is rejected' 'does not pin the junction to a commit' "$tree/tests/fsdk-contract.sh"
new_tree

printf 'overrides:\n  printing/base.bst: ~\n' >>"$tree/elements/fsdk-containers.bst"
expect_fail 'an overridden printing base is rejected' 'overrides the printing base' "$tree/tests/fsdk-contract.sh"
new_tree

sed -i "s/^    arch: '%{arch}'$/    arch: '%{arch}'\n    strip-commands: ['true']/" "$tree/elements/fsdk-containers.bst"
expect_fail 'a junction option besides arch is rejected' "configures something besides arch" "$tree/tests/fsdk-contract.sh"
new_tree

sed -i "/^    ref: 8a02f5e18b6d89c5558d2371212a5489e86c3ea2$/a\\  - kind: patch_queue\n    path: patches/cups" \
  "$tree/elements/fsdk-containers.bst"
expect_fail 'a patch queue on the junction is rejected' 'queues patches' "$tree/tests/fsdk-contract.sh"
new_tree

sed -i "/^    ref: release-1-1-0-0-g29ccf6cf85781315a696774e7458a2f1f61aac57$/i\\  - kind: git_repo\n    url: github:OpenPrinting/other.git\n    track: main" \
  "$tree/elements/printer-app/pyppd.bst"
expect_fail 'a remote source with no ref is rejected' 'every source needs a pin' "$tree/tests/fsdk-contract.sh"
new_tree

# The mistake issue #37 and #39 were filed about: a floating track with no pin.
sed -i 's/^\( *\)ref: release-1-1-0-0-g29ccf6cf85781315a696774e7458a2f1f61aac57$/\1ref: release-1-1-0/' \
  "$tree/elements/printer-app/pyppd.bst"
expect_fail 'a git source pinned to a tag is rejected' 'commit pin(s)' "$tree/tests/fsdk-contract.sh"
new_tree

# A repository-owned CUPS element is a second copy of the same source.
printf 'kind: manual\n' >"$tree/elements/printer-app/cups.bst"
expect_fail 'a repository-owned CUPS element is rejected' 'repository-owned CUPS stack element' "$tree/tests/fsdk-contract.sh"
new_tree

# Staging a patch here duplicates the shared seam for the build graph.
printf '  - kind: patch_queue\n    path: patches/cups\n' >>"$tree/elements/printer-app/core-stack.bst"
expect_fail 'a locally staged patch is rejected' 'stages a local patch' "$tree/tests/fsdk-contract.sh"
new_tree

# A patch only Snap and Rock use, with no element and no legacy recipe behind it.
cp "$tree/patches/cups-dnssd-backend-socket-only.patch" "$tree/patches/cups-usb-quirk-dir.patch"
expect_fail 'an unowned patch file is rejected' 'neither referenced by the legacy Snap/Rock packaging' "$tree/tests/fsdk-contract.sh"
new_tree

# Without the exclude the devel stack's compiler and package manager ship.
sed -i '/^    - devel$/d' "$tree/elements/printer-app/core-runtime.bst"
expect_fail 'a runtime without the devel exclude is rejected' 'does not exclude the devel domain' "$tree/tests/fsdk-contract.sh"
new_tree

echo "== Broken graphs are rejected =="
# Each case gets its own copy of the resolved graph, so one broken graph cannot
# mask the next one.
graph_case=""
graph_with() {
  graph_case="$scratch/graph-case"
  cp "$scratch/graph" "$graph_case"
  printf '%s\n' "$1" >>"$graph_case"
}

grep -v '^fsdk-containers.bst:printing/base.bst$' "$scratch/graph" >"$scratch/graph-no-base"
expect_fail 'a graph without the printing base is rejected' 'does not stage fsdk-containers.bst:printing/base.bst' \
  "$check" --graph "$scratch/graph-no-base"

graph_with 'printer-app/cups.bst'
expect_fail 'a CUPS element of this repository is rejected' 'second CUPS owner' "$check" --graph "$graph_case"

graph_with 'freedesktop-sdk.bst:components/cups-daemon-only.bst'
expect_fail 'CUPS from a second FSDK junction is rejected' 'second CUPS owner' "$check" --graph "$graph_case"

graph_with 'fsdk-containers.bst:freedesktop-sdk.bst:components/avahi.bst'
expect_fail 'a duplicate avahi-daemon is rejected' 'components/avahi.bst is staged next to the base avahi-printing.bst' \
  "$check" --graph "$graph_case"

: >"$scratch/graph-empty"
expect_fail 'an empty graph is rejected' 'the resolved graph is empty' "$check" --graph "$scratch/graph-empty"

expect_fail 'a missing graph file is rejected' 'no such file' "$check" --graph "$scratch/graph-missing"

expect_fail 'a --graph without a file is rejected' '--graph needs a file or -' "$check" --graph
expect_fail 'an unknown argument is rejected' 'unknown argument' "$check" --bogus

printf 'PASS: every fsdk-containers contract check fails when its invariant is broken\n'