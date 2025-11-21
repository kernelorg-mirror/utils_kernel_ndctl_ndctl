#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2025 Intel Corporation. All rights reserved.

. "$(dirname "$0")"/common

rc=77

set -ex

trap 'err $LINENO' ERR

check_prereq "jq"

modprobe -r cxl_test
modprobe cxl_test extended_linear_cache=1
[ -f /sys/module/cxl_test/parameters/extended_linear_cache ] || \
    do_skip "cxl_test extended_linear_cache module param not available"

rc=1

find_region()
{
	json="$($CXL list -b cxl_test -R)"
	region=$(echo "$json" | jq -r '.[] | select(has("extended_linear_cache_size") and .extended_linear_cache_size != null) | .region')
	[[ -n "$region" && "$region" != "null" ]] || err "no test extended linear cache region found"
}

retrieve_info()
{
	# Root decoder name
	cxlrd="$($CXL list -r"$region" -D | jq -r '.[] | select(has("root decoders")) | ."root decoders"[0].decoder')"
	# Root decoder (CFMWS) window size
	cxlrd_size="$($CXL list -b cxl_test -d "$cxlrd" | jq '.[] | to_entries[] | select(.key | startswith("decoders:")) | .value[].size')"
	# Root decoder (CFMWS) window address base
	cxlrd_hpa="$($CXL list -b cxl_test -d "$cxlrd" | jq '.[] | to_entries[] | select(.key | startswith("decoders:")) | .value[].resource')"

	# Region size
	region_size="$($CXL list -b cxl_test -r "$region" | jq '.[] | to_entries[] | select(.key | startswith("regions:")) | .value[].size')"

	# switch port 0 size
	swp0_size="$($CXL list -r "$region" -D | jq '.[] | select(has("port decoders")) | ."port decoders"[0] | .size')"
	# switch port 0 base address
	swp0_hpa="$($CXL list -r "$region" -D | jq '.[] | select(has("port decoders")) | ."port decoders"[0] | .resource')"

	# switch port 1 size
	swp1_size="$($CXL list -r "$region" -D | jq '.[] | select(has("port decoders")) | ."port decoders"[1] | .size')"
	# switch port 1 base address
	swp1_hpa="$($CXL list -r "$region" -D | jq '.[] | select(has("port decoders")) | ."port decoders"[1] | .resource')"

	# endpoint port 0 size
	ep0_size="$($CXL list -r "$region" -D | jq '.[] | select(has("endpoint decoders")) | ."endpoint decoders"[0] | .size')"
	# endpoint port 0 base address
	ep0_hpa="$($CXL list -r "$region" -D | jq '.[] | select(has("endpoint decoders")) | ."endpoint decoders"[0] | .resource')"

	# endpoint port 1 size
	ep1_size="$($CXL list -r "$region" -D | jq '.[] | select(has("endpoint decoders")) | ."endpoint decoders"[1] | .size')"
	# endpoint port 1 base address
	ep1_hpa="$($CXL list -r "$region" -D | jq '.[] | select(has("endpoint decoders")) | ."endpoint decoders"[1] | .resource')"
}

compare_sizes()
{
	# The CXL region size should equal to the CFMWS size.
	# It should be DRAM+CXL size combined
	((cxlrd_size == region_size)) || err "$LINENO"

	# The switch decoder size should be half of CFMWS size.
	((cxlrd_size == swp0_size * 2)) || err "$LINENO"
	((cxlrd_size == swp1_size * 2)) || err "$LINENO"

	# The endpoint decoder size should be half of CFMWS size
	((cxlrd_size == ep0_size * 2)) || err "$LINENO"
	((cxlrd_size == ep1_size * 2)) || err "$LINENO"
}

# The extended linear cache is expected to be DRAM:CXL of 1:1 size
# The CXL region occupies the second half of the CFMWS
compare_bases()
{
	((cxlrd_hpa == swp0_hpa - swp0_size)) || err "$LINENO"
	((cxlrd_hpa == swp1_hpa - swp1_size)) || err "$LINENO"

	((cxlrd_hpa == ep0_hpa - ep0_size)) || err "$LINENO"
	((cxlrd_hpa == ep1_hpa - ep1_size)) || err "$LINENO"
}

find_region
retrieve_info
compare_sizes
compare_bases

check_dmesg "$LINENO"
modprobe -r cxl_test
