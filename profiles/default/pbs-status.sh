#!/usr/bin/env bash
# Copyright 2026 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0
#
# Job-status probe for snakemake-executor-plugin-cluster-generic on PBS Pro.
# Takes a job id and prints exactly one of: success, failed, running.
#
# `qstat -x` reports finished jobs from the retained-job records. Those records
# expire, so a job id that qstat no longer knows about is treated as success -
# Snakemake's own output-file check is the real completion test.

set -uo pipefail

jobid="$1"

state=$(qstat -xf "$jobid" 2>/dev/null | awk -F'= *' '/job_state/ {print $2; exit}')

case "$state" in
    F)
        exit_status=$(qstat -xf "$jobid" 2>/dev/null | awk -F'= *' '/Exit_status/ {print $2; exit}')
        if [[ "${exit_status:-0}" == "0" ]]; then
            echo success
        else
            echo failed
        fi
        ;;
    E | H | Q | R | S | T | W | M)
        echo running
        ;;
    "")
        # Unknown job id: the retained record has expired.
        echo success
        ;;
    *)
        echo running
        ;;
esac
