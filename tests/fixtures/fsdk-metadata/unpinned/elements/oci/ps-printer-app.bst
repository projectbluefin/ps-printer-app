# Fixture: the OCI element, trimmed to the label block the checker reads.
kind: script

build-depends:
  - freedesktop-sdk.bst:components/oci-builder.bst
  - filename: printer-app/version.bst
    config:
      location: /metadata
  - filename: printer-app/core-runtime.bst
    config:
      location: /layer

config:
  commands:
    - |
      version="$(cat /metadata/VERSION)"
      cd "%{install-root}"
      build-oci <<EOF
      mode: oci
      gzip: disabled
      images:
        - os: linux
          architecture: "%{go-arch}"
          layer: /layer
          config:
            User: '65532:65532'
            Entrypoint: ['/usr/bin/catatonit', '--', '/usr/bin/bash', '/usr/libexec/ps-printer-app/container-entrypoint']
            Labels:
              'org.opencontainers.image.title': 'ps-printer-app'
              'org.opencontainers.image.version': '${version}'
              'io.projectbluefin.fsdk.version': '26.08rc.1'
              'io.projectbluefin.fsdk.ref': 'e076d4978ee6945763486f6ebd755d189460e4e7'
      EOF
