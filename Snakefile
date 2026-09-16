# Copyright 2026 ACCESS-NRI and contributors. See the top-level COPYRIGHT file for details.
# SPDX-License-Identifier: Apache-2.0
#
# ACCESS-OM3 topography and derived-input workflow. Replaces config.sh,
# build.sh, gen_topo.sh and finalise.sh.
#
# A resolution must be given on every invocation; there is no default.
#
#   snakemake --config resolution=8km -n --reason   # what would rebuild, and why
#   snakemake --config resolution=8km               # build everything
#   snakemake --config resolution=8km topog.nc      # stop after the topography
#   snakemake --config resolution=8km edit          # launch the editTopo GUI
#   snakemake --config resolution=8km publish       # copy products to staging
#
# Always dry-run first. The default rerun triggers include `code`, so editing
# this file can invalidate the expensive gen_topo step; pass
# `--rerun-triggers mtime` when you know an edit here was cosmetic.

from pathlib import Path
import subprocess

from snakemake.utils import min_version

# `executor: cluster-generic` in profiles/default is Snakemake 8+ syntax.
min_version("8.0")


configfile: "config.yaml"


shell.executable("/bin/bash")
# `module` is a shell function, not a binary, and is not defined in a
# non-interactive shell.
# VERIFY ON GADI, two separate risks:
#   - that /etc/profile.d/modules.sh is the right init path here;
#   - that `set -u` does not break `module`, which in some Lmod/Tcl versions
#     dereferences unset variables. Drop the `u` if module commands misbehave.
shell.prefix("source /etc/profile.d/modules.sh 2>/dev/null || true; set -euo pipefail; ")


RES = config["resolution"]
if RES not in config["resolutions"]:
    raise WorkflowError(
        f"unknown resolution {RES!r}; choose one of {sorted(config['resolutions'])}"
    )
C = config["resolutions"][RES]

MERGE = bool(C["use_bgrid_merge"])
LAYOUT = C.get("masktable_layout")

# Intermediates keep the flat filenames the non-advective_*.ipynb notebooks
# hardcode. Do not add a resolution tag here without updating those notebooks.
INT = "topography_intermediate_output"
# Built once by scripts/build_topogtools.sh, not by this workflow - compiling
# needs intel-compiler/netcdf rather than the conda environment everything else
# uses, and the submodule pointer moves perhaps once a year. Declared as a
# required input, so a missing binary fails immediately with a
# MissingInputException naming this path rather than part-way through a rule.
TT = "bathymetry-tools/bin/topogtools"
EDITTOPO = "bathymetry-tools/editTopo.py"
OM3 = "om3-scripts"

# Module environments, matching what the shell scripts loaded. Snakemake's
# `envmodules:` directive cannot express `module use`, so these are shell
# prefixes instead.
ANALYSIS3 = (
    "module purge && module use /g/data/xp65/public/modules && "
    "module load conda/analysis3-25.11 && "
)
ANALYSIS3_NCO = ANALYSIS3 + "module load nco && "
# gen_topo.sh ran topogtools under conda+nco, not intel+netcdf; the build bakes
# in library paths. Kept identical so output can be compared against the
# current workflow.
TOPOGTOOLS_ENV = ANALYSIS3_NCO
FRE_NCTOOLS = (
    ANALYSIS3
    + "module use /g/data/vk83/modules && "
    + "module load model-tools/fre-nctools/2024.05-1 && "
)
MPI_ENV = (
    "module purge && module use /g/data/xp65/public/modules && "
    "module load conda/analysis3 && module load openmpi/4.1.7 && "
)

# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------

MESH = f"access-om3-{RES}-ESMFmesh.nc"
MESH_NOMASK = f"access-om3-{RES}-nomask-ESMFmesh.nc"
ROF_WEIGHTS = f"access-om3-{RES}-rof-remap-weights.nc"
ROFI_SPREAD = f"access-om3-{RES}-rofi-climatology.nc"
CHL = "chl_globcolour_monthly_clim.nc"
SFE = "SFe_Hamiltonetal2020_monthly_clim.nc"
CO2 = "CO2_gm_1750-2024.nc"
TIDEAMP = "tideamp.nc"
BOTTOM_ROUGHNESS = "bottom_roughness.nc"
MASKTABLE_DIR = "masktable"

