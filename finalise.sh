#!/usr/bin/env sh
# Copyright 2025 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0
#
# Commit changes and push, then add metadata to note how changes were made

source ./config.sh

echo "About to commit all changes to git repository and push to remote."
read -p "Proceed? (y/n) " yesno
case $yesno in
   [Yy] ) ;;
      * ) echo "Cancelled."; exit 0;;
esac

module load nco
module load git
module use /g/data/xp65/public/modules
module load conda/analysis3-25.11

set -x
set -e

git commit -am "Files used for topo generation on $(date)" || true
git push || true

ncatted -O -h -a history,global,a,c," | Created on $(date) using https://github.com/ACCESS-NRI/make_OM3_025deg_topo/tree/$(git rev-parse --short HEAD) and based on GEBCO_2024 topography" topog.nc
ncatted -O -h -a history,global,a,c," | Created on $(date) using https://github.com/ACCESS-NRI/make_OM3_025deg_topo/tree/$(git rev-parse --short HEAD)" kmt.nc
ncatted -O -h -a history,global,a,c," | Updated on $(date) using https://github.com/ACCESS-NRI/make_OM3_025deg_topo/tree/$(git rev-parse --short HEAD)" ocean_vgrid.nc

for file in topog.nc kmt.nc ocean_vgrid.nc; do
    ncatted -O -h -a resolution,global,o,c,"$RESOLUTION" "$file"
done

# Get grid dimensions from the MOM supergrid
set -- $(python3 - <<'PY'
from netCDF4 import Dataset

with Dataset("ocean_hgrid.nc") as ds:
    nx = len(ds.dimensions["nx"])
    ny = len(ds.dimensions["ny"])

if nx % 2 != 0 or ny % 2 != 0:
    raise SystemExit(f"Expected even MOM supergrid dimensions, got nx={nx}, ny={ny}")

print(nx // 2, ny // 2)
PY
)
ROF_NX=$1
ROF_NY=$2

#Make mesh / weights /wombatlite files
INPUTS_JOB=$(qsub <<EOF
#!/bin/bash
#PBS -q normal
#PBS -N inputs_generation
#PBS -l walltime=8:00:00
#PBS -l ncpus=48
#PBS -l mem=190GB
#PBS -l wd
#PBS -l storage=gdata/ik11+gdata/tm70+gdata/xp65+gdata/vk83+gdata/x77+gdata/av17

module purge
module use /g/data/xp65/public/modules
module load conda/analysis3-25.11

set -x
set -e

# Create ESMF mesh from hgrid and topog.nc
python3 ./om3-scripts/mesh_generation/generate_mesh.py --grid-type=mom --grid-filename=ocean_hgrid.nc --mesh-filename="$ESMF_MESH_FILE" --topog-filename=topog.nc --wrap-lons True

# Create ESMF mesh without mask
python3 ./om3-scripts/mesh_generation/generate_mesh.py --grid-type=mom --grid-filename=ocean_hgrid.nc --mesh-filename="$ESMF_NO_MASK_MESH_FILE" --wrap-lons True

# Create runoff remapping weights
python3 ./om3-scripts/mesh_generation/generate_rof_weights.py --mesh_filename="$ESMF_MESH_FILE" --weights_filename="$ROF_WEIGHTS_FILE" --nx=$ROF_NX --ny=$ROF_NY

# Create iceberg melt spreading pattern
python3 ./om3-scripts/rof_pattern_generation/generate_rofi_pattern.py --hgrid-filename=ocean_hgrid.nc --output-filename="$ROFI_SPREAD_FILE" --topog-file=topog.nc

# Generate chlorophyll climatology
python3 ./om3-scripts/wombat_ic_generation/regrid_forcing.py --forcing-filename=/g/data/ik11/inputs/GlobColour/2026.05.07/cmems_obs-oc_glo_bgc-plankton_my_l4-multi-4km-climatology-filled_P1M.nc --hgrid-filename=ocean_hgrid.nc --output-filename=chl_globcolour_monthly_clim.nc

# Generate wombatlite forcings
python3 ./om3-scripts/wombat_ic_generation/regrid_forcing.py --forcing-filename=/g/data/ik11/inputs/WOMBAT/CESM-MIMI_1980-2015_CAM4-6MEAN_MonthlyDep_Hamiltonetal2020_clim.nc --hgrid-filename=ocean_hgrid.nc --output-filename=SFe_Hamiltonetal2020_monthly_clim.nc
python3 ./om3-scripts/wombat_ic_generation/co2_iaf.py --co2-cmip-filename=/g/data/ik11/inputs/WOMBAT/co2_input4MIPs_GHGConcentrations_CMIP_CR-CMIP-1-0-0_gm_1750-2022.nc --co2-noaa-filename=/g/data/ik11/inputs/WOMBAT/co2_annmean_gl.gml.noaa.gov.txt --hgrid-filename=ocean_hgrid.nc --output-filename=CO2_gm_1750-2024.nc

EOF
)
echo "Submitted tidal amplitude job: $INPUTS_JOB"

# Generate tidal files
TIDAL_JOB=$(qsub <<'EOF'
#!/bin/bash
#PBS -q normal
#PBS -N tidal_amp
#PBS -l walltime=8:00:00
#PBS -l ncpus=48
#PBS -l mem=190GB
#PBS -l wd
#PBS -l storage=gdata/ik11+gdata/tm70+gdata/xp65+gdata/vk83+gdata/x77+gdata/av17

module purge
module use /g/data/xp65/public/modules
module load conda/analysis3-25.11

python3 ./om3-scripts/external_tidal_generation/generate_tide_amplitude.py --hgrid-file=ocean_hgrid.nc --topog-file=topog.nc --method=conservative_normed --data-path=/g/data/ik11/inputs/TPXO10_atlas_v2 --output=tideamp.nc

EOF
)
echo "Submitted tidal amplitude job: $TIDAL_JOB"

bash ./om3-scripts/external_tidal_generation/submit_bottom_roughness.sh -s ./ -r "$RESOLUTION" -p true -g ocean_hgrid.nc -t topog.nc -j ./om3-scripts/external_tidal_generation/pbs_bottom_roughness.pbs