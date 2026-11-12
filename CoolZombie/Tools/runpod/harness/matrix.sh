#!/usr/bin/env bash
# Baseline matrix: sets x scenarios x profiles; summary lines -> results file.
set -uo pipefail
D="$(dirname "$0")"; OUT=${OUT:-$D/results_baseline.txt}; : > "$OUT"
for set in style100 kimodo; do
  for scen in approach flip orbit; do
    for prof in clusters ramp; do
      "$D/run.sh" "$set" "$scen" "$prof" "$@" | grep -a "CS SUMMARY\|CS prepare" | sed "s/^CS prepare \([0-9]*\) ms, \([0-9]*\) frames.*/prepare=\1ms frames=\2/" | tr '\n' ' ' >> "$OUT"; echo >> "$OUT"
    done
  done
done
echo "MATRIX DONE $(date -u +%T)" >> "$OUT"
