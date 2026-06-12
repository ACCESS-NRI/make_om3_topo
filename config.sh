# Copyright 2025 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0

DEFAULT_RESOLUTION="${DEFAULT_RESOLUTION:-25km}"
RESOLUTION_INPUT="${1:-${RESOLUTION:-$DEFAULT_RESOLUTION}}"
INPUT_GEBCO='/g/data/ik11/inputs/GEBCO_2024/GEBCO_2024.nc'

usage() {
    echo "Usage: $0 [25km|100km]" >&2
    echo "Set RESOLUTION=25km or RESOLUTION=100km to use qsub -v instead of a positional argument." >&2
}

require_file() {
    if [ ! -e "$1" ]; then
        echo "Error: required file not found: $1" >&2
        exit 1
    fi
}

case "$(printf '%s' "$RESOLUTION_INPUT" | tr '[:upper:]' '[:lower:]')" in
    25km|025deg|0.25deg)
        RESOLUTION='25km'
        INPUT_HGRID='/g/data/vk83/prerelease/configurations/inputs/access-om3/share/grids/global.25km/2026.06.11/ocean_hgrid.nc'
        INPUT_VGRID='/g/data/vk83/configurations/inputs/access-om3/mom/grids/vertical/global.25km/2025.03.12/ocean_vgrid.nc'
        B_MASK_FILE='B_mask_25km.nc'
        CUTOFF_VALUE=6000
        ESMF_MESH_FILE='access-om3-25km-ESMFmesh.nc'
        ESMF_NO_MASK_MESH_FILE='access-om3-25km-nomask-ESMFmesh.nc'
        ROF_WEIGHTS_FILE='access-om3-25km-rof-remap-weights.nc'
        ROFI_SPREAD_FILE='access-om3-25km-rofi-climatology.nc'
        EDIT_TOPO_FILE='edit_25km_topog.txt'
        EDIT_TOPO_BGRID_FILE='edit_25km_topog_Bgrid.txt'
        ;;
    100km)
        RESOLUTION='100km'
        INPUT_HGRID='/g/data/vk83/prerelease/configurations/inputs/access-om3/mom/grids/mosaic/global.100km/2026.03.13/ocean_hgrid.nc'
        INPUT_VGRID='/g/data/vk83/configurations/inputs/access-om3/mom/grids/vertical/global.25km/2025.03.12/ocean_vgrid.nc'
        B_MASK_FILE='B_mask_100km.nc'
        CUTOFF_VALUE=15400
        ESMF_MESH_FILE='access-om3-100km-ESMFmesh.nc'
        ESMF_NO_MASK_MESH_FILE='access-om3-100km-nomask-ESMFmesh.nc'
        ROF_WEIGHTS_FILE='access-om3-100km-rof-remap-weights.nc'
        ROFI_SPREAD_FILE='access-om3-100km-rofi-climatology.nc'
        EDIT_TOPO_FILE='edit_100km_topog.txt'
        EDIT_TOPO_BGRID_FILE='edit_100km_topog_Bgrid.txt'
        ;;
    *)
        usage
        exit 1
        ;;
esac

require_file "$INPUT_HGRID"
require_file "$INPUT_VGRID"
require_file "$INPUT_GEBCO"
require_file "$B_MASK_FILE"
require_file "$EDIT_TOPO_FILE"
require_file "$EDIT_TOPO_BGRID_FILE"