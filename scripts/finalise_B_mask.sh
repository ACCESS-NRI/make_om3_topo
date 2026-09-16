#!/usr/bin/env sh
# Copyright 2025 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0
#
# Commit changes and push, then add metadata to note how changes were made
#
# Usage:
#   ./scripts/finalise_B_mask.sh 25km
#   ./scripts/finalise_B_mask.sh 8km
#   ./scripts/finalise_B_mask.sh 100km

set -e
set -x

# Paths below are relative to the repository root, so run from there regardless
# of where this script was invoked.
cd "$(dirname "$0")/.."

case "${1:-25km}" in
  25km)
    NOTEBOOK="notebooks/make_B_mask_25km.ipynb"
    NCFILE="masks/B_mask_25km.nc"
    LABEL="25km"
    ;;
  8km)
    NOTEBOOK="notebooks/make_B_mask_8km.ipynb"
    NCFILE="masks/B_mask_8km.nc"
    LABEL="8km"
    ;;
  100km)
    NOTEBOOK="notebooks/make_B_mask_100km.ipynb"
    NCFILE="masks/B_mask_100km.nc"
    LABEL="100km"
    ;;
  *)
    echo "Usage: $0 [25km|8km|100km]"
    exit 1
    ;;
esac

echo "About to commit ${LABEL} B_mask changes to git repository and push to remote."
read -p "Was ${NCFILE} created by the current version of ${NOTEBOOK}? (y/n) " yesno
case "$yesno" in
  [Yy]) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

module load nco
module load git

git add "$NOTEBOOK"
git commit -m "${NOTEBOOK} on $(date)" || true
git push || true

ncatted -O -h -a history,global,a,c," | Created on $(date) using https://github.com/ACCESS-NRI/make_OM3_025deg_topo/tree/$(git rev-parse --short HEAD)/${NOTEBOOK}" "$NCFILE"

git add "$NCFILE"
git commit -m "${NCFILE} on $(date)" || true
git push || true
