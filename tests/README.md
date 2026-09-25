# Payload and print-path verification

`core-payload.sh` verifies the driver and PPD payload of a real ps-printer-app OCI
image and proves that a submitted job travels the intended IPP, filter and socket
backend path. It is the evidence half of
[projectbluefin/ps-printer-app#4](https://github.com/projectbluefin/ps-printer-app/issues/4);
it checks an image, never repository source text.

## What it proves

1. **Payload presence and closure.** Every entry in `payload-manifest.txt` exists in
   the image. Executables must resolve their runtime closure: `ldd` reports no
   missing shared library for ELF binaries, and a script's shebang interpreter must
   be installed. PPD archives must extract PostScript, sampled at their first,
   middle and last entry so a truncated archive cannot pass.
2. **The application uses the payload.** The generic PostScript driver is offered
   and at least `MIN_DRIVERS` drivers are enumerated, so the Foomatic and HPLIP PPD
   archives are wired into driver selection and not just shipped.
3. **A real job prints.** The container is started on the host network, a printer
   is added over IPP with the CUPS socket device scheme pointing at a TCP sink on
   the host, and the web interface's test page action submits a job. The captured
   bytes must carry a PostScript page description (`%!PS-Adobe`, also accepted
   behind a PJL preamble), and the job must reach `completed`.
4. **State survives a restart.** The container is restarted with the same state
   volume; the printer, its driver selection and the persisted state directory must
   all still be there.

## What it does not prove

Physical paper output, because no printer hardware is available. "The job completed
and PostScript bytes reached the socket sink" is the limit of what the image can be
asked without a printer.

## Running it

```sh
tests/core-payload.sh
```

`IMAGE` selects the image, `RUNTIME` the container runtime, `PORT` the application
port (the sink uses `PORT + 1000`), `MIN_DRIVERS` the enumeration floor juggled
above, and `IMAGE_PULL=1` forces a pull. The default image is
`ghcr.io/projectbluefin/ps-printer-app:latest`.

To verify a build of this tree instead of a published image, build the FSDK image
and run the full verification:

```sh
just build     # tags ghcr.io/projectbluefin/ps-printer-app:build
just verify    # validate, no-devel check, core-appliance.sh, core-payload.sh
```

`just verify` runs both suites against the `:build` tag (see `docs/fsdk-ci.md`).
The manifest, not this script, is what has to be updated when the graph changes
where the payload lands.

## Appliance verification

`core-appliance.sh` starts the built image as a user would (nonroot, host network,
a state volume) and checks from the host: the web interface answers as nonroot
65532:65532; the entrypoint seeds its state; IPP answers a Get-Printer-Attributes
request (`ipp-request.py`, a minimal IPP client, so no client tool in the image is
trusted) for a printer added with the generic PostScript driver; an IPP Print-Job of
`testpage.ps` completes and PostScript reaches `socket-sink.py`; and TERM, a dead
required child and an invalid `PORT` stop the appliance with 143, a failure and 64,
while persisted state survives. `IMAGE` and `PORT` (default 18000) select the image
and port.

## The manifest

`payload-manifest.txt` is the list of driver, filter, backend, interpreter and PPD
providers this application promises, with the source of each promise. It is the one
place to change when the payload contract changes, and the only place a reviewer
has to read to see what the image is expected to contain. The PostScript-only scope
is the one exclusion the upstream source itself makes: the non-PostScript Foomatic
manufacturer PPDs are removed before the archive is generated
(`elements/printer-app/foomatic-ps-ppds.bst`).

## Unit tests

### Running

```sh
make test
```

The tests build with a plain C compiler only. PAPPL, CUPS, libppd,
libcupsfilters and libpappl-retrofit do **not** need to be installed.

### What is covered

`tests/test_ps_autoadd.c` covers `ps_autoadd()` in `ps-printer-app.c`, the
callback that decides whether a discovered printer is auto-added and which
driver it gets.

`ps_autoadd()` is compiled and linked from the real `ps-printer-app.c` - the
`main()` in that file is skipped via `-DPS_PRINTER_APP_NO_MAIN` - so the
control flow under test is the shipped one, not a copy of it.

Regression under test: `prBestMatchingPPD()` returns `NULL` when it finds
neither a matching driver nor a usable device ID. `ps_autoadd()` used to
`strcmp()` that result unconditionally, which crashed the whole PAPPL service
on an unsupported printer.

### The test doubles

`tests/stubs/pappl-retrofit.h` shadows the real `<pappl-retrofit.h>` for the
test build only, and the test supplies its own `prBestMatchingPPD()` and
`prSupportsPostScript()`. Both answer for the device ID of the scenario
currently under test and refuse anything else, so a wrong device ID reaching
them fails a case instead of passing silently.

That means these tests pin `ps_autoadd()`'s own decision logic - including
every route into the former crash - but they do **not** exercise the real PPD
lookup or the real device ID parser. End-to-end behaviour, including the
driver that a specific physical printer actually gets, still has to be proven
by printing through a real image.

### Adding cases

Append to the `cases[]` table in `main()`: the device ID to pass in, what each
stubbed helper answers for it, the driver `ps_autoadd()` must return (`NULL`
for none), and how many PPD lookups it should make.
