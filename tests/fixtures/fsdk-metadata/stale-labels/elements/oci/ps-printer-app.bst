# Fixture: elements/oci/ps-printer-app.bst, trimmed to the build-oci label block.
kind: script
config:
  commands:
    - |
      build-oci <<EOF
      mode: oci
      images:
        - os: linux
          architecture: "%{go-arch}"
          layer: /layer
          config:
            Labels:
              'org.opencontainers.image.title': 'ps-printer-app'
              'org.opencontainers.image.version': '${version}'
              'io.projectbluefin.fsdk.version': '26.08.0'
              'io.projectbluefin.fsdk.ref': 'db97cce32cecadc7a3e98f06d557ebfa6ba9ad46'
      EOF
