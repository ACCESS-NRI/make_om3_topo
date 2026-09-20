#!/usr/bin/env python3
"""
Verify the input-provenance records the generation scripts already wrote.

What this checks
----------------
Each generated product carries, in its own metadata, the filenames and hashes of
the inputs it was built from:

  * gen_topo.sh style  : `input_file = "<path> (md5sum:<hash>) ; <path> (md5sum:<hash>)"`
                         `ocean_mask_file = "<path> (md5sum:<hash>)"`
  * om3-scripts style  : `inputFile  = "<path> (md5 hash: <hash>), <path> (md5 hash: <hash>)"`
  * mask table (text)  : '#' comment lines listing `<path> (sha256: <hash>)`

For every recorded entry this compares the RECORDED hash against a freshly
computed hash of the input THIS WORKFLOW selected for that role.

The distinction matters and is the whole point: the recorded path frequently
points at a staging directory that is not what the workflow used, and that file
may since have been superseded. Hashing the file at the recorded path would
happily "confirm" a stale input. So the recorded path is used only to identify
WHICH input a record refers to (by basename); the hash is then compared against
the workflow's own input for that role.

These are input-provenance checks. They never compare a product's own hash with
an input's hash.

Failure conditions
------------------
  * missing required provenance attribute, or no records at all
  * a recorded input that cannot be resolved to a declared workflow input
  * a basename that resolves ambiguously
  * any recorded hash that differs from the workflow input's actual hash
  * `require_topog` set but no topog.nc record present

A mismatch is never to be "fixed" by rewriting the recorded hash: regenerate the
affected product from the correct inputs and verify again.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import netCDF4 as nc

# `<path> (md5sum:<hash>)`  |  `<path> (md5 hash: <hash>)`  |  `<path> (sha256: <hash>)`
RECORD_RE = re.compile(
    r"(?P<path>[^\s;,()][^;,()]*?)\s*\(\s*(?:md5sum|md5 hash|sha256)\s*:\s*(?P<hash>[0-9a-fA-F]{32,64})\s*\)"
)

_HASH_CACHE: dict[tuple[str, str], str] = {}


def file_hash(path: Path, algorithm: str = "md5") -> str:
    key = (str(path), algorithm)
    if key in _HASH_CACHE:
        return _HASH_CACHE[key]
    digest = hashlib.new(algorithm)
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    _HASH_CACHE[key] = digest.hexdigest()
    return _HASH_CACHE[key]


@dataclass
class Record:
    product: str
    attribute: str
    recorded_path: str
    recorded_hash: str
    role: str | None = None
    workflow_path: str | None = None
    actual_hash: str | None = None
    status: str = "UNKNOWN"
    note: str = ""

    def as_dict(self):
        return {
            "product": self.product,
            "attribute": self.attribute,
            "recorded_path": self.recorded_path,
            "recorded_hash": self.recorded_hash,
            "resolved_role": self.role,
            "workflow_input_path": self.workflow_path,
            "actual_hash": self.actual_hash,
            "status": self.status,
            "note": self.note,
        }


@dataclass
class ProductResult:
    name: str
    path: str
    exists: bool
    records: list[Record] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return (
            self.exists
            and not self.problems
            and all(r.status in ("PASS", "SKIP") for r in self.records)
            and any(r.status == "PASS" for r in self.records)
        )


def read_netcdf_records(product: str, path: Path, attributes: list[str]):
    """Extract (attribute, path, hash) records from the named global attributes."""
    records, problems = [], []
    with nc.Dataset(path) as ds:
        available = set(ds.ncattrs())
        for attr in attributes:
            if attr not in available:
                problems.append(
                    f"required provenance attribute '{attr}' is missing "
                    f"(present: {sorted(available)})"
                )
                continue
            text = str(ds.getncattr(attr))
            found = RECORD_RE.findall(text)
            if not found:
                problems.append(
                    f"attribute '{attr}' carries no parseable '<path> (hash)' records"
                )
            for p, h in found:
                records.append(Record(product, attr, p.strip(), h.lower()))
    return records, problems


def read_text_records(product: str, path: Path):
    """Mask-table style: '#' comment lines carrying '<path> (sha256: <hash>)'."""
    records, problems = [], []
    any_found = False
    for line in path.read_text().splitlines():
        if not line.lstrip().startswith("#"):
            continue
        for p, h in RECORD_RE.findall(line.lstrip("#").strip()):
            any_found = True
            records.append(Record(product, "#comment", p.strip().split()[-1], h.lower()))
    if not any_found:
        problems.append("no parseable '<path> (hash)' records found in comment header")
    return records, problems


def resolve_roles(records: list[Record], roles: dict[str, str], product: str):
    """
    Map each record to a declared workflow input by BASENAME, then hash the
    workflow's file - not the recorded path.
    """
    problems = []
    for rec in records:
        base = Path(rec.recorded_path).name
        # The generating script itself is recorded in `history`-like strings; it
        # is not an input, so it is skipped rather than treated as unresolved.
        if base.endswith((".py", ".sh")):
            rec.status = "SKIP"
            rec.note = "generating script, not an input"
            continue
        matches = [r for r in roles if r == base]
        if not matches:
            rec.status = "FAIL"
            rec.note = (
                f"recorded input '{base}' is not a declared workflow input; cannot "
                "confirm what it refers to"
            )
            problems.append(f"{product}: unresolved recorded input '{rec.recorded_path}'")
            continue
        if len(matches) > 1:
            rec.status = "FAIL"
            rec.note = f"ambiguous: '{base}' matches multiple declared roles {matches}"
            problems.append(f"{product}: ambiguous recorded input '{base}'")
            continue
        rec.role = matches[0]
        rec.workflow_path = roles[rec.role]
    return problems


def verify_product(name: str, spec: dict, roles: dict[str, str], project: Path) -> ProductResult:
    if "path_from_manifest" in spec:
        manifest = project / spec["path_from_manifest"]
        if not manifest.is_file():
            return ProductResult(name, str(manifest), False, problems=["manifest not found"])
        record = json.loads(manifest.read_text())
        primary = record.get("primary") or record["masktables"][0]["filename"]
        path = Path(record["masktables"][0]["path"]).parent / primary
    else:
        path = project / spec["path"] if not Path(spec["path"]).is_absolute() else Path(spec["path"])

    if not path.is_file():
        return ProductResult(name, str(path), False, problems=[f"product not found: {path}"])

    algorithm = spec.get("algorithm", "md5")
    if spec.get("kind") == "text":
        records, problems = read_text_records(name, path)
    else:
        records, problems = read_netcdf_records(name, path, spec.get("attributes", ["inputFile"]))

    problems += resolve_roles(records, roles, name)

    for rec in records:
        if rec.status in ("SKIP", "FAIL"):
            continue
        wf = Path(rec.workflow_path)
        if not wf.is_file():
            rec.status = "FAIL"
            rec.note = f"workflow input for role '{rec.role}' does not exist: {wf}"
            problems.append(f"{name}: missing workflow input {wf}")
            continue
        algo = "sha256" if len(rec.recorded_hash) == 64 else algorithm
        rec.actual_hash = file_hash(wf, algo)
        if rec.actual_hash == rec.recorded_hash:
            rec.status = "PASS"
            if str(wf) != rec.recorded_path:
                rec.note = "recorded path differs from workflow path; hashes agree"
        else:
            rec.status = "FAIL"
            rec.note = (
                f"recorded {algo} does not match the workflow's '{rec.role}'. "
                "Regenerate this product from the correct inputs - do NOT edit the record."
            )
            problems.append(
                f"{name}: {rec.role} hash mismatch (recorded {rec.recorded_hash}, "
                f"workflow {rec.actual_hash})"
            )

    if spec.get("require_topog"):
        topog_recs = [r for r in records if Path(r.recorded_path).name == "topog.nc"]
        if not topog_recs:
            problems.append(
                f"{name}: REQUIRED topog.nc provenance record is absent - cannot confirm "
                "which topography this product was built from"
            )
        elif not any(r.status == "PASS" for r in topog_recs):
            problems.append(f"{name}: topog.nc record does not match the workflow topography")

    return ProductResult(name, str(path), True, records, problems)


def render(results: list[ProductResult], topog_path: str, topog_hash: str) -> str:
    out = [
        "=" * 100,
        "Input-provenance verification (recorded input hashes vs this workflow's inputs)",
        "=" * 100,
        f"workflow topography : {topog_path}",
        f"            md5     : {topog_hash}",
        "",
    ]
    for res in results:
        status = "PASS" if res.passed else "FAIL"
        out.append(f"[{status}] {res.name}   ({res.path})")
        if not res.exists:
            for p in res.problems:
                out.append(f"         ! {p}")
            out.append("")
            continue
        for rec in res.records:
            if rec.status == "SKIP":
                continue
            out.append(f"    {rec.status:4s} {rec.attribute}: {rec.role or Path(rec.recorded_path).name}")
            out.append(f"         recorded path : {rec.recorded_path}")
            out.append(f"         workflow input: {rec.workflow_path}")
            out.append(f"         recorded hash : {rec.recorded_hash}")
            out.append(f"         actual   hash : {rec.actual_hash}")
            if rec.note:
                out.append(f"         note          : {rec.note}")
        for p in res.problems:
            out.append(f"         ! {p}")
        out.append("")
    ok = all(r.passed for r in results)
    out.append("=" * 100)
    out.append(f"RESULT: {'ALL PROVENANCE CHECKS PASSED' if ok else 'PROVENANCE VERIFICATION FAILED'}")
    if not ok:
        out.append(
            "A mismatch must be resolved by regenerating the affected product from the "
            "correct inputs and verifying again - never by editing the recorded hash."
        )
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", type=Path, required=True)
    ap.add_argument("--topog", type=Path, required=True, help="the workflow's topography node")
    ap.add_argument("--ocean-mask", type=Path, help="the workflow's ocean_mask node")
    ap.add_argument("--json-out", type=Path)
    ap.add_argument("--text-out", type=Path)
    ap.add_argument("--only", nargs="*", help="verify only these products")
    args = ap.parse_args()

    import yaml

    cfg = yaml.safe_load(args.config.read_text())
    project = Path(cfg["project_dir"])
    inputs = cfg["inputs"]

    substitutions = {
        "@topog": str(args.topog),
        "@ocean_mask": str(args.ocean_mask) if args.ocean_mask else "",
        "@hgrid": inputs["hgrid"],
        "@vgrid": inputs["vgrid"],
        "@gebco": inputs["gebco"],
        "@bottom_roughness_intermediate": inputs["bottom_roughness_intermediate"],
        "@mankoff_aq": inputs["mankoff_aq"],
        "@mankoff_gl": inputs["mankoff_gl"],
    }
    roles = {
        base: substitutions.get(target, target)
        for base, target in cfg["verification"]["roles"].items()
    }
    roles = {k: v for k, v in roles.items() if v}

    products = cfg["verification"]["products"]
    names = args.only if args.only else list(products)

    results = [verify_product(n, products[n], roles, project) for n in names if n in products]

    rendered = render(results, str(args.topog), file_hash(args.topog, "md5"))
    print(rendered)

    payload = {
        "workflow_topography": {"path": str(args.topog), "md5": file_hash(args.topog, "md5")},
        "all_passed": all(r.passed for r in results),
        "products": [
            {
                "name": r.name,
                "path": r.path,
                "exists": r.exists,
                "passed": r.passed,
                "problems": r.problems,
                "records": [rec.as_dict() for rec in r.records],
            }
            for r in results
        ],
    }
    if args.text_out:
        args.text_out.parent.mkdir(parents=True, exist_ok=True)
        args.text_out.write_text(rendered + "\n")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(payload, indent=2) + "\n")

    return 0 if payload["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
