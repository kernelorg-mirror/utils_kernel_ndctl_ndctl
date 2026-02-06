// SPDX-License-Identifier: GPL-2.0
/* Copyright (C) 2025 AMD. All rights reserved. */
#include <util/parse-options.h>
#include <cxl/libcxl.h>
#include <cxl/filter.h>
#include <util/log.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

static bool debug;

static struct proto_inject_params {
	const char *proto;
	const char *severity;
} proto_inj_param;

static const struct option proto_inject_options[] = {
	OPT_STRING('p', "protocol", &proto_inj_param.proto, "mem/cache",
		   "Which CXL protocol error to inject into <dport>"),
	OPT_STRING('s', "severity", &proto_inj_param.severity,
		   "correctable/uncorrectable/fatal",
		   "Severity of CXL protocol to inject into <dport>"),
#ifdef ENABLE_DEBUG
	OPT_BOOLEAN(0, "debug", &debug, "turn on debug output"),
#endif
	OPT_END(),
};

static struct inject_poison_params {
	const char *address;
} poison_inj_param;

static struct clear_params {
	const char *address;
} poison_clear_param;

static const struct option poison_inject_options[] = {
	OPT_STRING('a', "address", &poison_inj_param.address,
		   "Address for poison injection",
		   "Device physical address for poison injection in hex or decimal"),
#ifdef ENABLE_DEBUG
	OPT_BOOLEAN(0, "debug", &debug, "turn on debug output"),
#endif
	OPT_END(),
};

static const struct option poison_clear_options[] = {
	OPT_STRING('a', "address", &poison_clear_param.address,
		   "Address for poison clearing",
		   "Device physical address to clear poison from in hex or decimal"),
#ifdef ENABLE_DEBUG
	OPT_BOOLEAN(0, "debug", &debug, "turn on debug output"),
#endif
	OPT_END(),
};

static struct log_ctx iel;

static struct cxl_protocol_error *find_cxl_proto_err(struct cxl_ctx *ctx,
						     const char *type,
						     const char *severity)
{
	struct cxl_protocol_error *pe;
	char perror[256] = { 0 };
	size_t len;

	len = snprintf(perror, sizeof(perror), "%s-%s", type,
		       severity);
	if (len >= sizeof(perror)) {
		log_err(&iel, "Buffer too small\n");
		return NULL;
	}

	cxl_protocol_error_foreach(ctx, pe) {
		if (strcmp(perror, cxl_protocol_error_get_str(pe)) == 0)
			return pe;
	}

	log_err(&iel, "Invalid CXL protocol error type: %s\n", perror);
	return NULL;
}

static struct cxl_dport *find_cxl_dport(struct cxl_ctx *ctx, const char *devname)
{
	struct cxl_dport *dport;
	struct cxl_port *port;
	struct cxl_bus *bus;

	cxl_bus_foreach(ctx, bus)
		cxl_port_foreach_all(cxl_bus_get_port(bus), port)
			cxl_dport_foreach(port, dport)
				if (util_cxl_dport_filter(dport, devname))
					return dport;

	log_err(&iel, "Downstream port \"%s\" not found\n", devname);
	return NULL;
}

static struct cxl_memdev *find_cxl_memdev(struct cxl_ctx *ctx,
					  const char *filter)
{
	struct cxl_memdev *memdev;

	cxl_memdev_foreach(ctx, memdev) {
		if (util_cxl_memdev_filter(memdev, filter, NULL))
			return memdev;
	}

	log_err(&iel, "Memdev \"%s\" not found\n", filter);
	return NULL;
}

static int inject_proto_err(struct cxl_ctx *ctx, const char *devname,
			    struct cxl_protocol_error *perror)
{
	struct cxl_dport *dport;
	int rc;

	if (!devname) {
		log_err(&iel, "No downstream port specified for injection\n");
		return -EINVAL;
	}

	dport = find_cxl_dport(ctx, devname);
	if (!dport)
		return -ENODEV;

	rc = cxl_dport_protocol_error_inject(dport,
					     cxl_protocol_error_get_num(perror));
	if (rc)
		return rc;

	log_info(&iel, "injected %s protocol error.\n",
		 cxl_protocol_error_get_str(perror));
	return 0;
}

static int inject_protocol_action(int argc, const char **argv,
				  struct cxl_ctx *ctx,
				  const struct option *options,
				  const char *usage)
{
	struct cxl_protocol_error *perr;
	const char * const u[] = {
		usage,
		NULL
	};
	int rc = -EINVAL;

	log_init(&iel, "cxl inject-protocol-error", "CXL_INJECT_LOG");
	argc = parse_options(argc, argv, options, u, 0);

	if (debug) {
		cxl_set_log_priority(ctx, LOG_DEBUG);
		iel.log_priority = LOG_DEBUG;
	} else {
		iel.log_priority = LOG_INFO;
	}

	if (argc != 1 || proto_inj_param.proto == NULL ||
	    proto_inj_param.severity == NULL) {
		usage_with_options(u, options);
		return rc;
	}

	perr = find_cxl_proto_err(ctx, proto_inj_param.proto,
				  proto_inj_param.severity);
	if (perr) {
		rc = inject_proto_err(ctx, argv[0], perr);
		if (rc)
			log_err(&iel, "Failed to inject error: %d\n", rc);
	}

	return rc;
}

