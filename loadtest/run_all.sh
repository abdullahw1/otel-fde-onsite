#!/usr/bin/env bash
# run_all.sh -- run every load-test profile back-to-back and print a summary.
#
# Why this exists: instead of pasting four different `locust` commands by hand
# during the demo, this runs them all, writes a CSV + a self-contained HTML
# report per profile into results/, then prints one summary table at the end.
#
# Usage:
#   ./run_all.sh                      # run all profiles at demo-friendly durations
#   DURATION=2m ./run_all.sh          # override run time for every profile
#   OTEL_HOST=http://host:4318 ./run_all.sh   # skip kubectl, target a known endpoint
#   PROFILES="baseline large" ./run_all.sh    # run only some profiles
#   SUMMARY_ONLY=1 ./run_all.sh       # don't run anything, just summarize results/
#
# Profiles: baseline | sustained | large | heavy | bursty
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p results

# --- activate the local venv if present -------------------------------------
if [[ -f .venv/bin/activate ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

LOCUST_BIN="${LOCUST_BIN:-locust}"
DURATION="${DURATION:-3m}"           # default per-profile run time (kept short for demos)
PROFILES="${PROFILES:-baseline sustained large heavy}"

if ! command -v "$LOCUST_BIN" >/dev/null 2>&1; then
  echo "ERROR: locust not found. Run:" >&2
  echo "  python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt" >&2
  exit 1
fi

# --- resolve the target endpoint --------------------------------------------
# Prefer an explicit OTEL_HOST. Otherwise try to read the NLB hostname via kubectl.
# (kubectl needs valid AWS creds; if they're expired this will fail fast and
#  tell you to set OTEL_HOST manually.)
resolve_host() {
  if [[ -n "${OTEL_HOST:-}" ]]; then
    echo "$OTEL_HOST"
    return
  fi
  local nlb
  nlb="$(kubectl -n otel get svc otel-collector-nlb \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -z "$nlb" ]]; then
    echo "ERROR: could not resolve the NLB host via kubectl." >&2
    echo "       Set it explicitly, e.g.:  OTEL_HOST=http://<nlb-hostname>:4318 ./run_all.sh" >&2
    exit 1
  fi
  echo "http://${nlb}:4318"
}

# --- one locust invocation ---------------------------------------------------
# args: <name> <users> <spawn-rate> [extra env assignments...]
run_profile() {
  local name="$1" users="$2" spawn="$3"; shift 3
  local out="results/${name}"
  echo ""
  echo "=== profile: ${name}  (users=${users}, spawn=${spawn}/s, time=${DURATION}) ==="
  # The leading `env "$@"` applies any payload-shaping env vars for this profile only.
  env "$@" "$LOCUST_BIN" -f locustfile.py \
    --host "$HOST" \
    --headless \
    -u "$users" -r "$spawn" --run-time "$DURATION" \
    --csv "$out" \
    --html "${out}_report.html"
}

# --- summary table from the *_stats.csv "Aggregated" rows --------------------
print_summary() {
  echo ""
  echo "================= SUMMARY (aggregated per profile) ================="
  printf "%-24s %10s %8s %10s %8s %8s\n" "profile" "reqs" "fails" "req/s" "p95(ms)" "p99(ms)"
  printf "%-24s %10s %8s %10s %8s %8s\n" "------------------------" "----------" "--------" "----------" "--------" "--------"
  local f base
  for f in results/*_stats.csv; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" _stats.csv)"
    # Aggregated row: col3=reqs col4=fails col10=req/s col17=p95 col19=p99
    awk -F, -v p="$base" '
      $2=="Aggregated" {
        printf "%-24s %10d %8d %10.1f %8s %8s\n", p, $3, $4, $10, $17, $19
      }' "$f"
  done
  echo "===================================================================="
  echo "HTML reports: results/<profile>_report.html  (open in a browser, no cluster needed)"
}

# --- main --------------------------------------------------------------------
if [[ "${SUMMARY_ONLY:-0}" == "1" ]]; then
  print_summary
  exit 0
fi

HOST="$(resolve_host)"
echo "Target endpoint: $HOST"

for p in $PROFILES; do
  case "$p" in
    baseline)
      run_profile "baseline" 25 5
      ;;
    sustained)
      run_profile "sustained" 100 10
      ;;
    large)
      # heavy payloads: bigger spans + padding -> stresses serialization/CPU
      run_profile "large" 150 30 \
        LARGE_TRACE_SPANS=500 LARGE_TRACE_PAD_BYTES=256 COMPLEX_TRACE_PAD_BYTES=512
      ;;
    heavy)
      # the evidence-producing degradation profile: large/complex traces plus bursts.
      # This is the run that should push p95/p99 into seconds and may produce timeouts.
      run_profile "heavy" 300 60 \
        LARGE_TRACE_SPANS=700 LARGE_TRACE_PAD_BYTES=512 \
        COMPLEX_TRACE_SPANS=150 COMPLEX_TRACE_PAD_BYTES=1024 \
        BURST_REQUESTS=25
      ;;
    bursty)
      run_profile "bursty" 150 50 \
        BURST_REQUESTS=25
      ;;
    *)
      echo "WARNING: unknown profile '$p' (skipping)" >&2
      ;;
  esac
done

print_summary
