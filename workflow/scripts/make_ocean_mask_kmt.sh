#!/usr/bin/env bash
# ocean_mask.nc + kmt.nc from a SUPPLIED topography.
#
# Runs exactly the commands gen_topo.sh uses for this step (topogtools mask ->
# record topog md5 -> ncrename mask->kmt -> drop unused vars -> record
# ocean_mask md5), so the provenance records are format-identical. Needed only
# for the `supplied` provider; with `generate`, gen_topo.sh produces these itself.
#
# Unlike gen_topo.sh this writes into an output directory outside the repository.
set -euo pipefail
TOPOG="$1"; OUTDIR="$2"; TOPOGTOOLS="$3"

module purge >/dev/null 2>&1 || true
module use /g/data/xp65/public/modules
module load conda/analysis3-26.02
module load nco 2>/dev/null || true

mkdir -p "$OUTDIR"; cd "$OUTDIR"

cp -f "$TOPOG" ./topog_for_mask.nc
"$TOPOGTOOLS" mask -i topog_for_mask.nc -o ocean_mask.nc

MD5SUM_topog=$(md5sum "$TOPOG" | awk '{print $1}')
ncatted -O -h -a input_file,global,a,c,"$(readlink -f "$TOPOG") (md5sum:$MD5SUM_topog)" ocean_mask.nc

ncrename -O -v mask,kmt ocean_mask.nc kmt.nc
ncks -O -x -v geolon_t,geolat_t kmt.nc kmt.nc

MD5SUM_mask=$(md5sum ocean_mask.nc | awk '{print $1}')
ncatted -O -h -a ocean_mask_file,global,a,c,"$(readlink -f "$OUTDIR/ocean_mask.nc") (md5sum:$MD5SUM_mask)" kmt.nc

rm -f topog_for_mask.nc
ls -la ocean_mask.nc kmt.nc
