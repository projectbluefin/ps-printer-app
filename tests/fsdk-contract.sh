#!/usr/bin/env bash
#
# fsdk-containers printing-base consumer contract check.
#
# The image graph builds on fsdk-containers' shared printing base
# (`fsdk-containers.bst:printing/base.bst`), which is the one CUPS provider for
# every printer application. This repository has to hold up its end of the
# consumer contract in fsdk-containers `docs/skills/printing-base.md`: one
# junction, no patches and no `overrides` of its own, FSDK reached only through
# that junction, and a final OCI element composed from runtime domains only.
#
# Those rules are what make "one CUPS artifact owner" true
# (projectbluefin/ps-printer-app#2). They are checked here rather than assumed,
# because `just validate` on a pull request is otherwise the only gate that
# runs, and it builds nothing: a second CUPS owner would first show up as a
# duplicate in a full build, if at all.
#
# The declaration checks read this repository's own files and need no
# BuildStream, so they run anywhere. --graph adds the checks that need the
# resolved graph:
#
#   just bst show --deps all --format '%{name}' oci/ps-printer-app.bst
#
# Usage:
#   tests/fsdk-contract.sh                  # declarations only
#   tests/fsdk-contract.sh --graph FILE     # FILE, or - to read stdin
#
# tests/fsdk-contract-test.sh proves that each check below fails when the
# invariant it guards is broken.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

junction="elements/fsdk-containers.bst"
runtime="elements/printer-app/core-runtime.bst"
graph=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --graph)
      [[ -n "${2:-}" ]] || fail '--graph needs a file or -'
      graph="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (try --help)"
      ;;
  esac
done

mapfile -t elements < <(find elements -type f -name '*.bst' | sort)
[[ "${#elements[@]}" -gt 0 ]] ||
  fail "no elements under $(pwd)/elements; run this from the repository"

# --- One junction, pinned, with nothing added to it ------------------------
# A second FSDK junction would be a second CUPS.
for file in "${elements[@]}"; do
  [[ "$file" == "$junction" ]] && continue
  grep -qE '^[[:space:]]*kind:[[:space:]]*junction' "$file" || continue
  if grep -qE 'url:[^#]*freedesktop-sdk' "$file"; then
    fail "$file junctions FSDK itself; FSDK is reached through $junction only"
  fi
done

[[ -f "$junction" ]] || fail "$junction is missing; nothing junctions the printing base"

# FSDK may only be referenced as fsdk-containers.bst:freedesktop-sdk.bst:...
# anywhere in this repository's elements.
direct="$(grep -rnoE '[A-Za-z0-9_./:-]*freedesktop-sdk\.bst:' elements/ |
  grep -vE ':fsdk-containers\.bst:freedesktop-sdk\.bst:$' || true)"
[[ -z "$direct" ]] || {
  printf '%s\n' "$direct" >&2
  fail 'FSDK referenced outside the fsdk-containers junction'
}

ref="$(sed -n 's/^[[:space:]]*ref:[[:space:]]*//p' "$junction")"
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || fail "$junction does not pin the junction to a commit (ref: ${ref:-none})"
grep -qE 'url:[^#]*projectbluefin/fsdk-containers' "$junction" ||
  fail "$junction does not junction projectbluefin/fsdk-containers"
if grep -qE 'kind:[[:space:]]*patch_queue' "$junction"; then
  fail "$junction queues patches; the shared seam is fsdk-containers"
fi
if grep -qE '^[[:space:]]*overrides:' "$junction"; then
  fail "$junction overrides the printing base"
fi
# The junction config may carry no option besides the architecture.
mapfile -t junction_options < <(awk '/^config:/{inside=1;next} inside&&/^[^[:space:]]/{inside=0} inside' "$junction" |
  sed 's/#.*//' | sed '/^[[:space:]]*$/d' | sed 's/^[[:space:]]*//')
[[ "${#junction_options[@]}" == 2 && "${junction_options[0]}" == 'options:' &&
  "${junction_options[1]}" == "arch: '%{arch}'" ]] ||
  fail "$junction configures something besides arch: '%{arch}'"
echo '  ok: one FSDK junction, pinned to a commit, with no patches or overrides'

