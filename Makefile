#
# Makefile for the PostScript Printer Application
#
# Copyright © 2020-2021 by Till Kamppeter
# Copyright © 2020 by Michael R Sweet
#
# Licensed under Apache License v2.0.  See the file "LICENSE" for more
# information.
#

# Version and
VERSION		=	1.0
prefix		=	$(DESTDIR)/usr
localstatedir	=	$(DESTDIR)/var
includedir	=	$(prefix)/include
bindir		=	$(prefix)/bin
libdir		=	$(prefix)/lib
mandir		=	$(prefix)/share/man
ppddir		=	$(prefix)/share/ppd
statedir	=	$(localstatedir)/lib/ps-printer-app
spooldir	=	$(localstatedir)/spool/ps-printer-app
serverbin	=	$(prefix)/lib/ps-printer-app
resourcedir	=	$(prefix)/share/ps-printer-app
cupsserverbin	=	`cups-config  --serverbin`
unitdir 	:=	$(DESTDIR)`pkg-config --variable=systemdsystemunitdir systemd`


# Compiler/linker options...
OPTIM		=	-Os -g
CFLAGS		+=	`pkg-config --cflags pappl` `cups-config --cflags` `pkg-config --cflags libppd` `pkg-config --cflags libcupsfilters` `pkg-config --cflags libpappl-retrofit` $(OPTIM)
ifdef VERSION
CFLAGS		+=	-DSYSTEM_VERSION_STR="\"$(VERSION)\""
# PAPPL keeps the numeric version as four 16-bit integers.  VERSION is either a
# foomatic-db snapshot date plus a packaging revision, YYYYMMDD-N, mapped to
# YYYY.M.D.N (20240504-20 -> 2024.5.4.20), or MAJOR[.MINOR[.PATCH]][-PACKAGE]
# with missing fields set to 0.  Any other VERSION, or a field above 65535,
# stops the build instead of compiling a meaningless number.
VERSION_NUMBERS	:=	$(shell printf '%s\n' '$(VERSION)' | awk '\
  NR > 1 { exit 1 } \
  /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]+$$/ { \
    f[1] = substr($$0, 1, 4); f[2] = substr($$0, 5, 2); \
    f[3] = substr($$0, 7, 2); f[4] = substr($$0, 10); \
    if (f[2] + 0 < 1 || f[2] + 0 > 12 || f[3] + 0 < 1 || f[3] + 0 > 31) exit 1; \
    ok = 1 } \
  /^[0-9]+(\.[0-9]+(\.[0-9]+)?)?(-[0-9]+)?$$/ && !ok { \
    v = $$0; f[4] = 0; d = index(v, "-"); \
    if (d) { f[4] = substr(v, d + 1); v = substr(v, 1, d - 1) } \
    n = split(v, p, "."); for (i = 1; i <= 3; i++) f[i] = (i <= n) ? p[i] : 0; \
    ok = 1 } \
  END { \
    if (!ok || NR != 1) exit 1; \
    for (i = 1; i <= 4; i++) if (length(f[i]) > 5 || f[i] + 0 > 65535) exit 1; \
    print f[1] + 0, f[2] + 0, f[3] + 0, f[4] + 0 }')
ifneq ($(words $(VERSION_NUMBERS)),4)
$(error VERSION "$(VERSION)" is neither YYYYMMDD-N nor MAJOR[.MINOR[.PATCH]][-PACKAGE] with every field at most 65535)
endif
MAJOR		?=	$(word 1,$(VERSION_NUMBERS))
MINOR		?=	$(word 2,$(VERSION_NUMBERS))
PATCH		?=	$(word 3,$(VERSION_NUMBERS))
PACKAGE		?=	$(word 4,$(VERSION_NUMBERS))
endif
ifdef MAJOR
CFLAGS		+=	-DSYSTEM_VERSION_ARR_0=$(MAJOR)
endif
ifdef MINOR
CFLAGS		+=	-DSYSTEM_VERSION_ARR_1=$(MINOR)
endif
ifdef PATCH
CFLAGS		+=	-DSYSTEM_VERSION_ARR_2=$(PATCH)
endif
ifdef PACKAGE
CFLAGS		+=	-DSYSTEM_VERSION_ARR_3=$(PACKAGE)
endif
LDFLAGS		+=	$(OPTIM) `cups-config --ldflags`
LIBS		+=	`pkg-config --libs pappl` `cups-config --image --libs` `pkg-config --libs libppd` `pkg-config --libs libcupsfilters` `pkg-config --libs libpappl-retrofit`


# Targets...
OBJS		=	ps-printer-app.o
TARGETS		=	ps-printer-app

# Unit tests.  These link the real ps-printer-app.c with the two
# libpappl-retrofit helpers that ps_autoadd() calls replaced by test doubles,
# so they build and run without PAPPL, CUPS, libppd, libcupsfilters or
# libpappl-retrofit installed.  See tests/README.md.
TEST_CFLAGS	=	-Itests/stubs -DPS_PRINTER_APP_NO_MAIN -Wall -Wextra
TEST_TARGETS	=	tests/test_ps_autoadd
# Host-only Python unit tests (Renovate config; the IPP client the appliance
# suites trust; the numeric version derived from VERSION).
PYTHON_TESTS	=	test_renovate.py test_ipp_request.py test_numeric_version.py

.PHONY:		all clean install test


# General build rules...
.SUFFIXES:	.c .o
.c.o:
	$(CC) $(CFLAGS) -c -o $@ $<


# Targets...
all:		$(TARGETS)

clean:
	rm -f $(TARGETS) $(OBJS) $(TEST_TARGETS)

test:		$(TEST_TARGETS)
	for t in $(TEST_TARGETS); do ./$$t || exit 1; done
	for t in $(PYTHON_TESTS); do python3 -m unittest discover -s tests -p $$t || exit 1; done
	python3 -m unittest discover -s tests -p test_verify_no_devel.py
	python3 -m unittest discover -s tests -p test_no_remote_login_records.py

tests/test_ps_autoadd:	tests/test_ps_autoadd.c ps-printer-app.c \
			tests/stubs/pappl-retrofit.h
	$(CC) $(TEST_CFLAGS) -o $@ tests/test_ps_autoadd.c ps-printer-app.c

install:	$(TARGETS)
	mkdir -p $(bindir)
	cp $(TARGETS) $(bindir)
	mkdir -p $(mandir)/man1
	cp ps-printer-app.1 $(mandir)/man1
	mkdir -p $(ppddir)
	cp generic-ps-printer.ppd $(ppddir)
	mkdir -p $(statedir)/ppd
	mkdir -p $(spooldir)
	mkdir -p $(resourcedir)
	cp testpage.ps $(resourcedir)
	if test "x$(cupsserverbin)" != x; then \
	  mkdir -p $(libdir); \
	  touch $(serverbin) 2> /dev/null || :; \
	  if rm $(serverbin) 2> /dev/null; then \
	    ln -s $(cupsserverbin) $(serverbin); \
	  fi; \
	else \
	  mkdir -p $(serverbin)/filter; \
	  mkdir -p $(serverbin)/backend; \
	fi
	if test "x$(unitdir)" != x; then \
	  mkdir -p $(unitdir); \
	  cp ps-printer-app.service $(unitdir); \
	fi

ps-printer-app:	$(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBS)

$(OBJS):	Makefile