# Grid-independent, shared across resolutions, never published.
BR_INTERMEDIATE = "bottom_roughness_intermediate.nc"


def products():
    """Everything `publish` copies into the dated staging directory.

    ocean_hgrid.nc and ocean_vgrid.nc are deliberately absent: they are already
    dated vk83 releases and are referenced by path and md5 in topog.README.md
    rather than duplicated here.
    """
    out = [
        "topog.nc",
        "kmt.nc",
        "topog.README.md",
        MESH,
        MESH_NOMASK,
        ROF_WEIGHTS,
        ROFI_SPREAD,
        CHL,
        SFE,
        CO2,
        TIDEAMP,
        BOTTOM_ROUGHNESS,
    ]
    if LAYOUT:
        out.append(MASKTABLE_DIR)
    return out


STAGING = Path(config["publish_root"]) / f"global.{RES}" / C["release_date"]


rule all:
    input:
        products(),


# ---------------------------------------------------------------------------
# Input staging
# ---------------------------------------------------------------------------


rule stage_hgrid:
    input:
        C["hgrid"],
    output:
        "ocean_hgrid.nc",
    shell:
        "cp -L --preserve=timestamps {input} {output}"


rule stage_vgrid:
    input:
        C["vgrid"],
    output:
        "ocean_vgrid.nc",
    shell:
        "cp -L --preserve=timestamps {input} {output}"


# ---------------------------------------------------------------------------
# Topography chain
# ---------------------------------------------------------------------------


rule gen_topo:
    """Interpolate GEBCO onto the model grid (cell mean altitude)."""
    input:
        gebco=config["gebco"],
        hgrid="ocean_hgrid.nc",
        tt=TT,
    output:
        f"{INT}/topog_new.nc",
    resources:
        mem_mb=50_000,
        walltime="4:00:00",
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} gen_topo -i {input.gebco} -o {output} "
        "--hgrid {input.hgrid} --tripolar --longitude-offset -100"


rule min_dy:
    """Cut off T cells smaller than the cutoff value."""
    input:
        nc=f"{INT}/topog_new.nc",
        hgrid="ocean_hgrid.nc",
        tt=TT,
    output:
        f"{INT}/topog_new_min_dy.nc",
    params:
        cutoff=C["cutoff_value"],
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} min_dy -i {input.nc} -o {output} "
        "--cutoff {params.cutoff} --hgrid {input.hgrid}"


rule fill_fraction:
    """Fill cells with a sea-area fraction below 0.5."""
    input:
        nc=f"{INT}/topog_new_min_dy.nc",
        tt=TT,
    output:
        f"{INT}/topog_new_fillfraction.nc",
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} fill_fraction -i {input.nc} -o {output} "
        "--fraction 0.5"


rule apply_edits:
    """Apply the hand-edit list.

    Covers both applications of edit_<res>_topog.txt: to the C-grid topography,
    and (when merging) to the merged file. The wildcard constraint is
    load-bearing - without it `stage` also matches `fillfraction_B`, whose edits
    come from a different file, and the DAG becomes ambiguous.
    """
    input:
        nc=f"{INT}/topog_new_{{stage}}.nc",
        edits=C["edit_topo"],
        script=EDITTOPO,
    output:
        f"{INT}/topog_new_{{stage}}_edited.nc",
    wildcard_constraints:
        stage="fillfraction|fillfraction_merged",
    shell:
        ANALYSIS3 + "python3 {input.script} --overwrite --nogui "
        "--apply {input.edits} --output {output} {input.nc}"


rule deseas_cgrid:
    """Remove seas under C-grid rules."""
    input:
        nc=f"{INT}/topog_new_{{stage}}_edited.nc",
        tt=TT,
    output:
        f"{INT}/topog_new_{{stage}}_edited_deseas.nc",
    wildcard_constraints:
        stage="fillfraction|fillfraction_merged",
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} deseas -i {input.nc} -o {output} --grid_type C"


