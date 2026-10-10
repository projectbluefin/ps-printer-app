# AGENTS.md

Bluefin fork of OpenPrinting's PostScript Printer Application (PAPPL +
pappl-retrofit), built as an FSDK/BuildStream OCI appliance on the shared
fsdk-containers printing base. See `README.md` and `docs/fsdk-ci.md`.

## Checks and CI

- **`validate`** (`.github/workflows/validate.yml`): runs `pre-commit run --all-files` on `pull_request` and `merge_group`: `actionlint`, YAML/JSON/toml hygiene, and `no-floating-action-tags` (third-party actions must be pinned to a full SHA). Required in the `main` ruleset. Run `pre-commit run --all-files` before every commit.
- **Scorecard** (`.github/workflows/scorecard.yml`): OpenSSF Scorecard supply-chain check.
- **FSDK image CI** (`.github/workflows/fsdk-ci.yml`): `just validate` on pull requests; the merge queue runs the native amd64 and arm64 `just build` and `just verify`.
- **FSDK metadata** (`.github/workflows/fsdk-metadata.yml`): image labels must match the fsdk-containers pin (`docs/fsdk-metadata.md`).
- Host-only unit tests: `make test`.

## Issues and pull requests

Prow drives review and merge: `/` commands in comments set labels, reviewers and approvals, and Prow merges through the merge queue on `lgtm` + `approved` (approvers come from `OWNERS`). Labels and commands come from the org config in projectbluefin/.project; repository overrides live in `.github/prow.yaml`. See [how issues and PRs work here](https://github.com/projectbluefin/common/blob/main/docs/skills/label-workflow.md).

## Branches and releases

Target `main` for development and fsdk-containers updates. `promote-stable.yml` rebuilds and verifies an exact `main` commit and fast-forwards `stable` to it; only a `v$(cat VERSION)` tag on `stable` publishes an immutable OCI release (`registry-actions.yml`).