# --- Every remote source is pinned ----------------------------------------
# A `track:` without an immutable `ref:` compiles whatever upstream HEAD
# happens to be, which is not the revision this graph was reviewed with.
for file in "${elements[@]}"; do
  git_sources="$(grep -cE '^[[:space:]]*-[[:space:]]*kind: git_repo$' "$file" || true)"
  tar_sources="$(grep -cE '^[[:space:]]*-[[:space:]]*kind: tar$' "$file" || true)"
  refs="$(grep -cE '^[[:space:]]*ref: ' "$file" || true)"
  ((refs == git_sources + tar_sources)) ||
    fail "$file: $((git_sources + tar_sources)) remote source(s) but $refs ref(s); every source needs a pin"
  if ((git_sources > 0)); then
    pinned="$(grep -cE '^[[:space:]]*ref: .*[0-9a-f]{40}$' "$file" || true)"
    ((pinned == git_sources)) ||
      fail "$file: $git_sources git source(s) but $pinned commit pin(s)"
  fi
  if ((tar_sources > 0)); then
    pinned="$(grep -cE '^[[:space:]]*ref: [0-9a-f]{64}$' "$file" || true)"
    ((pinned == tar_sources)) ||
      fail "$file: $tar_sources tar source(s) but $pinned sha256 pin(s)"
  fi
done
echo "  ok: ${#elements[@]} elements, every remote source pinned to an immutable ref"

# --- This repository owns no CUPS component -------------------------------
# CUPS, cups-filters, libcupsfilters, libppd, ghostscript, PAPPL and
# pappl-retrofit come from the printing base. A build element here would be a
# second copy of the same source, and its artifact would be a second owner.
for file in "${elements[@]}"; do
  case "$(basename "$file")" in
    *cups*|*libppd*|*ghostscript*|*pappl*)
      fail "$file looks like a repository-owned CUPS stack element; the printing base is the one owner"
      ;;
  esac
done
echo '  ok: no element of this repository owns a CUPS stack component'

# --- Build patches live in the shared seam, not here ----------------------
# patches/ is the legacy Snap/Rock staging only. Anything a BuildStream element
# consumes has to come from fsdk-containers at the pinned ref.
staged="$(grep -rn 'patches/' elements/ | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
[[ -z "$staged" ]] || {
  printf '%s\n' "$staged" >&2
  fail 'a BuildStream element stages a local patch; the shared seam is fsdk-containers'
}
for patch in $(find patches -type f | sort); do
  name="$(basename "$patch")"
  grep -qF "patches/$name" rockcraft.yaml snap/snapcraft.yaml ||
    fail "$patch is neither referenced by the legacy Snap/Rock packaging nor by any element"
done
echo '  ok: no duplicate CUPS source copies staged into the graph'

# --- The image is composed from runtime domains ---------------------------
# The printing base is a devel stack: headers, static libraries, pkg-config
# files and, with them, the compiler and package manager it was built with.
grep -qE '^[[:space:]]*kind:[[:space:]]*compose' "$runtime" ||
  fail "$runtime is not a compose element"
for domain in devel debug doc static-blocklist; do
  grep -qE "^[[:space:]]*-[[:space:]]*${domain}$" "$runtime" ||
    fail "$runtime does not exclude the $domain domain"
done
echo '  ok: the runtime compose excludes the devel domains the base ships'

# --- The resolved graph has exactly one CUPS provider ---------------------
if [[ -n "$graph" ]]; then
  if [[ "$graph" == - ]]; then
    names="$(cat)"
  else
    [[ -f "$graph" ]] || fail "$graph: no such file"
    names="$(cat "$graph")"
  fi
  [[ -n "$names" ]] || fail 'the resolved graph is empty'

  grep -qx 'fsdk-containers.bst:printing/base.bst' <<<"$names" ||
    fail 'the graph does not stage fsdk-containers.bst:printing/base.bst, the one CUPS owner'

  # Every CUPS stack element has to come through the fsdk-containers junction:
  # a second FSDK junction, or an element of this repository, would be a second
  # CUPS artifact owner.
  second="$(grep -E '(cups|libppd|ghostscript|pappl|avahi)' <<<"$names" |
    grep -vE '^fsdk-containers\.bst(:|$)' || true)"
  [[ -z "$second" ]] || {
    printf '%s\n' "$second" >&2
    fail 'a CUPS stack element outside the fsdk-containers junction would be a second CUPS owner'
  }

  # The printing base already stages avahi-printing's avahi-daemon;
  # FSDK's components/avahi.bst installs the same files.
  if grep -qx 'fsdk-containers.bst:freedesktop-sdk.bst:components/avahi.bst' <<<"$names"; then
    fail 'components/avahi.bst is staged next to the base avahi-printing.bst'
  fi
  echo '  ok: fsdk-containers.bst:printing/base.bst is the only CUPS provider'
fi

printf 'PASS: the graph holds the fsdk-containers printing-base consumer contract'
if [[ -n "$graph" ]]; then
  printf ' with one CUPS artifact owner'
fi
printf '\n'