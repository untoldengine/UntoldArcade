#!/usr/bin/env bash
# sweep.sh OUTFILE JOBSFILE [PARALLEL]: one run1.sh per line of JOBSFILE (env assignments), summaries appended to OUTFILE.
OUT=$1; JOBS=$2; PAR=${3:-2}; D="$(dirname "$0")"; : > "$OUT"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PAR" ]; do sleep 1; done
  ( "$D/run1.sh" $line >> "$OUT" ) &
done < "$JOBS"
wait
