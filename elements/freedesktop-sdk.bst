# The freedesktop-sdk junction is the single CUPS artifact owner for this
# appliance. CUPS, cups-filters, libcupsfilters and libppd are built here and
# nowhere else in this repository, so every reverse dependency is compiled
# against the same libcups the application receives at runtime.
#
# The pinned ref matches the freedesktop-sdk line reviewed with the Ghostscript
# appliance, so the canonical patches below are the same patches reviewed there.
kind: junction

sources:
  - kind: git_repo
    url: gitlab:freedesktop-sdk/freedesktop-sdk.git
    track: freedesktop-sdk-26.08*
    ref: freedesktop-sdk-26.08rc.1-0-ge076d4978ee6945763486f6ebd755d189460e4e7
  # CUPS-only source patches, shared verbatim with the Ghostscript appliance.
  # patch_queue applies every file in the directory, so unrelated patches stay
  # in their own directories.
  - kind: local
    path: patches/cups
    directory: patches/ps-printer-app/cups
  - kind: local
    path: patches/libcupsfilters
    directory: patches/ps-printer-app/libcupsfilters
  - kind: local
    path: patches/cups-filters
    directory: patches/ps-printer-app/cups-filters
  # Project-level patch: injects the nested source patch queues above and
  # adjusts freedesktop-sdk's CUPS, Avahi and TLS configuration. Applied as a
  # patch queue rather than config.overrides so freedesktop-sdk keeps owning
  # these elements and their upstream updates.
  - kind: patch_queue
    path: patches/freedesktop-sdk

config:
  options:
    target_arch: "%{arch}"
    (?):
      - arch == "x86_64":
          bootstrap_build_arch: "x86_64"
      - arch == "aarch64":
          bootstrap_build_arch: "aarch64"
