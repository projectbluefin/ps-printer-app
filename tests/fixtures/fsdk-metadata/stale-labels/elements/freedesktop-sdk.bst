# Fixture: the pinned freedesktop-sdk junction, trimmed to the parts the
# metadata checker reads. The pin encodes the FSDK point release and commit.
kind: junction

sources:
  - kind: git_repo
    url: gitlab:freedesktop-sdk/freedesktop-sdk.git
    track: freedesktop-sdk-26.08*
    ref: freedesktop-sdk-26.08rc.2-0-g3b1c9f0a2d4e5b6c7d8e9f0a1b2c3d4e5f607182
  - kind: local
    path: patches/cups
    directory: patches/ps-printer-app/cups
  - kind: patch_queue
    path: patches/freedesktop-sdk

config:
  options:
    target_arch: "%{arch}"
