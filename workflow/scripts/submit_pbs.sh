#!/usr/bin/env bash
# Run a command under PBS and block until it finishes, propagating its status.
#
# Snakemake needs each step to be synchronous so the DAG stays correct, so this
# uses `qsub -W block=true` - no polling loop, no orphaned job. Job scripts,
# stdout and stderr all stay under $WORKDIR, outside the repository.
set -euo pipefail
: "${WORKDIR:?WORKDIR must be set}"
NAME="${PBS_JOB_NAME:-om3topo}"
mkdir -p "$WORKDIR/logs" "$WORKDIR/tmp"

JOBSCRIPT="$(mktemp "$WORKDIR/tmp/pbsjob.XXXXXX.sh")"
{
  echo "#!/usr/bin/env bash"
  echo "set -euo pipefail"
  printf '%q ' "$@"
  echo
} > "$JOBSCRIPT"
chmod +x "$JOBSCRIPT"

echo "-- PBS (blocking) [$NAME]: $*"
set +e
qsub -W block=true -N "$NAME" \
     -P "${PBS_PROJECT:-tm70}" -q "${PBS_QUEUE:-normalsr}" \
     -l "ncpus=${PBS_NCPUS:-4}" -l "mem=${PBS_MEM:-32GB}" \
     -l "walltime=${PBS_WALLTIME:-01:00:00}" -l "storage=${PBS_STORAGE:-gdata/tm70+scratch/tm70}" \
     -o "$WORKDIR/logs/${NAME}.out" -e "$WORKDIR/logs/${NAME}.err" \
     "$JOBSCRIPT"
status=$?
set -e
echo "-- PBS [$NAME] exit=$status"
[[ -f "$WORKDIR/logs/${NAME}.out" ]] && cat "$WORKDIR/logs/${NAME}.out"
[[ -s "$WORKDIR/logs/${NAME}.err" ]] && { echo "---- stderr ----"; cat "$WORKDIR/logs/${NAME}.err"; }
rm -f "$JOBSCRIPT"
exit $status
