# make_OM3_topo

Makes resolution-specific `topog.nc` MOM6 global bathymetry files for ACCESS-OM3 topography workflows based on the GEBCO 2024 dataset, along with the masks, meshes, forcings and remapping files derived from them. The workflow supports 8km, 25km and 100km grids.

The workflow is a [Snakemake](https://snakemake.readthedocs.io/) pipeline ([`Snakefile`](Snakefile)). Intermediate files are kept in `topography_intermediate_output` so you can check the result of each step. Key stages in the processing are:

- Interpolate GEBCO onto the model grid, setting each cell's altitude to the mean of the GEBCO data within it and setting cells that contain more than 50% land in GEBCO to 100% land in the model (this rule of thumb gives acceptable results in most places but requires some specific fixes to ensure important straits, sills, etc. are well represented).
- Produce a global topography (`topog_new_fillfraction_edited_deseas.nc`) with a coastline suitable for a C-grid (i.e. with 1-cell-wide channels).
- (optional, `use_bgrid_merge: true`) Also create a second topography (`topog_new_fillfraction_B_edited_fixnonadvective_deseas.nc`) with a coastline suitable for both a B-grid and C-grid (i.e. all 1-cell-wide channels are closed off or widened to at least 2 cells); this is identical to the C-grid version apart from coastal points and any embayments/channels that are cut off by closing 1-cell-wide channels. It is then merged with `scripts/combine_by_mask.py` using the mask `masks/B_mask_<res>.nc` such that the B-grid version is used in regions prone to sea ice and the C-grid version everywhere else. This allows the use of B-grid CICE6 with C-grid MOM6 without [ice piling up](https://github.com/ACCESS-NRI/access-om3-configs/issues/1010) in narrow channels and inlets. This step is off by default.
- Further processing and edits to generate the final `topog.nc`.
- Generation of associated `.nc` files based on and consistent with `topog.nc`.

## Repository layout

```
Snakefile              the workflow
config.yaml            per-resolution configuration
profiles/default/      PBS submission settings for NCI Gadi (auto-detected)
edits/                 hand-curated editTopo.py edit lists
masks/                 B-grid merge masks (hand-made inputs)
notebooks/             mask generation and inspection notebooks, run on ARE
scripts/               workflow helpers, plus the one-time build and B_mask setup
bathymetry-tools/      submodule: topogtools, editTopo.py
om3-scripts/           submodule: mesh, forcing and mask-table generation
```

Generated outputs are written to the working directory and are not tracked; `snakemake publish` copies them to the dated staging tree.

## Setup

This repository contains submodules, so clone with

```bash
git clone --recursive https://github.com/ACCESS-NRI/make_om3_topo
cd make_om3_topo
mkdir -p logs
```

Build the `bathymetry-tools` executables once. This is not part of the workflow — it needs `intel-compiler`/`netcdf` rather than the conda environment everything else uses, and only needs repeating when the submodule pointer moves:

```bash
./scripts/build_topogtools.sh
```

Snakemake 8 or newer is required, along with the PBS submission plugin:

```bash
pip install 'snakemake>=8' snakemake-executor-plugin-cluster-generic
```

One working directory builds **one** resolution. The intermediate filenames under `topography_intermediate_output/` carry no resolution tag (the `notebooks/non-advective_*.ipynb` notebooks hardcode them), so use a separate directory per resolution.

Run the Snakemake head process inside a small long-walltime PBS job rather than on a login node — it only submits and waits, so one or two CPUs is enough.

## Workflow Overview

### 1. (optional) Regenerate the B-grid mask

`masks/B_mask_<res>.nc` can be updated with `notebooks/make_B_mask_<res>.ipynb` if needed.

- run `notebooks/make_B_mask_<res>.ipynb` on ARE and check it looks like what you want
- move the resulting `B_mask_<res>.nc` into `masks/`
- run `scripts/finalise_B_mask.sh` to embed its provenance, with the resolution as a positional argument:

```bash
./scripts/finalise_B_mask.sh 25km
```

Note that `masks/B_mask_8km.nc` is **derived from** `masks/B_mask_25km.nc` by nearest-neighbour regridding, so regenerating the 25km mask makes the 8km one stale.

### 2. Configure

Check the per-resolution block in [`config.yaml`](config.yaml) — grid paths, `cutoff_value`, `masktable_layout`, and whether `use_bgrid_merge` is on. Adjust the `storage=` flags and resources in [`profiles/default/config.yaml`](profiles/default/config.yaml) for your project.

### 3. Generate the topography and derived files

Always dry-run first to see what will be rebuilt and why:

```bash
snakemake --config resolution=25km -n --reason
snakemake --config resolution=25km
```

Each step runs as its own PBS job with its own resources. This produces `topog.nc`, `kmt.nc`, and the meshes, remapping weights, tidal fields, bottom roughness, mask tables and WOMBAT-lite forcings needed by OM3.

Because Snakemake tracks what each step depends on, re-running after a change only redoes the affected steps. Note that the default rerun triggers include `code`, so editing the `Snakefile` itself can invalidate the expensive GEBCO interpolation; pass `--rerun-triggers mtime` when you know an edit there was cosmetic.

To stop after the topography and check it before generating everything else, ask for that file by name:

```bash
snakemake --config resolution=25km topog.nc kmt.nc
# inspect (step 4), then continue
snakemake --config resolution=25km
```

The second command reuses the first — the topography is not rebuilt. Any file or rule name works as a target this way, so you can stop at any point in the chain, e.g. `topography_intermediate_output/topog_new_fillfraction.nc`.

To see the dependency graph:

```bash
snakemake --config resolution=25km --dag | dot -Tsvg > dag.svg
```

### 4. Check the output files look OK

- See whether the final topography `topog.nc` and associated `.nc` files look OK. Look carefully for any missing marginal seas, and channels that are too wide or narrow/closed. If there's a problem, you can identify where it arose by inspecting the intermediate outputs in `topography_intermediate_output`.
- Run `notebooks/non-advective_<res>.ipynb` on ARE to see the B-grid changes in the polar coastlines, and check there are no seas/bays without B-grid advective connection to the ocean in `topography_intermediate_output/topog_new_fillfraction_B_edited_fixnonadvective_deseas.nc`. This only applies when `use_bgrid_merge: true` — with the merge off, the B-grid branch is never built and that file will not exist. (There is also currently no `notebooks/non-advective_8km.ipynb`.)

### 5. Fix problems (if any)

Since all outputs are generated from `topog.nc`, problems in any of the outputs can generally be fixed by altering the edits applied when generating `topog.nc`. There are two resolution-specific edit lists, applied by `editTopo.py`:

- `edits/edit_<res>_topog.txt` is always applied, to the C-grid topography. If `use_bgrid_merge: true`, it is applied a second time to the merged file.
- `edits/edit_<res>_topog_Bgrid.txt` is only used when `use_bgrid_merge: true`; it is applied to the B-grid file prior to merging but after the first application of `edits/edit_<res>_topog.txt`. This should apply fixes that are suitable for a global B-grid, e.g. to open the Bosphorus so the Black Sea is retained.

To generate new edits, launch the `editTopo.py` GUI on the right intermediate file:

```bash
snakemake --config resolution=25km edit         # C-grid, extends edit_<res>_topog.txt
snakemake --config resolution=25km edit_bgrid   # B-grid, extends edit_<res>_topog_Bgrid.txt
```

Both open the topography with the existing edits already applied, so you see the current coastline, and the list written when you close the window contains only your new edits. Append them to the relevant file, skipping the first line:

```bash
tail -n +2 topography_intermediate_output/edit_topog_new_fillfraction_edited.txt \
    >> edits/edit_25km_topog.txt
```

The first line must be skipped — a second `editTopo.py edits file version 1` header part-way through the file makes `--apply` fail with an unhelpful error. Add an explanatory comment above each new block, as the existing blocks have; re-editing a cell that already has an entry is fine, since the later entry supersedes the earlier one.

Then return to step 3. Only the steps from `editTopo.py` onward will re-run — the GEBCO interpolation is not repeated.

> **Warning:** avoid edits that create B-grid non-advective cells in ice-prone areas, since `edits/edit_<res>_topog.txt` is applied again after the merge.

### 6. Publish

Once the outputs meet your satisfaction, commit and push your changes through the normal git workflow, then:

```bash
snakemake --config resolution=25km publish
```

This copies the products to

```
/g/data/vk83/prerelease/staging/inputs/access-om3/global.<res>/<release_date>/
```

and stamps the git commit hash into the `.nc` metadata for provenance. `release_date` is set per-resolution in [`config.yaml`](config.yaml); bump it deliberately when cutting a release.

`publish` refuses to run if the working tree has uncommitted changes or unpushed commits, so the stamped hash genuinely describes the code that produced the files. Released directories are immutable — publishing over an existing one fails.

`ocean_hgrid.nc` and `ocean_vgrid.nc` are not republished; they are already dated vk83 releases, and are recorded by path and md5 in `topog.README.md` instead.

## Note on Dependencies

This workflow relies on the **xp65 conda environments** for running the scripts and generating the outputs. As long as you are [a member of the _xp65_ project](https://my.nci.org.au/mancini/project/xp65/members/active), this environment is loaded by the workflow itself. There is data loaded from the `av17`, `ik11`, `vk83` and `xp65` projects.
