# Fixture: the pinned freedesktop-sdk junction, trimmed to the parts the
# metadata checker reads. The pin encodes the FSDK point release and commit.
kind: junction

sources:
  - kind: git_repo
    url: gitlab:freedesktop-sdk/freedesktop-sdk.git
    track: freedesktop-sdk-26.08*
    ref: freedesktop-sdk-26.08rc.1-0-ge076d4978ee6945763486f6ebd755d189460e4e7
  - kind: local
    path: patches/cups
    directory: patches/ps-printer-app/cups
  - kind: patch_queue
    path: patches/freedesktop-sdk

config:
  options:
    target_arch: "%{arch}"
