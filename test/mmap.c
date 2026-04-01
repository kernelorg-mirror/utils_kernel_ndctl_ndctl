// SPDX-License-Identifier: GPL-2.0
// Copyright (C) 2015 Toshi Kani, Hewlett Packard Enterprise. All rights reserved.
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <string.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdarg.h>

#define MiB(a)           ((a) * 1024UL * 1024UL)

static struct timeval start_tv, stop_tv;
static int verbose;

// Calculate the difference between two time values.
static void tvsub(struct timeval *tdiff, struct timeval *t1, struct timeval *t0)
{
	tdiff->tv_sec = t1->tv_sec - t0->tv_sec;
	tdiff->tv_usec = t1->tv_usec - t0->tv_usec;
	if (tdiff->tv_usec < 0)
		tdiff->tv_sec--, tdiff->tv_usec += 1000000;
}

// Start timing now.
static void start(void)
{
	(void) gettimeofday(&start_tv, (struct timezone *) 0);
}

// Stop timing and return real time in microseconds.
static unsigned long long stop(void)
{
	struct timeval tdiff;

	(void) gettimeofday(&stop_tv, (struct timezone *) 0);
	tvsub(&tdiff, &stop_tv, &start_tv);
	return (tdiff.tv_sec * 1000000 + tdiff.tv_usec);
}

static void trace(const char *fmt, ...)
{
	va_list ap;

	if (!verbose)
		return;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
}

static void test_write(unsigned long *p, size_t size)
{
	size_t i;
	unsigned long *wp;
	unsigned long long timeval;

	start();
	for (i=0, wp=p; i<(size/sizeof(*wp)); i++)
		*wp++ = 1;
	timeval = stop();
	trace("Write: %10llu usec\n", timeval);
}

static void test_read(unsigned long *p, size_t size)
{
	size_t i;
	volatile unsigned long *wp, tmp;
	unsigned long long timeval;

	start();
	for (i=0, wp=p; i<(size/sizeof(*wp)); i++)
		tmp = *wp++;
	tmp = tmp;
	timeval = stop();
	trace("Read : %10llu usec\n", timeval);
}

int main(int argc, char **argv)
{
	int fd, i, opt, ret;
	int oflags, mprot, mflags = 0;
	int is_read_only = 0, is_mlock = 0, is_mlockall = 0;
	int mlock_skip = 0, read_test = 0, write_test = 0;
	void *mptr = NULL;
	unsigned long *p;
	struct stat stat;
	size_t size, cpy_size;
	const char *file_name = NULL;

	while ((opt = getopt(argc, argv, "RMSApsrwv")) != -1) {
		switch (opt) {
			case 'R':
				trace("> mmap: read-only\n");
				is_read_only = 1;
				break;
			case 'M':
				trace("> mlock\n");
				is_mlock = 1;
				break;
			case 'S':
				trace("> mlock - skip first iteration\n");
				mlock_skip = 1;
				break;
			case 'A':
				trace("> mlockall\n");
				is_mlockall = 1;
				break;
			case 'p':
				trace("> MAP_POPULATE\n");
				mflags |= MAP_POPULATE;
				break;
			case 's':
				trace("> MAP_SHARED\n");
				mflags |= MAP_SHARED;
				break;
			case 'r':
				trace("> read-test\n");
				read_test = 1;
				break;
			case 'w':
				trace("> write-test\n");
				write_test = 1;
				break;
			case 'v':
				verbose = 1;
				break;
		}
	}

	if (optind == argc) {
		printf("missing file name\n");
		return EXIT_FAILURE;
	}
	file_name = argv[optind];

	if (!(mflags & MAP_SHARED)) {
		trace("> MAP_PRIVATE\n");
		mflags |= MAP_PRIVATE;
	}

	if (is_read_only) {
		oflags = O_RDONLY;
		mprot = PROT_READ;
	} else {
		oflags = O_RDWR;
		mprot = PROT_READ|PROT_WRITE;
	}

	fd = open(file_name, oflags);
	if (fd == -1) {
		perror("open failed");
		return EXIT_FAILURE;
	}

	ret = fstat(fd, &stat);
	if (ret < 0) {
		perror("fstat failed");
		return EXIT_FAILURE;
	}
	size = stat.st_size;

	trace("> open %s size %#zx flags %#x\n", file_name, size, oflags);

	ret = posix_memalign(&mptr, MiB(2), size);
	if (ret ==0)
		free(mptr);

	trace("> mmap mprot 0x%x flags 0x%x\n", mprot, mflags);
	p = mmap(mptr, size, mprot, mflags, fd, 0x0);
	if (p == MAP_FAILED) {
		perror("mmap failed");
		return EXIT_FAILURE;
	}
	if ((long unsigned)p & (MiB(2)-1))
		trace("> mmap: NOT 2MiB aligned: 0x%p\n", p);
	else
		trace("> mmap: 2MiB aligned: 0x%p\n", p);

	cpy_size = size;

	for (i=0; i<3; i++) {

		if (is_mlock && !mlock_skip) {
			trace("> mlock 0x%p\n", p);
			ret = mlock(p, size);
			if (ret < 0) {
				perror("mlock failed");
				return EXIT_FAILURE;
			}
		} else if (is_mlockall) {
			trace("> mlockall\n");
			ret = mlockall(MCL_CURRENT|MCL_FUTURE);
			if (ret < 0) {
				perror("mlockall failed");
				return EXIT_FAILURE;
			}
		}

		trace("===== %d =====\n", i+1);
		if (write_test)
			test_write(p, cpy_size);
		if (read_test)
			test_read(p, cpy_size);

		if (is_mlock && !mlock_skip) {
			trace("> munlock 0x%p\n", p);
			ret = munlock(p, size);
			if (ret < 0) {
				perror("munlock failed");
				return EXIT_FAILURE;
			}
		} else if (is_mlockall) {
			trace("> munlockall\n");
			ret = munlockall();
			if (ret < 0) {
				perror("munlockall failed");
				return EXIT_FAILURE;
			}
		}

		/* skip, if requested, only the first iteration */
		mlock_skip = 0;
	}

	trace("> munmap 0x%p\n", p);
	munmap(p, size);
	printf("mmap: ok prot=%#x flags=%#x%s%s%s%s%s\n",
		mprot, mflags,
		is_read_only ? " RO" : "",
		is_mlock ? " MLOCK" : "",
		is_mlockall ? " MLOCKALL" : "",
		read_test ? " READ" : "",
		write_test ? " WRITE" : "");
	return EXIT_SUCCESS;
}

