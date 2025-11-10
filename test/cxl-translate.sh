#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2025 Intel Corporation. All rights reserved.

# Note about ShellCheck disables in this script:
#
# Arrays in this script are passed by name into helper functions using Bash's
# nameref feature `declare -n`. This pattern supports writing generic test
# harnesses that can iterate over many different test vector arrays simply by
# passing the array name. ShellCheck doesn't track nameref indirection, so it
# incorrectly reports these arrays as unused (SC2034). At runtime they are
# fully used through the nameref, so these warnings are safe to ignore.

# source common to get the err() only
. "$(dirname "$0")"/common

modinfo cxl_translate &>/dev/null || modinfo cxl_translate &>/dev/null ||
	do_skip "test requires cxl_translate kernel module"

trap 'err $LINENO' ERR
set -ex
rc=1

MODULO=0
XOR=1

# Test against 'Sample Sets' and 'XOR Tables'
#
# Sample Set's have a pattern and the expected HPAs have been verified
# although maybe not published. They verify Modulo and XOR translations.
#
# XOR Table's are extracted from the CXL Driver Writers Guide [1].
# Although the XOR Tables do not include an explicit check of the Modulo
# translation result, a Modulo calculation is always the first step in
# any XOR calculation. ie. if Modulo fails so does XOR.
#
# [1] https://www.intel.com/content/www/us/en/content-details/643805/cxl-memory-device-sw-guide.html

# Start time for kernel log checking at millisecond granularity
set_log_start_time() {
	log_start_time=$(date '+%Y-%m-%d %H:%M:%S.%3N')
}

check_dmesg_results() {
	local nr_entries=$1
	local expect_failures=${2:-false} # Optional param, builtin true|false
	local log nr_pass nr_fail

	log=$(journalctl --reverse --dmesg --since "$log_start_time")

	nr_pass=$(echo "$log" | grep -c "CXL Translate Test.*PASS") || nr_pass=0
	nr_fail=$(echo "$log" | grep -c "CXL Translate Test.*FAIL") || nr_fail=0

	if $expect_failures; then
		# Expect no PASS and all FAIL
		[ "$nr_pass" -eq 0 ] || err "$LINENO"
		[ "$nr_fail" -eq "$nr_entries" ] || err "$LINENO"
	else
		# Expect all PASS and no FAIL
		[ "$nr_pass" -eq "$nr_entries" ] || err "$LINENO"
		[ "$nr_fail" -eq 0 ] || err "$LINENO"
	fi
}

# Sample Sets
#
# params_#: dpa, region eiw, region eig, host bridge ways
# expect_[modulo|xor]_#: expected spa for each position in the region
# 	interleave set for the modulo|xor math.
#
# Feeds the parameters with an expected SPA for each position in the region
# interleave to the test module. Returns success if the calculation matches
# the expected SPA and the reverse calculation returns the original DPA and
# position.

# 4 way region interleave using 4 host bridges
# Notation: 1+1+1+1

# shellcheck disable=SC2034
declare -A Sample_4R_4H=(
	["params_0"]="0 2 0 4"
	["expect_modulo_0"]="0 256 512 768"
	["expect_xor_0"]="0 256 512 768"
	["params_1"]="256 2 0 4"
	["expect_modulo_1"]="1024 1280 1536 1792"
	["expect_xor_1"]="1024 1280 1536 1792"
	["params_2"]="2048 2 0 4"
	["expect_modulo_2"]="8192 8448 8704 8960"
	["expect_xor_2"]="8192 8448 8704 8960"
)

# 12 way region interleave using 12 host bridges
# Notation: 1+1+1+1+1+1+1+1+1+1+1+1

# shellcheck disable=SC2034
declare -A Sample_12R_12H=(
	["params_0"]="0 10 0 12"
	["expect_modulo_0"]="0 256 512 768 1024 1280 1536 1792 2048 2304 2560 2816"
	["expect_xor_0"]="0 256 512 768 1024 1280 1536 1792 2304 2048 2816 2560"
	["params_1"]="512 10 0 12"
	["expect_modulo_1"]="6144 6400 6656 6912 7168 7424 7680 7936 8192 8448 8704 8960"
	["expect_xor_1"]="6912 6656 6400 6144 7936 7680 7424 7168 8192 8448 8704 8960"
)