rule min_max_depth:
    """Set maximum/minimum depth."""
    input:
        nc=f"{INT}/topog_new_{{stage}}_edited_deseas.nc",
        vgrid="ocean_vgrid.nc",
        tt=TT,
    output:
        f"{INT}/topog_new_{{stage}}_edited_deseas_mindepth.nc",
    wildcard_constraints:
        stage="fillfraction|fillfraction_merged",
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} min_max_depth -i {input.nc} -o {output} "
        "--level 7 --vgrid {input.vgrid} --vgrid_type mom6"


# --- optional B-grid branch ------------------------------------------------


rule mark_bgrid:
    """Copy for the B grid, setting depth:grid_type = "B" so fix_nonadvective runs."""
    input:
        f"{INT}/topog_new_fillfraction_edited_deseas.nc",
    output:
        f"{INT}/topog_new_fillfraction_B.nc",
    shell:
        ANALYSIS3_NCO
        + "ncatted -O --output {output} -a grid_type,depth,o,c,B {input}"


rule apply_edits_bgrid:
    """Edits keeping the Med, Black Sea, Sea of Azov and Gulf of Riga alive under B-grid deseas."""
    input:
        nc=f"{INT}/topog_new_fillfraction_B.nc",
        edits=C["edit_topo_bgrid"],
        script=EDITTOPO,
    output:
        f"{INT}/topog_new_fillfraction_B_edited.nc",
    shell:
        ANALYSIS3 + "python3 {input.script} --overwrite --nogui "
        "--apply {input.edits} --output {output} {input.nc}"


rule fix_nonadvective:
    """Fix B-grid non-advective coastal cells."""
    input:
        nc=f"{INT}/topog_new_fillfraction_B_edited.nc",
        vgrid="ocean_vgrid.nc",
        tt=TT,
    output:
        f"{INT}/topog_new_fillfraction_B_edited_fixnonadvective.nc",
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} fix_nonadvective --coastal-cells "
        "--input {input.nc} --output {output} "
        "--vgrid {input.vgrid} --vgrid_type mom6"


rule deseas_bgrid:
    """Remove seas under B-grid rules."""
    input:
        nc=f"{INT}/topog_new_fillfraction_B_edited_fixnonadvective.nc",
        tt=TT,
    output:
        f"{INT}/topog_new_fillfraction_B_edited_fixnonadvective_deseas.nc",
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} deseas -i {input.nc} -o {output} --grid_type B"


rule combine_by_mask:
    """Merge B- and C-grid versions, using the C-grid version in ice-free regions."""
    input:
        cgrid=f"{INT}/topog_new_fillfraction_edited_deseas.nc",
        bgrid=f"{INT}/topog_new_fillfraction_B_edited_fixnonadvective_deseas.nc",
        mask=C["b_mask"],
        script="scripts/combine_by_mask.py",
    output:
        f"{INT}/topog_new_fillfraction_merged.nc",
    shell:
        ANALYSIS3 + "python3 {input.script} {input.cgrid} {input.bgrid} "
        "{input.mask} {output}"


# ---------------------------------------------------------------------------
# Final topography and masks
# ---------------------------------------------------------------------------


def final_topog(_):
    stem = "fillfraction_merged" if MERGE else "fillfraction"
    return f"{INT}/topog_new_{stem}_edited_deseas_mindepth.nc"


def topog_input_files():
    """External inputs recorded as `input_file` attributes on topog.nc.

    edit_*.txt and B_mask_*.nc are tracked in this repo, so the commit hash
    stamped by `publish` covers their provenance instead.
    """
    files = [C["hgrid"], C["vgrid"], config["gebco"]]
    if MERGE:
        files.append(C["b_mask"])
    return files


rule topog:
    """Name the final topography topog.nc and stamp its external inputs.

    The stamping happens here, on the copy, so the rule's output is final when
    it exits. gen_topo.sh appended these attributes to topog.nc after the fact,
    which duplicated them whenever the workflow was re-run.
    """
    input:
        nc=final_topog,
        stamped=topog_input_files(),
    output:
        "topog.nc",
    shell:
        ANALYSIS3_NCO + "cp {input.nc} {output} && "
        'for f in {input.stamped}; do '
        '  md5=$(md5sum "$f" | awk "{{print \\$1}}"); '
        '  ncatted -O -h -a input_file,global,a,c,"$(readlink -f "$f") (md5sum:$md5) ; " {output}; '
        "done"


