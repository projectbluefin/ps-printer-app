//
// Unit tests for ps_autoadd(), the PostScript Printer Application's driver
// auto-selection callback.
//
// ps_autoadd() is compiled and linked from the real ps-printer-app.c, so the
// control flow under test is the shipped one.  The two libpappl-retrofit
// helpers it calls are replaced by deterministic test doubles (see
// tests/stubs/pappl-retrofit.h), which lets the suite run with no printer, no
// PPD archive and no libpappl-retrofit installed.
//
// Regression under test: prBestMatchingPPD() returns NULL when it finds
// neither a matching driver nor a usable device ID.  ps_autoadd() used to
// strcmp() that result unconditionally, which segfaults the whole PAPPL
// service on an unsupported printer.
//
// Licensed under Apache License v2.0.  See the file "LICENSE" for more
// information.
//

#include <pappl-retrofit.h>

#include <stdio.h>
#include <string.h>


//
// Local types...
//

// One scenario: the device ID handed to ps_autoadd(), what the stubbed
// libpappl-retrofit helpers answer for it, and what ps_autoadd() must return.
typedef struct case_s
{
  const char *what;			// I - What this case covers
  const char *device_id;		// I - IEEE-1284 device ID to pass in
  const char *ppd;			// I - Driver the PPD lookup returns, NULL for none
  int         ps;			// I - What the PostScript check returns
  const char *expect;			// I - Driver ps_autoadd() must return, NULL for none
  int         expect_ppd_calls;		// I - PPD lookups ps_autoadd() should make
} case_t;


//
// Local globals...
//

static const case_t *g_case = NULL;	// Scenario currently being exercised
static int          g_ppd_calls = 0;	// prBestMatchingPPD() call count
static int          g_run = 0;		// Cases run
static int          g_failed = 0;	// Cases that failed

// Backing storage for the non-NULL global data pointer.  The global data
// record is opaque to this test - ps_autoadd() only checks it for NULL.
static char         g_global_data_storage;

#define GLOBAL_DATA ((pr_printer_app_global_data_t *)(void *)&g_global_data_storage)


//
// The real callback under test, linked in from ps-printer-app.c.
//

extern const char *ps_autoadd(const char *device_info,
			      const char *device_uri,
			      const char *device_id,
			      void       *data);


//
// Test doubles for libpappl-retrofit...
//
// Both answer for the device ID of the scenario currently under test and
// refuse everything else, so a wrong device ID reaching them shows up as a
// failing case rather than passing silently.
//

int					// O - 1 if printer does PostScript, 0 if not
prSupportsPostScript(
    const char *device_id)		// I - IEEE-1284 device ID
{
  if (g_case == NULL || device_id == NULL ||
      strcmp(device_id, g_case->device_id) != 0)
    return (0);

  return (g_case->ps);
}


const char *				// O - Driver name, or NULL for no driver
prBestMatchingPPD(
    const char                  *device_id,	// I - IEEE-1284 device ID
    pr_printer_app_global_data_t *data)		// I - Global data
{
  g_ppd_calls ++;

  (void)data;

  if (g_case == NULL || device_id == NULL ||
      strcmp(device_id, g_case->device_id) != 0)
    return (NULL);

  return (g_case->ppd);
}


//
// 'report()' - Record one case result.
//

static void
report(int         ok,			// I - 1 if the case passed
       const case_t *c,			// I - Case that ran
       const char  *got,		// I - Driver ps_autoadd() returned
       int         ppd_calls)		// I - PPD lookups ps_autoadd() made
{
  g_run ++;

  if (ok)
  {
    printf("ok   - %s\n", c->what);
    return;
  }

  g_failed ++;

  printf("FAIL - %s\n", c->what);
  printf("       device ID      : \"%s\"\n", c->device_id);
  printf("       driver expected: %s\n", c->expect ? c->expect : "(NULL)");
  printf("       driver got     : %s\n", got ? got : "(NULL)");
  printf("       PPD lookups    : expected %d, got %d\n",
	 c->expect_ppd_calls, ppd_calls);
}