decode_r_eiw() {
	case $1 in
	0) echo 1 ;;
	1) echo 2 ;;
	2) echo 4 ;;
	3) echo 8 ;;
	4) echo 16 ;;
	8) echo 3 ;;
	9) echo 6 ;;
	10) echo 12 ;;
	*)
		echo "Invalid r_eiw value: $1"
		err "$LINENO"
		;;
	esac
}

generate_sample_tests() {
	local -n input_sample_set=$1
	local -n output_array=$2

	# Find all params_* keys and extract the index
	local indices=()
	for key in "${!input_sample_set[@]}"; do
		if [[ $key =~ ^params_([0-9]+)$ ]]; then
			indices+=("${BASH_REMATCH[1]}")
		fi
	done

	# Sort indices to process in order
	mapfile -t indices < <(printf '%s\n' "${indices[@]}" | sort -n)

	for i in "${indices[@]}"; do
		# Split the parameters and expected spa values
		IFS=' ' read -r dpa r_eiw r_eig hb_ways <<<"${input_sample_set["params_$i"]}"
		IFS=' ' read -r -a expect_modulo_values <<<"${input_sample_set["expect_modulo_$i"]}"
		IFS=' ' read -r -a expect_xor_values <<<"${input_sample_set["expect_xor_$i"]}"

		ways=$(decode_r_eiw "$r_eiw")
		for ((pos = 0; pos < ways; pos++)); do
			expect_spa_modulo=${expect_modulo_values[$pos]}
			expect_spa_xor=${expect_xor_values[$pos]}

			# Add the MODULO test case, then the XOR test case
			output_array+=("$dpa $pos $r_eiw $r_eig $hb_ways $MODULO $expect_spa_modulo")
			output_array+=("$dpa $pos $r_eiw $r_eig $hb_ways $XOR $expect_spa_xor")
		done
	done
}

test_sample_sets() {
	local sample_name=$1
	# shellcheck disable=SC2034
	local -n sample_set=$1
	local generated_tests=()

	generate_sample_tests sample_set generated_tests

	IFS=','
	table_string="${generated_tests[*]}"
	IFS=' '

	echo "Testing $sample_name with ${#generated_tests[@]} test entries"
	set_log_start_time
	rmmod cxl-translate 2>/dev/null || true
	modprobe cxl_translate "table=$table_string"
	check_dmesg_results "${#generated_tests[@]}"
}

# XOR Tables
#
# The tables that follow are the XOR translation examples in the
# CXL Driver Writers Guide Sections 2.13.24.1 and 25.1
# Note that the Guide uses the device number in its table notation.
# Here the 'position' of that device number is used, not the
# device number itself, which is meaningless in this context.
#
# Format: "dpa pos r_eiw r_eig hb_ways xor_math(0|1) xor_spa:

# 4 way region interleave using 4 host bridges
# Notation: 1+1+1+1

# shellcheck disable=SC2034
XOR_Table_4R_4H=(
	"248   0 2 0 4 1 248"
	"16    1 2 0 4 1 272"
	"16    2 2 0 4 1 528"
	"32    3 2 0 4 1 800"
	"288   0 2 0 4 1 1056"
	"288   1 2 0 4 1 1312"
	"288   2 2 0 4 1 1568"
	"288   3 2 0 4 1 1824"
	"544   1 2 0 4 1 2080"
	"544   0 2 0 4 1 2336"
	"544   3 2 0 4 1 2592"
	"1040  2 2 0 4 1 4112"
	"1568  3 2 0 4 1 6176"
	"32784 1 2 0 4 1 131088"
	"65552 2 2 0 4 1 262160"
	"98336 3 2 0 4 1 393248"
	"98328 2 2 0 4 1 393496"
	"98352 2 2 0 4 1 393520"
	"443953523 0 2 0 4 1 1775813747"
)

