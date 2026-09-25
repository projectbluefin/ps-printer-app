# Fixture: the pinned freedesktop-sdk junction, trimmed to the parts the
# metadata checker reads. The pin encodes the FSDK point release and commit.
kind: junction

sources:
  - kind: git_repo
    url: gitlab:freedesktop-sdk/freedesktop-sdk.git
    track: freedesktop-sdk-26.08*
    ref: freedesktop-sdk-26.08rc.1-0-g9a8b7c6d5e4f30211fee0dd9cc8bb7aa6699a5b4
  - kind: local
    path: patches/cups
    directory: patches/ps-printer-app/cups
  - kind: patch_queue
    path: patches/freedesktop-sdk

config:
  options:
    target_arch: "%{arch}"
