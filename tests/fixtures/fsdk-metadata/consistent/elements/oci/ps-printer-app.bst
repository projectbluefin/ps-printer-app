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
              'io.projectbluefin.fsdk.version': '26.08.1'
              'io.projectbluefin.fsdk.ref': 'b02b59ffe19a49a402f357fd5fcb1d552ebc50d7'
      EOF
