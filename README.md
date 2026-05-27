# make_OM3_topo

Makes resolution-specific `topog.nc` MOM6 global bathymetry files for ACCESS-OM3 topography workflows based on the GEBCO 2024 dataset. The current workflow supports both 25km and 100km grids.

The workflow [`gen_topo.sh`](https://github.com/ACCESS-NRI/make_om3_topo/blob/main/gen_topo.sh) contains many steps, and stores intermediate files in `topography_intermediate_output` so you can check the result of each step. Key stages in the processing are:
- Interpolate GEBCO onto the model grid, setting each cell's altitude to the mean of the GEBCO data within it and setting cells that contain more than 50% land in GEBCO to 100% land in the model (this rule of thumb gives acceptable results in most places but requires some specific fixes to ensure important straits, sills, etc. are well represented).
- Create two global topographies, one (`topog_new_fillfraction_edited_deseas.nc`) with a coastline suitable for a C-grid (i.e. with 1-cell-wide channels) and another (`topog_new_fillfraction_B_edited_fixnonadvective_deseas.nc`) with a coastline suitable for both a B-grid and C-grid (i.e. all 1-cell-wide channels are closed off or widened to at least 2 cells); these are identical apart from coastal points and any embayments/channels that are cut off by closing 1-cell-wide channels in the B-grid version.
- These are then merged with `combine_by_mask.py` using the mask `B_mask.nc` such the B-grid version is used in regions prone to sea ice and the C-grid version everywhere else. This allows the use of B-grid CICE6 with C-grid MOM6 without [ice piling up](https://github.com/ACCESS-NRI/access-om3-configs/issues/1010) in narrow channels and inlets.
- Further processing and edits to generate the final `topog.nc`.
- Generation of associated .nc files based on and consistent with `topog.nc`.

## Workflow Overview

1. **Download to Gadi**

   This repository contains submodules, so clone with
   ```bash
   git clone --recursive https://github.com/ACCESS-NRI/make_om3_topo
   cd make_om3_topo
   ```

2. (optional) **Regenerate B-grid mask**

   `B_mask.nc` can be updated with `make_B_mask.ipynb` if needed

   - run `make_B_mask_xxkm.ipynb` on ARE and check it looks like what you want
   - move `~/B_mask_xxkm.nc` to topog generation directory so it can be used in workflow
   - run `finalise_B_mask.sh` to embed its provenance. A positional argument specifying the resolution is required:
  ```bash
   ./finalise_B_mask.sh 25km
   ./finalise_B_mask.sh 100km
   ```

3. **Generate Topography**
   Use `./gen_topo.sh` to generate the topography and associated files. The script selects the 25km or 100km workflow from a single `case` block.

   - add gdata for your project & working directory to the `#PBS -l storage=` line in `gen_topo.sh`
   - check/adjust the per-resolution configuration block in `gen_topo.sh` and `finalise.sh`
   - for smaller cases such as 100km you can run with a positional argument; for 25km submit with qsub using RESOLUTION:
   ```bash
   ./gen_topo.sh 100km
   qsub -v RESOLUTION=25km -P $PROJECT gen_topo.sh
   ```
   - after generating the topography, this will then generate most other masks, forcing and remapping files needed by OM3

4. **Check the output files look OK**

   - See whether the final topography `topog.nc` and associated .nc files look OK. Look carefully for any missing marginal seas, and channels that are too wide or narrow/closed. If there's a problem, you can identify where it arose by inspecting the intermediate outputs in `topography_intermediate_output`.
   - Run `non-advective.ipynb` on ARE to see the B-grid changes in the polar coastlines, and check there are no seas/bays without B-grid advective connection to the ocean in `topography_intermediate_output/topog_new_fillfraction_B_edited_fixnonadvective_deseas.nc`.

5. **Fix problems (if any)**

   Since all outputs are generated from `topog.nc`, problems in any of the outputs can generally be fixed by altering the edits applied as part of generating `topog.nc` in the workflow. There are two resolution-specific files containing lists of edits, which are applied by `editTopo.py` in [`gen_topo.sh`](https://github.com/ACCESS-NRI/make_om3_topo/blob/main/gen_topo.sh):
   - edit_025deg_topog.txt is applied twice, once to the precursor to the B- and C-grid files which are later merged, and then again to the merged file.  
   - edit_025deg_topog_Bgrid.txt is applied only to the B-grid file prior to merging but after the first application of edit_025deg_topog.txt. This should apply fixes that are suitable for a global B-grid, e.g. to open the Bosphorus so the Black Sea is retained.
   - For the 100 km workflow, the same procedure is used, but with the corresponding edit files `edit_100km_topog.txt` and `edit_100km_topog_Bgrid.txt`.
   - Run `bathymetry-tools/editTopo.py` on the appropriate intermediate files to generate new lists of edits which can be appended (with explanatory comments) to the relevant edit file for your chosen resolution.
   - Return to step 3 to check that the updated workflow does what you want.

6. **Finalise Output Files**

   Once the output files meet your satisfaction, to commit and push the changes run `finalise.sh`. This adds the git commit hash as metadata in the output `.nc` files for provenance. This then triggers creation of the other input/forcing files which depends on the grid and bathymetry, including ESMF mesh files, tidal and wombatlite forcings. A positional argument specifying the resolution is required:
  ```bash
   ./finalise.sh 25km
   ./finalise.sh 100km
   ```

## Note on Dependencies  

This workflow relies on the **xp65 conda environments** for running the scripts and generating the outputs. As long as you are [a member of the _xp65_ project](https://my.nci.org.au/mancini/project/xp65/members/active), this conda environment is loaded as part of the scripts. There's is data loaded from the `av17`, `ik11` and `xp65` projects.