# shellcheck disable=SC2034
XOR_Table_8R_4H=(
	"248       0 3 0 4 1 248"
	"16        1 3 0 4 1 272"
	"16        2 3 0 4 1 528"
	"32        3 3 0 4 1 800"
	"272       1 3 0 4 1 2064"
	"528       2 3 0 4 1 4112"
	"800       3 3 0 4 1 6176"
	"16400     1 3 0 4 1 131088"
	"32784     2 3 0 4 1 262160"
	"49184     3 3 0 4 1 393248"
	"49176     2 3 0 4 1 393496"
	"49200     2 3 0 4 1 393520"
	"116520373 3 3 0 4 1 932162229"
	"244690459 5 3 0 4 1 1957525275"
	"292862215 5 3 0 4 1 2342899463"
	"30721158  4 3 0 4 1 245769350"
	"246386959 4 3 0 4 1 1971096847"
	"72701249  5 3 0 4 1 581610561"
	"529382429 5 3 0 4 1 4235060509"
	"191132300 2 3 0 4 1 1529057420"
	"18589081  1 3 0 4 1 148712089"
	"344295715 7 3 0 4 1 2754367011"
)

# shellcheck disable=SC2034
XOR_Table_12R_12H=(
	"224 0 10 0 12 1 224"
	"16  1 10 0 12 1 272"
	"16  2 10 0 12 1 528"
	"32  3 10 0 12 1 800"
	"32  4 10 0 12 1 1056"
	"32  5 10 0 12 1 1312"
	"32  6 10 0 12 1 1568"
	"32  7 10 0 12 1 1824"
	"32  9 10 0 12 1 2080"
	"32  8 10 0 12 1 2336"
	"32 11 10 0 12 1 2592"
	"32 10 10 0 12 1 2848"
	"288 0 10 0 12 1 3360"
	"299017087 7 10 0 12 1 3588205439"
	"329210435 0 10 0 12 1 3950524995"
	"151050637 11 10 0 12 1 1812608653"
	"145169214  2 10 0 12 1 1742030654"
	"328998732 10 10 0 12 1 3947985996"
	"159252439  3 10 0 12 1 1911027415"
	"342098916  5 10 0 12 1 4105186020"
	"97970344   8 10 0 12 1 1175645096"
	"214995572  8 10 0 12 1 2579948404"
	"101289661  7 10 0 12 1 1215475645"
	"40424079   7 10 0 12 1 485088911"
	"231458716  7 10 0 12 1 2777503900"
)

# A fail table entry is expected to fail the DPA->SPA calculation.
# Intent is to show that the test module can tell good from bad.
# If one of these cases passes, don't trust other pass results.
# This is not a test of module parsing, so don't send garbage.

# shellcheck disable=SC2034
Expect_Fail_Table=(
	"544   3 2 0 4 1 2080" # Change position
	"544   2 2 0 4 1 2336"
	"544   1 2 0 4 1 2592"
	"272   1 2 0 4 1 2064" # Change r_eiw
	"528   2 1 0 4 1 4112"
	"800   3 10 0 4 1 6176"
	"32  4 10 0 12 1 1156" # Change expected spa
	"32  5 10 0 12 1 1112"
	"32  6 10 0 12 1 1168"
	"32  7 10 0 12 1 1124"
)

test_tables() {
	local table_name=$1
	local -n table_ref=$1
	local expect_failures=${2:-false} # Optional param, builtin true|false
	local IFS

	IFS=','
	table_string="${table_ref[*]}"
	IFS=' '

	if $expect_failures; then
		echo "Testing $table_name with ${#table_ref[@]} entries (expecting FAIL results)"
	else
		echo "Testing $table_name with ${#table_ref[@]} test entries"
	fi

	set_log_start_time
	rmmod cxl-translate 2>/dev/null || true
	modprobe cxl_translate "table=$table_string"
	check_dmesg_results "${#table_ref[@]}" "$expect_failures"
}

test_internal() {
	echo "Running internal validation..."
	set_log_start_time
	rmmod cxl-translate 2>/dev/null || true
	modprobe cxl_translate

	local log
	log=$(journalctl --reverse --dmesg --since "$log_start_time")

	if echo "$log" | grep -q "Internal validation test completed successfully"; then
		echo "Internal validation test: PASS"
	else
		echo "Internal validation test: FAIL"
		err "$LINENO"
	fi
}

# Each test function rmmods cxl_translate before modprobe so new test
# parameters take effect. Full teardown is deferred until the end of
# all test runs to avoid repeated reprobes of non CXL-test devices.

test_internal
test_tables Expect_Fail_Table true
test_sample_sets Sample_4R_4H
test_sample_sets Sample_12R_12H
test_tables XOR_Table_4R_4H
test_tables XOR_Table_8R_4H
test_tables XOR_Table_12R_12H

modprobe -r cxl_translate
echo "Translate unit test completed with no failures"
