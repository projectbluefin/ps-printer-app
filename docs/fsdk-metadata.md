# The FSDK metadata gate

The appliance is built against a pinned freedesktop-sdk junction, and the OCI
artifact advertises that pin:

| Label or annotation | Meaning |
| --- | --- |
| `io.projectbluefin.fsdk.version` | the freedesktop-sdk point release |
| `io.projectbluefin.fsdk.ref` | the freedesktop-sdk commit |
| `org.opencontainers.image.version` | the application release |

The same two facts are written in three independent places:

- the junction source in `elements/freedesktop-sdk.bst`, where
  `project.conf`'s `ref-format: git-describe` makes the ref carry both the point
  release and the commit;
- the `build-oci` label block in `elements/oci/ps-printer-app.bst`, which is
  what every architecture image config carries;
- the annotations on the published multi-architecture index, which GHCR renders
  and which nothing inherits from the child manifests.

A commit can bump one of those and leave the others behind. The image still
builds, still prints, and still passes `just verify` — the drift surfaces only
when something reads the metadata back, which today is the release job. This
gate reads all three and refuses the state in between.

## Running it

```sh
# The graph against itself. No registry, no build, no credentials.
python3 scripts/verify-fsdk-metadata.py

# Also against published index metadata.
python3 scripts/verify-fsdk-metadata.py \
    --index-ref docker://ghcr.io/projectbluefin/ps-printer-app:20240504-20 \
    --app-version "$(< VERSION)" \
    --require-multiarch
```

`--index` takes a JSON file or `-` for standard input, which is what the
fixtures use. `--index-ref` accepts anything `skopeo inspect --raw` accepts.
`--require-multiarch` additionally insists the index carries an amd64 and an
arm64 manifest, so a single-architecture manifest is never mistaken for the
index.

## Where it runs

- `.github/workflows/fsdk-metadata.yml` runs the unit tests and the source-only
  comparison on every pull request and push to `testing`. It reads files and
  runs tests; it builds nothing and needs no credentials.
- `.github/workflows/promote-stable.yml` runs both comparisons in its
  `metadata` job, and the `promote` job that writes `stable` needs that job. A
  mismatch — or an index that cannot be read — stops the promotion with `stable`
  untouched.

## What it refuses

Every failure mode exits non-zero with a diagnostic that names the field, both
values, and the file or index the wrong one came from:

- the junction and the image labels disagree;
- the junction and the index annotations disagree;
- the junction carries no `ref: freedesktop-sdk-<version>-<n>-g<sha>` line, or
  pins more than one;
- the OCI element writes no FSDK label, or writes one twice;
- the index has no `annotations`, or drops one of the two FSDK labels, or is an
  image manifest rather than an index;
- the registry cannot be reached, the credentials are wrong, or `skopeo` is not
  installed.

The last group matters as much as the first. `skopeo inspect` exits non-zero for
a missing tag *and* for a network or authentication failure, so a lookup that
fails is never read as agreement.

## What it does not claim

This is a metadata comparison. It says nothing about whether the image runs,
what it prints, or whether the pinned freedesktop-sdk line is a good one. Those
are `just verify` and the appliance suites. Nothing here prints on paper, and
physical output remains unverified without printer hardware.

The gate also cannot compare index metadata that does not exist yet. Before the
release pipeline publishes an index for a version, `promote-stable.yml` fails
closed rather than promoting on the graph alone.
