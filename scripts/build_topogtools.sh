#!/usr/bin/env bash
# Copyright 2024 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0
#
# Build the bathymetry-tools executables. One-time setup, not part of the
# Snakemake workflow: compiling needs intel-compiler/netcdf rather than the
# conda environment the workflow uses, and the submodule pointer moves rarely.
#
# Re-run this after moving the bathymetry-tools submodule.
#
# Usage:
#   ./scripts/build_topogtools.sh

set -eu

# Paths below are relative to the repository root, so run from there regardless
# of where this script was invoked.
cd "$(dirname "$0")/.."

module purge
module load intel-compiler
module load netcdf

cd ./bathymetry-tools/

# Check if the build directory exists before cleaning
if [ -d "build" ]; then
  cmake --build build --target clean
fi

cmake -B build -DCMAKE_BUILD_TYPE=Release -DNetCDF_Fortran_LIBRARY=$NETCDF_ROOT/lib/Intel/libnetcdff.so -DNetCDF_C_LIBRARY=$NETCDF_ROOT/lib/libnetcdf.so -DNetCDF_Fortran_INCLUDE_DIRS=$NETCDF_ROOT/include/Intel

cmake --build build

cmake --install build --prefix=./

cd ../

echo
echo "Built: bathymetry-tools/bin/topogtools"
