#!/bin/bash
# Samples one process with top: CSV rows to out.csv (or stdout), summary to stderr.
# No root required. powermetrics is an optional cross-check (sudo).
set -euo pipefail
usage='Usage: measure-resources.sh <pid> <seconds> [interval=10] [out.csv]'
pid="${1:?$usage}"
seconds="${2:?$usage}"
interval="${3:-10}"
output="${4:-/dev/stdout}"
for value in "$pid" "$seconds" "$interval"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' "$usage" >&2; exit 1; }
done
((seconds >= interval)) || { printf 'seconds must be at least the interval\n' >&2; exit 1; }
# top's first sample has no CPU or energy delta yet; one extra sample covers the whole span.
samples=$((seconds / interval + 1))

# ps prints accumulated user+system CPU time as minutes:seconds, e.g. 437:33.97.
cpu_seconds() {
  /bin/ps -o time= -p "$1" 2>/dev/null | awk '{ n = split($1, part, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + part[i]; printf "%.2f\n", s }'
}

start_cpu=$(cpu_seconds "$pid") || { printf 'No process with PID %s\n' "$pid" >&2; exit 1; }
start_time=$(date +%s)
{
  printf 'timestamp,cpu_percent,energy_impact,idle_wakeups,memory\n'
  # IDLEW counts platform-idle wake-ups cumulatively; the first and last samples give the delta.
  /usr/bin/top -l "$samples" -s "$interval" -pid "$pid" -stats pid,cpu,power,idlew,mem | awk -v pid="$pid" '
    /^[0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] / { time = $1 "T" $2; gsub("/", "-", time) }
    $1 == pid {
      for (i = 2; i <= 5; i++) sub(/[+-]$/, "", $i)
      print time "," $2 "," $3 "," $4 "," $5
      if (rows++ == 0) first = $4
      last = $4
    }
    END { if (rows) printf "Idle wake-ups: %d between the first and last of %d samples\n", last - first, rows > "/dev/stderr" }'
} >"$output"
end_cpu=$(cpu_seconds "$pid") || { printf 'Process %s exited during the measurement\n' "$pid" >&2; exit 1; }
end_time=$(date +%s)
awk -v before="$start_cpu" -v after="$end_cpu" -v elapsed=$((end_time - start_time)) 'BEGIN {
  printf "Average CPU: %.2f%% over %d s (ps CPU time)\n", (elapsed > 0 ? (after - before) / elapsed * 100 : 0), elapsed
}' >&2