int cmd_inject_protocol_error(int argc, const char **argv, struct cxl_ctx *ctx)
{
	int rc = inject_protocol_action(argc, argv, ctx, proto_inject_options,
					"inject-protocol-error <dport> -p <protocol> -s <severity> [<options>]");

	return rc ? EXIT_FAILURE : EXIT_SUCCESS;
}

static int poison_action(struct cxl_ctx *ctx, const char *filter,
			 const char *addr_str, bool inj)
{
	struct cxl_memdev *memdev;
	unsigned long long addr;
	int rc;

	memdev = find_cxl_memdev(ctx, filter);
	if (!memdev)
		return -ENODEV;

	if (!cxl_memdev_has_poison_support(memdev, inj)) {
		log_err(&iel, "%s does not support %s\n",
			cxl_memdev_get_devname(memdev),
			inj ? "poison injection" : "clearing poison");
		return -EINVAL;
	}

	errno = 0;
	addr = strtoull(addr_str, NULL, 0);
	if (addr == ULLONG_MAX && errno == ERANGE) {
		log_err(&iel, "invalid address: %s", addr_str);
		return -EINVAL;
	}

	if (inj)
		rc = cxl_memdev_inject_poison(memdev, addr);
	else
		rc = cxl_memdev_clear_poison(memdev, addr);

	if (rc)
		log_err(&iel, "failed to %s %s:%s: %s\n",
			inj ? "inject poison at" : "clear poison at",
			cxl_memdev_get_devname(memdev), addr_str, strerror(-rc));
	else
		log_info(&iel,
			 "poison %s at %s:%s\n", inj ? "injected" : "cleared",
			 cxl_memdev_get_devname(memdev), addr_str);

	return rc;
}

static int inject_poison_action(int argc, const char **argv,
				struct cxl_ctx *ctx,
				const struct option *options, const char *usage)
{
	const char * const u[] = {
		usage,
		NULL
	};
	int rc = -EINVAL;

	log_init(&iel, "cxl inject-media-poison", "CXL_CLEAR_LOG");
	argc = parse_options(argc, argv, options, u, 0);

	if (debug) {
		cxl_set_log_priority(ctx, LOG_DEBUG);
		iel.log_priority = LOG_DEBUG;
	} else {
		iel.log_priority = LOG_INFO;
	}

	if (argc != 1 || !poison_inj_param.address) {
		usage_with_options(u, options);
		return rc;
	}

	rc = poison_action(ctx, argv[0], poison_inj_param.address, true);
	if (rc) {
		log_err(&iel, "Failed to inject poison on %s: %s\n", argv[0],
			strerror(-rc));
		return rc;
	}

	return rc;
}

int cmd_inject_media_poison(int argc, const char **argv, struct cxl_ctx *ctx)
{
	int rc = inject_poison_action(argc, argv, ctx, poison_inject_options,
				      "inject-media-poison <memdev> -a <address> [<options>]");

	return rc ? EXIT_FAILURE : EXIT_SUCCESS;
}

static int clear_poison_action(int argc, const char **argv, struct cxl_ctx *ctx,
			       const struct option *options, const char *usage)
{
	const char * const u[] = {
		usage,
		NULL
	};
	int rc = -EINVAL;

	log_init(&iel, "cxl clear-media-poison", "CXL_CLEAR_LOG");
	argc = parse_options(argc, argv, options, u, 0);

	if (debug) {
		cxl_set_log_priority(ctx, LOG_DEBUG);
		iel.log_priority = LOG_DEBUG;
	} else {
		iel.log_priority = LOG_INFO;
	}

	if (argc != 1 || !poison_clear_param.address) {
		usage_with_options(u, options);
		return rc;
	}

	rc = poison_action(ctx, argv[0], poison_clear_param.address, false);
	if (rc) {
		log_err(&iel, "Failed to clear poison on %s: %s\n", argv[0],
			strerror(-rc));
		return rc;
	}

	return rc;
}

int cmd_clear_media_poison(int argc, const char **argv, struct cxl_ctx *ctx)
{
	int rc = clear_poison_action(argc, argv, ctx, poison_clear_options,
				     "clear-error <memdev> -a <address> [<options>]");

	return rc ? EXIT_FAILURE : EXIT_SUCCESS;
}
