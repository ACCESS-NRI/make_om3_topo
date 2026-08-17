#!/usr/bin/env python3
# Copyright 2025 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0

"""
Write a README.md for topog.nc and kmt.nc, following the same provenance
convention used by the om3-scripts (see om3-scripts/scripts_common.py).
Intended to be run as the last step of gen_topo.sh.

Usage:
    python3 write_topog_readme.py <runcmd> <input_file> [<input_file> ...]
"""

import sys
from pathlib import Path

sys.path.append(str(Path(__file__).parent / "om3-scripts"))

from scripts_common import get_provenance_metadata

if __name__ == "__main__":
    runcmd = sys.argv[1]
    input_files = sys.argv[2:]

    get_provenance_metadata(
        input_files=input_files,
        runcmd=runcmd,
        output_filename=["topog.nc", "kmt.nc"],
        output_dir=".",
        licence="CC BY 4.0; Public Domain (GEBCO Grid)",
    )
