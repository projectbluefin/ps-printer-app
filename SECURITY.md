# Security Policy

## Supported images

Only `ghcr.io/projectbluefin/ps-printer-app` images built from the `main`
branch of this repository are supported. The Snap, Rock and Docker Hub images
described in the README are OpenPrinting's and are not built here.

## Reporting a vulnerability

Do not open a public issue for a security report. Email the maintainers at
**bluefin@projectbluefin.io** with:

- the vulnerability and its impact
- reproduction steps or a proof of concept
- the affected image tag or commit

Vulnerabilities in the printing stack the image takes from the shared
fsdk-containers base (CUPS, cups-filters, libcupsfilters, libppd, Ghostscript,
PAPPL, pappl-retrofit) are handled through
[fsdk-containers](https://github.com/projectbluefin/fsdk-containers/blob/main/SECURITY.md).
