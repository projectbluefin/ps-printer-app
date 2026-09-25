//
// Minimal stand-in for the libpappl-retrofit public header.
//
// This header is used *only* by the unit tests (see tests/README.md). It
// deliberately shadows the real <pappl-retrofit.h> so that the tests can link
// the real ps-printer-app.c - exercising ps_autoadd() exactly as shipped -
// without PAPPL, CUPS, libppd, libcupsfilters and libpappl-retrofit having to
// be installed.
//
// ps-printer-app.c pulls only three things out of the real header, so this
// stub only has to provide those.  The declarations must stay identical to
// the upstream ones; tests/test_ps_autoadd.c supplies the definitions.
//
// Licensed under Apache License v2.0.  See the file "LICENSE" for more
// information.
//

#ifndef PAPPL_RETROFIT_H
#  define PAPPL_RETROFIT_H

// The real header reaches these through PAPPL/CUPS; ps-printer-app.c uses
// NULL, strcmp(), strncmp() and strstr() without including them itself, so
// the stub has to pull them in too.
#  include <stddef.h>
#  include <string.h>

#  ifdef __cplusplus
extern "C" {
#  endif // __cplusplus


//
// Types...
//

typedef struct pr_printer_app_global_data_s pr_printer_app_global_data_t;


//
// Prototypes...
//

extern int prSupportsPostScript(const char *device_id);
extern const char *prBestMatchingPPD(
    const char                  *device_id,
    pr_printer_app_global_data_t *data);


#  ifdef __cplusplus
}
#  endif // __cplusplus

#endif // !PAPPL_RETROFIT_H