rule ocean_mask:
    """Land/sea mask. Intermediate only - kmt.nc is the product."""
    input:
        nc="topog.nc",
        tt=TT,
    output:
        temp("ocean_mask.nc"),
    shell:
        TOPOGTOOLS_ENV + "./{input.tt} mask -i {input.nc} -o {output} && "
        'md5=$(md5sum {input.nc} | awk "{{print \\$1}}"); '
        'ncatted -O -h -a input_file,global,a,c,"$(readlink -f {input.nc}) (md5sum:$md5)" {output}'


rule kmt:
    """CICE mask file."""
    input:
        "ocean_mask.nc",
    output:
        "kmt.nc",
    shell:
        ANALYSIS3_NCO + "ncrename -O -v mask,kmt {input} {output} && "
        "ncks -O -x -v geolon_t,geolat_t {output} {output} && "
        'md5=$(md5sum {input} | awk "{{print \\$1}}"); '
        'ncatted -O -h -a ocean_mask_file,global,a,c,"$(readlink -f {input}) (md5sum:$md5)" {output}'


rule topog_readme:
    """Provenance README for topog.nc/kmt.nc, following the om3-scripts convention."""
    input:
        topog="topog.nc",
        kmt="kmt.nc",
        script="scripts/write_topog_readme.py",
        inputs=[C["hgrid"], C["vgrid"], config["gebco"]],
    output:
        "topog.README.md",
    params:
        runcmd=f"snakemake --config resolution={RES} (use_bgrid_merge={MERGE})",
    shell:
        ANALYSIS3 + 'python3 {input.script} "{params.runcmd}" {input.inputs}'


# ---------------------------------------------------------------------------
# Derived inputs (was the qsub blocks in finalise.sh, now one rule each)
# ---------------------------------------------------------------------------


def rof_grid_size():
    """Tracer-grid dimensions from the MOM supergrid."""
    from netCDF4 import Dataset

    with Dataset("ocean_hgrid.nc") as ds:
        nx = len(ds.dimensions["nx"])
        ny = len(ds.dimensions["ny"])
    if nx % 2 or ny % 2:
        raise WorkflowError(
            f"expected even MOM supergrid dimensions, got nx={nx}, ny={ny}"
        )
    return nx // 2, ny // 2


rule esmf_mesh:
    input:
        hgrid="ocean_hgrid.nc",
        topog="topog.nc",
    output:
        MESH,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3 + f"python3 {OM3}/mesh_generation/generate_mesh.py "
        "--grid-type=mom --grid-filename={input.hgrid} "
        "--mesh-filename={output} --topog-filename={input.topog} --wrap-lons True"


rule esmf_mesh_nomask:
    input:
        hgrid="ocean_hgrid.nc",
    output:
        MESH_NOMASK,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3 + f"python3 {OM3}/mesh_generation/generate_mesh.py "
        "--grid-type=mom --grid-filename={input.hgrid} "
        "--mesh-filename={output} --wrap-lons True"


rule rof_weights:
    input:
        mesh=MESH,
    output:
        ROF_WEIGHTS,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    run:
        nx, ny = rof_grid_size()
        shell(
            ANALYSIS3 + f"python3 {OM3}/mesh_generation/generate_rof_weights.py "
            f"--mesh_filename={input.mesh} --weights_filename={output[0]} "
            f"--nx={nx} --ny={ny}"
        )


rule rofi_pattern:
    input:
        hgrid="ocean_hgrid.nc",
        topog="topog.nc",
    output:
        ROFI_SPREAD,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3 + f"python3 {OM3}/rof_pattern_generation/generate_rofi_pattern.py "
        "--hgrid-filename={input.hgrid} --output-filename={output} "
        "--topog-file={input.topog}"


rule chl_climatology:
    input:
        hgrid="ocean_hgrid.nc",
        forcing=config["globcolour"],
    output:
        CHL,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3 + f"python3 {OM3}/wombat_ic_generation/regrid_forcing.py "
        "--forcing-filename={input.forcing} --hgrid-filename={input.hgrid} "
        "--output-filename={output}"


