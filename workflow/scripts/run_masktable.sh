#!/usr/bin/env bash
# Mask table via the repo's om3-scripts gen_masktable.py, invoked exactly as
# finalise.sh does. The filename encodes the resulting masked-domain count, so
# nothing hardcodes it: a manifest is built by scanning what was produced, and is
# written LAST so a failed run leaves no success record behind.
set -euo pipefail
HGRID="$1"; TOPOG="$2"; LX="$3"; LY="$4"; MODEL="$5"; PERIODX="$6"; AUTO="$7"
STAGE="$8"; PUBLISH="$9"; MANIFEST="${10}"; OM3="${11}"

module purge >/dev/null 2>&1 || true
module use /g/data/xp65/public/modules
module load conda/analysis3-26.02
module use /g/data/vk83/modules
module load model-tools/fre-nctools/2024.05-1

rm -rf "$STAGE"; mkdir -p "$STAGE" "$PUBLISH"
ARGS=(-g "$HGRID" -t "$TOPOG" -l "$LX" "$LY" -m "$MODEL" -x "$PERIODX" -o "$STAGE")
[[ "$AUTO" == "true" ]] && ARGS+=(-a)
python3 "$OM3/masktable_generation/gen_masktable.py" "${ARGS[@]}"

shopt -s nullglob
produced=("$STAGE"/mask_table.*)
(( ${#produced[@]} )) || { echo "no mask table produced" >&2; exit 1; }
rm -f "$PUBLISH"/mask_table.*
for f in "${produced[@]}"; do mv "$f" "$PUBLISH/"; done

python3 - "$PUBLISH" "$MANIFEST" "$TOPOG" "$HGRID" <<'PY'
import hashlib, json, sys, datetime, getpass, platform
from pathlib import Path
publish, manifest, topog, hgrid = sys.argv[1:5]
publish = Path(publish)
def h(p, algo="sha256"):
    d = hashlib.new(algo)
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""): d.update(b)
    return d.hexdigest()
entries = []
for t in sorted(publish.glob("mask_table.*")):
    payload = [l for l in t.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")]
    entries.append({"filename": t.name, "path": str(t), "sha256": h(t), "md5": h(t, "md5"),
                    "header_n_mask": int(payload[0]),
                    "header_layout": [int(v) for v in payload[1].split(",")]})
Path(manifest).write_text(json.dumps({
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "generated_by": getpass.getuser(), "host": platform.node(),
    "inputs": {"topog": topog, "hgrid": hgrid},
    "masktables": entries,
    "primary": entries[0]["filename"] if len(entries) == 1 else None,
    "n_masktables": len(entries)}, indent=2) + "\n")
for e in entries:
    print(f"  {e['filename']}  n_mask={e['header_n_mask']} layout={e['header_layout']}")
PY
