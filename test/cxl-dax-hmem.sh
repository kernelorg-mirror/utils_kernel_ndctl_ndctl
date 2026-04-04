#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 Intel Corporation

. $(dirname $0)/common

rc=77

set -ex

trap 'err $LINENO' ERR

check_prereq "jq"

modinfo cxl_test | grep -q '^parm:.*hmem_test' || \
	do_skip "cxl_test hmem_test module param not available"

modinfo cxl_test | grep -q '^parm:.*fail_autoassemble' || \
	do_skip "cxl_test fail_autoassemble module param not available"

rc=1

unload()
{
	modprobe -r dax_cxl 2>/dev/null || true
	modprobe -r dax_hmem 2>/dev/null || true
	modprobe -r cxl_mock_mem 2>/dev/null || true
	modprobe -r cxl_test 2>/dev/null || true
}

find_dax_cxl()
{
	$DAXCTL list -R | jq -r \
		'.[] | select(.path | contains("cxl_acpi.0")) | .path'
}

find_dax_hmem()
{
	$DAXCTL list -R | jq -r \
		'.[] | select(.path | contains("hmem_platform.1")) | .path'
}

unload

# Verify CXL autoassembly claims the Soft Reserve range before dax_hmem
modprobe cxl_mock_mem
modprobe cxl_test hmem_test=1
$CXL list

dax=$(find_dax_cxl)
[[ -z "$dax" ]] && err $LINENO
dax=$(find_dax_hmem)
[[ -n "$dax" ]] && err $LINENO

unload

# Verify dax_hmem claims the Soft Reserve range when CXL autoassembly fails
modprobe cxl_mock_mem
modprobe cxl_test hmem_test=1 fail_autoassemble=1
$CXL list

dax=$(find_dax_cxl)
[[ -n "$dax" ]] && err $LINENO
dax=$(find_dax_hmem)
[[ -z "$dax" ]] && err $LINENO

unload
check_dmesg "$LINENO"