rule sfe_climatology:
    input:
        hgrid="ocean_hgrid.nc",
        forcing=config["wombat_sfe"],
    output:
        SFE,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3 + f"python3 {OM3}/wombat_ic_generation/regrid_forcing.py "
        "--forcing-filename={input.forcing} --hgrid-filename={input.hgrid} "
        "--output-filename={output}"


rule co2:
    input:
        hgrid="ocean_hgrid.nc",
        cmip=config["co2_cmip"],
        noaa=config["co2_noaa"],
    output:
        CO2,
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3 + f"python3 {OM3}/wombat_ic_generation/co2_iaf.py "
        "--co2-cmip-filename={input.cmip} --co2-noaa-filename={input.noaa} "
        "--hgrid-filename={input.hgrid} --output-filename={output}"


rule tideamp:
    input:
        hgrid="ocean_hgrid.nc",
        topog="topog.nc",
    output:
        TIDEAMP,
    params:
        data=config["tpxo_data"],
    resources:
        mem_mb=190_000,
        walltime="8:00:00",
    shell:
        ANALYSIS3
        + f"python3 {OM3}/external_tidal_generation/generate_tide_amplitude.py "
        "--hgrid-file={input.hgrid} --topog-file={input.topog} "
        "--method=conservative_normed --data-path={params.data} --output={output}"


# --- bottom roughness ------------------------------------------------------
#
# These two rules replace submit_bottom_roughness.sh + pbs_bottom_roughness.pbs.
# Three reasons for the divergence:
#   - the .pbs script ran /g/data/vk83/apps/om3-scripts/... rather than the
#     pinned submodule, so the recorded commit hash did not describe the code
#     that produced bottom_roughness.nc;
#   - it skipped the 52-minute MPI step whenever the intermediate merely existed
#     and was non-empty, with no staleness check;
#   - it held one 72-CPU/500GB allocation across both the MPI step and the
#     1-minute single-CPU regrid.


rule bottom_roughness_intermediate:
    """Grid-independent WOA/SYNBATH roughness. Shared across resolutions, never published."""
    input:
        temp_file=config["woa_temp"],
        salt_file=config["woa_salt"],
        synbath=config["synbath"],
    output:
        BR_INTERMEDIATE,
    threads: 72
    resources:
        mem_mb=500_000,
        walltime="10:00:00",
        queue="normalsr",
    shell:
        MPI_ENV + "mpirun -n {threads} "
        f"python3 {OM3}/external_tidal_generation/generate_bottom_roughness_intermediate_woa.py "
        "--woa_temp_file {input.temp_file} --woa_salt_file {input.salt_file} "
        "--synbath_file {input.synbath} --woa_intermediate_file {output}"


rule bottom_roughness:
    """Regrid the roughness intermediate onto the model grid."""
    input:
        intermediate=BR_INTERMEDIATE,
        hgrid="ocean_hgrid.nc",
        topog="topog.nc",
    output:
        BOTTOM_ROUGHNESS,
    params:
        # 100km uses conservative_normed, everything else bilinear.
        # https://github.com/ACCESS-NRI/om3-scripts/pull/105#issuecomment-3942010809
        method="conservative_normed" if RES == "100km" else "bilinear",
    resources:
        mem_mb=32_000,
        walltime="1:00:00",
    shell:
        ANALYSIS3
        + f"python3 {OM3}/external_tidal_generation/generate_bottom_roughness_regrid.py "
        "--woa_intermediate_file {input.intermediate} --topog_file {input.topog} "
        "--hgrid_file {input.hgrid} --output_file {output} "
        "--method {params.method} --periodic_regrid --periodic_lon_laplace"


rule masktable:
    """Mask tables for the configured processor layout.

    Output is a directory: gen_masktable.py names its files
    mask_table.<n_mask>.<X>x<Y>, where n_mask is discovered by parsing
    FRE-NCtools output and may be adjusted again by the -a compatibility pass,
    so the filenames cannot be declared up front. Nothing consumes them, so a
    directory output costs nothing and adds the failure detection that
    finalise.sh lacked.
    """
    input:
        hgrid="ocean_hgrid.nc",
        topog="topog.nc",
    output:
        directory(MASKTABLE_DIR),
    params:
        x=LAYOUT[0] if LAYOUT else 0,
        y=LAYOUT[1] if LAYOUT else 0,
    resources:
        mem_mb=32_000,
        walltime="2:00:00",
    shell:
        FRE_NCTOOLS + "mkdir -p {output} && "
        f"python3 {OM3}/masktable_generation/gen_masktable.py "
        "-g $(readlink -f {input.hgrid}) -t $(readlink -f {input.topog}) "
        "-l {params.x} {params.y} -m mom6 -a -o {output}"


# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------


def git_state():
    """Return (short_hash, dirty_reason). dirty_reason is None when publishable."""

    def git(*args):
        return subprocess.check_output(["git", *args], text=True).strip()

    if git("status", "--porcelain"):
        return None, "the working tree has uncommitted changes"
    try:
        ahead = git("rev-list", "--count", "@{upstream}..HEAD")
    except subprocess.CalledProcessError:
        return None, "HEAD has no upstream branch"
    if ahead != "0":
        return None, f"{ahead} commit(s) are not pushed"
    return git("rev-parse", "--short", "HEAD"), None


rule publish:
    """Copy products to <publish_root>/global.<res>/<release_date>/ and stamp provenance.

    Refuses unless the working tree is clean and pushed, so the stamped hash
    genuinely describes the code that produced these files. finalise.sh instead
    ran `git commit -am` for you, which defeated the uncommitted/unpushed
    warnings in om3-scripts' own get_provenance_metadata.

    Released directories are immutable: publishing over an existing release
    fails. Bump release_date in config.yaml to cut a new one.
    """
    input:
        products(),
    run:
        sha, dirty = git_state()
        if dirty:
            raise WorkflowError(
                f"refusing to publish: {dirty}.\n"
                "Commit and push first so the stamped commit hash describes "
                "the code that produced these files."
            )
        if STAGING.exists():
            raise WorkflowError(
                f"refusing to publish: {STAGING} already exists.\n"
                "Released directories are immutable - bump release_date in "
                "config.yaml."
            )

        url = f"https://github.com/ACCESS-NRI/make_om3_topo/tree/{sha}"
        shell(f"mkdir -p {STAGING}")
        for item in input:
            shell(f"cp -R --preserve=timestamps {item} {STAGING}/")

        stamp = f" | Created on $(date) using {url}"
        shell(
            ANALYSIS3_NCO
            + f'ncatted -O -h -a history,global,a,c,"{stamp} and based on '
            f'GEBCO_2024 topography" {STAGING}/topog.nc'
        )
        shell(ANALYSIS3_NCO + f'ncatted -O -h -a history,global,a,c,"{stamp}" {STAGING}/kmt.nc')
        for f in ("topog.nc", "kmt.nc"):
            shell(ANALYSIS3_NCO + f"ncatted -O -h -a resolution,global,o,c,{RES} {STAGING}/{f}")

        print(f"Published {RES} release {C['release_date']} to {STAGING}")


# ---------------------------------------------------------------------------
# Interactive entry points (not part of the default DAG)
# ---------------------------------------------------------------------------


rule edit:
    """Launch the editTopo GUI on the C-grid topography, to extend edit_<res>_topog.txt.

    Opens the file with the existing edits already applied, so you can see the
    current coastline. Because --apply is not used, the list written on exit is
    a clean delta of only the new edits, which you then append by hand:

        tail -n +2 topography_intermediate_output/edit_topog_new_fillfraction_edited.txt \\
            >> <edit_topo from config.yaml>

    Skip the first line - a second "editTopo.py edits file version 1" header
    mid-file makes --apply fail with an unhelpful error. Add an explanatory
    comment above each new block, as the existing blocks have.
    """
    input:
        nc=f"{INT}/topog_new_fillfraction_edited.nc",
        script=EDITTOPO,
    shell:
        ANALYSIS3 + "python3 {input.script} {input.nc}"


rule edit_bgrid:
    """Launch the editTopo GUI on the B-grid topography, to extend edit_<res>_topog_Bgrid.txt."""
    input:
        nc=f"{INT}/topog_new_fillfraction_B.nc",
        script=EDITTOPO,
    shell:
        ANALYSIS3 + "python3 {input.script} {input.nc}"
