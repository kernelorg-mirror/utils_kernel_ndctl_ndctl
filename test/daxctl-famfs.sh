#!/bin/bash -Ex
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2025 Micron Technology, Inc. All rights reserved.
#
# Test daxctl famfs mode transitions and mode detection, targeting a
# nfit_test-backed dax device.
#
# nfit_test-backed dax devices have real DRAM backing, so kmem onlining
# works normally. This test exercises the full matrix of transitions
# between devdax, famfs, and system-ram.

rc=77
. $(dirname $0)/common

trap 'cleanup $LINENO' ERR

testbus=""
testdev=""
daxdev=""

cleanup()
{
	# Best-effort return to devdax so destroy-namespace can succeed.
	if [[ -n $daxdev ]]; then
		"$DAXCTL" reconfigure-device -f -m devdax "$daxdev" 2>/dev/null || true
	fi
	[[ -n $testdev ]] && reset_dev
	err "$1"
}

check_fsdev_dax()
{
	modinfo fsdev_dax &>/dev/null && return 0
	grep -qF "fsdev_dax" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null && return 0
	do_skip "fsdev_dax module not available"
}

check_kmem()
{
	modinfo kmem &>/dev/null && return 0
	grep -qF "kmem" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null && return 0
	do_skip "kmem module not available"
}

find_testdev()
{
	testbus="$ACPI_BUS"

	# Ensure the bus has labels, like align.sh / daxctl-devices.sh rely on.
	"$NDCTL" disable-region -b "$testbus" all
	"$NDCTL" init-labels -f -b "$testbus" all
	"$NDCTL" enable-region -b "$testbus" all

	testdev=$("$NDCTL" list -b "$testbus" -Ni | jq -er '.[0].dev | .//""')
	[[ $testdev ]] || do_skip "no victim device on $testbus"
}

setup_dev()
{
	test -n "$testbus"
	test -n "$testdev"

	"$NDCTL" destroy-namespace -f -b "$testbus" "$testdev"
	# x86_64 memory hotplug can require up to a 2GiB-aligned chunk of
	# memory. Create a 4GiB namespace, so enough space is left after
	# alignment for kmem + online.
	testdev=$("$NDCTL" create-namespace -b "$testbus" -m devdax -fe "$testdev" -s 4G | \
		jq -er '.dev')
	test -n "$testdev"

	daxdev=$("$NDCTL" list -n "$testdev" -X | jq -er '.[].daxregion.devices[0].chardev')
	test -n "$daxdev"
}

reset_dev()
{
	"$NDCTL" destroy-namespace -f -b "$testbus" "$testdev"
}

daxctl_get_mode()
{
	"$DAXCTL" list -d "$1" | jq -er '.[].mode'
}

save_online_policy()
{
	saved_policy="$(cat /sys/devices/system/memory/auto_online_blocks)"
}

restore_online_policy()
{
	echo "$saved_policy" > /sys/devices/system/memory/auto_online_blocks
}

unset_online_policy()
{
	echo "offline" > /sys/devices/system/memory/auto_online_blocks
}

ensure_devdax_mode()
{
	local mode
	mode=$(daxctl_get_mode "$daxdev")

	case "$mode" in
	devdax)      return 0 ;;
	famfs)       "$DAXCTL" reconfigure-device -m devdax "$daxdev" >/dev/null ;;
	system-ram)  "$DAXCTL" reconfigure-device -f -m devdax "$daxdev" >/dev/null ;;
	*)
		echo "unexpected starting mode: $mode"
		return 1
		;;
	esac

	[[ $(daxctl_get_mode "$daxdev") == "devdax" ]]
}

test_famfs_mode_transitions()
{
	ensure_devdax_mode

	# devdax -> famfs
	"$DAXCTL" reconfigure-device -m famfs "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "famfs" ]]

	# famfs -> famfs (re-enable in same mode)
	"$DAXCTL" reconfigure-device -m famfs "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "famfs" ]]

	# famfs -> devdax
	"$DAXCTL" reconfigure-device -m devdax "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "devdax" ]]

	# devdax -> devdax (re-enable in same mode)
	"$DAXCTL" reconfigure-device -m devdax "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "devdax" ]]
}

test_json_output()
{
	ensure_devdax_mode
	[[ $("$DAXCTL" list -d "$daxdev" | jq -er '.[].mode') == "devdax" ]]

	"$DAXCTL" reconfigure-device -m famfs "$daxdev" >/dev/null
	[[ $("$DAXCTL" list -d "$daxdev" | jq -er '.[].mode') == "famfs" ]]

	"$DAXCTL" reconfigure-device -m devdax "$daxdev" >/dev/null
}

test_error_handling()
{
	"$DAXCTL" reconfigure-device -m famfs "$daxdev" >/dev/null

	# Invalid mode must be rejected
	if "$DAXCTL" reconfigure-device -m invalidmode "$daxdev" &>/dev/null; then
		echo "FAIL: invalid mode should be rejected"
		return 1
	fi

	"$DAXCTL" reconfigure-device -m devdax "$daxdev" >/dev/null
}

# Full system-ram transitions (real backing, so online_pages() works).
# Turns auto-online off so daxctl drives onlining explicitly.
test_system_ram_transitions()
{
	save_online_policy
	unset_online_policy

	ensure_devdax_mode

	# devdax -> system-ram (no-online)
	"$DAXCTL" reconfigure-device -N -m system-ram "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "system-ram" ]]

	# system-ram -> famfs must be rejected
	if "$DAXCTL" reconfigure-device -m famfs "$daxdev" &>/dev/null; then
		echo "FAIL: system-ram -> famfs should be rejected"
		restore_online_policy
		return 1
	fi

	# system-ram -> devdax -> famfs
	"$DAXCTL" reconfigure-device -f -m devdax "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "devdax" ]]
	"$DAXCTL" reconfigure-device -m famfs "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "famfs" ]]

	# Full online cycle: devdax -> system-ram (with online) -> devdax.
	"$DAXCTL" reconfigure-device -m devdax "$daxdev" >/dev/null
	"$DAXCTL" reconfigure-device -m system-ram "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "system-ram" ]]
	"$DAXCTL" reconfigure-device -f -m devdax "$daxdev" >/dev/null
	[[ $(daxctl_get_mode "$daxdev") == "devdax" ]]

	restore_online_policy
}

check_fsdev_dax
check_kmem

rc=1

find_testdev
setup_dev

test_famfs_mode_transitions
test_json_output
test_error_handling
test_system_ram_transitions

ensure_devdax_mode
reset_dev

check_dmesg "$LINENO"