//
// 'run_case()' - Drive ps_autoadd() with one scenario and check the result.
//

static void
run_case(const case_t *c)		// I - Case to run
{
  const char *got;
  int         ok;


  g_case      = c;
  g_ppd_calls = 0;

  got = ps_autoadd("stub-device", "stub:uri", c->device_id, GLOBAL_DATA);

  if (c->expect == NULL)
    ok = (got == NULL);
  else
    ok = (got != NULL && strcmp(got, c->expect) == 0);

  // A driver must only be looked up once, and not at all for a printer that
  // has already been ruled out.
  ok = ok && (g_ppd_calls == c->expect_ppd_calls);

  report(ok, c, got, g_ppd_calls);
}


//
// 'main()' - Run every case.
//

int
main(void)
{
  static const case_t cases[] =
  {
    // A printer that advertises no PDL at all and that no driver matches.
    // This is the regression: the lookup returns NULL and the old code
    // strcmp()ed it, taking the service down with SIGSEGV.
    {
      "unknown printer with no PDL info is skipped, not a crash",
      "MFG:Acme;MDL:Inkjet 100;", NULL, 0, NULL, 1
    },
    // A malformed ID - empty is accepted by the PDL sniffing and reaches the
    // same NULL lookup.
    {
      "malformed (empty) device ID is skipped, not a crash",
      "", NULL, 0, NULL, 1
    },
    // A printer that claims PostScript but that no driver matches: the second
    // route into the NULL lookup.
    {
      "PostScript printer with no matching driver is skipped, not a crash",
      "MFG:Acme;MDL:Broken;CMD:POSTSCRIPT;", NULL, 1, NULL, 1
    },
    // A printer that explicitly does not do PostScript is not auto-added,
    // and is never looked up in the first place.
    {
      "non-PostScript printer is rejected without a driver lookup",
      "MFG:HP;MDL:LaserJet 4;CMD:PCL;", NULL, 0, NULL, 0
    },
    // A known PostScript printer keeps its dedicated PPD.
    {
      "known PostScript printer keeps its dedicated PPD",
      "MFG:Apple;MDL:LaserWriter II NTX;CMD:POSTSCRIPT;",
      "apple-laserwriter-ii-ntx", 1, "apple-laserwriter-ii-ntx", 1
    },
    // Only the generic driver matches and the printer does not do
    // PostScript, so nothing is auto-added.
    {
      "generic fallback is dropped for a non-PostScript printer",
      "MFG:Generic;MDL:Unknown Printer;", "generic", 0, NULL, 1
    },
    // Only the generic driver matches but the printer does do PostScript, so
    // the generic driver is kept.
    {
      "generic fallback is kept for a PostScript printer",
      "MFG:Generic;MDL:PS Printer;CMD:POSTSCRIPT;", "generic", 1, "generic", 1
    }
  };
  // ps_autoadd() must not require a device ID or global data to be present.
  static const case_t null_device_id =
    { "NULL device ID is rejected", NULL, NULL, 0, NULL, 0 };
  static const case_t null_global_data =
    { "NULL global data is rejected", "MFG:Acme;MDL:Inkjet 100;",
      NULL, 0, NULL, 0 };

  size_t i;

  for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i ++)
    run_case(cases + i);

  g_case      = &null_device_id;
  g_ppd_calls = 0;
  report(ps_autoadd("stub-device", "stub:uri", NULL, GLOBAL_DATA) == NULL &&
	 g_ppd_calls == 0, &null_device_id, NULL, g_ppd_calls);

  g_case      = &null_global_data;
  g_ppd_calls = 0;
  report(ps_autoadd("stub-device", "stub:uri", null_global_data.device_id,
		    NULL) == NULL && g_ppd_calls == 0,
	 &null_global_data, NULL, g_ppd_calls);

  printf("\n%d/%d cases passed\n", g_run - g_failed, g_run);

  return (g_failed > 0);
}
