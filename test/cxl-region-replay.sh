#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2022 Intel Corporation. All rights reserved.

. $(dirname $0)/common

rc=77

set -ex

trap 'err $LINENO' ERR

check_prereq "jq"

modprobe -r cxl_test
modprobe cxl_test

# Replay support is exposed by cxl_acpi after cxl_test loads
if [ ! -e /sys/bus/platform/devices/cxl_acpi.0/decoder_reset_preserve_registry ]; then
	do_skip "test requires decoder registry replay support"
fi

rc=1

# Demonstrate and validate CXL region replay support in cxl_test.
#
# Replay helpers in test/common snapshot the current region topology,
# replay the configuration, and verify that the reconstructed regions
# match the original configuration.
#
# Tests should use the common helper:
#   replay_regions
#
# This test serves as both a sanity check for replay support and an
# example of how other cxl_test unit tests can use replay_regions().

destroy_regions() {
	$CXL destroy-region -f -b cxl_test all
}

create_region() {
	region=$($CXL create-region -d "$decoder" -m "$memdevs" |
		jq -r ".region")

	if [[ ! $region ]]; then
		echo "create-region failed for $decoder"
		err "$LINENO"
	fi
}

create_x2_pmem_region() {
	# Find a pmem-capable x2 decoder
	decoder=$($CXL list -b cxl_test -D -d root | jq -r ".[] |
		select(.pmem_capable == true) |
		select(.nr_targets == 2) |
		.decoder")

	# Select one memdev for each host-bridge interleave position
	port_dev0=$($CXL list -T -d "$decoder" | jq -r ".[] |
		.targets | .[] | select(.position == 0) | .target")
	port_dev1=$($CXL list -T -d "$decoder" | jq -r ".[] |
		.targets | .[] | select(.position == 1) | .target")
	mem0=$($CXL list -M -p "$port_dev0" | jq -r ".[0].memdev")
	mem1=$($CXL list -M -p "$port_dev1" | jq -r ".[0].memdev")
	memdevs="$mem0 $mem1"
	create_region
}

create_x4_ram_region() {
	# Find a volatile-capable x2 decoder
	decoder=$($CXL list -b cxl_test -D -d root | jq -r ".[] |
		select(.volatile_capable == true) |
		select(.nr_targets == 2) |
		.decoder")

	# Select two memdevs for each host-bridge interleave position
	port_dev0=$($CXL list -T -d "$decoder" | jq -r ".[] |
		.targets | .[] | select(.position == 0) | .target")
	port_dev1=$($CXL list -T -d "$decoder" | jq -r ".[] |
		.targets | .[] | select(.position == 1) | .target")
	mem0=$($CXL list -M -p "$port_dev0" | jq -r ".[0].memdev")
	mem1=$($CXL list -M -p "$port_dev1" | jq -r ".[0].memdev")
	mem2=$($CXL list -M -p "$port_dev0" | jq -r ".[1].memdev")
	mem3=$($CXL list -M -p "$port_dev1" | jq -r ".[1].memdev")
	memdevs="$mem0 $mem1 $mem2 $mem3"
	create_region
}

AUTO_MEMDEVS=""
AUTO_ROOT_DECODER=""

capture_auto_region() {
	local region_json dec_json

	region_json=$($CXL list -R --targets)

	# Expect exactly one auto region
	[ "$(jq 'length' <<<"$region_json")" -eq 1 ] || err "$LINENO"

	AUTO_MEMDEVS=$(jq -r '.[0].mappings | sort_by(.position) | .[].memdev' \
		<<<"$region_json" | xargs)
	[[ $AUTO_MEMDEVS ]] || err "$LINENO"

	dec_json=$($CXL list -R --decoders)
	AUTO_ROOT_DECODER=$(jq -r '.[0]["root decoders"][0].decoder' <<<"$dec_json")
	[[ $AUTO_ROOT_DECODER ]] || err "$LINENO"
}

create_user_region_in_auto_region_space() {
	decoder="$AUTO_ROOT_DECODER"
	memdevs="$AUTO_MEMDEVS"
	create_region
}

# To remove the auto region, destroy and recreate in user space.
# With that action, there will be no 'auto' decoders and it will not be
# preserved across acpi rebind.
#
# This is done here as example if test wants the resources freed
remove_auto_region() {
	capture_auto_region
	destroy_regions
	create_user_region_in_auto_region_space
	destroy_regions
	replay_regions || err "$LINENO"
}

# Replay the built-in auto region
[ "$($CXL list -R | jq 'length')" -ne 0 ] || err "$LINENO"
replay_regions || err "$LINENO"

# Remove the built-in auto region to free up resources
remove_auto_region
[ "$($CXL list -R | jq 'length')" -eq 0 ] || err "$LINENO"

# Create and replay a volatile region
create_x4_ram_region
replay_regions || err "$LINENO"

# Add-on a pmem region
create_x2_pmem_region

# Replay both the x4_ram and x2_pmem
replay_regions || err "$LINENO"

check_dmesg "$LINENO"

modprobe -r cxl_test
