#!/usr/bin/env bash
# Usage: ./run.sh <A|B|C> [ENVOY_TAG] [OTELCOL_TAG]
#   ./run.sh A                 # envoy v1.39-latest (same minor Istio 1.31.1 ships: 1.39.2-dev)
#   ./run.sh A v1.36-latest    # older line
#   ./run.sh A latest          # current main-based image
set -euo pipefail
cd "$(dirname "$0")"

COND="${1:?condition A|B|C}"
export COND
export ENVOY_TAG="${2:-v1.39-latest}"
export OTELCOL_TAG="${3:-0.161.0}"

[[ -f "conditions/${COND}.yaml" ]] || { echo "no conditions/${COND}.yaml"; exit 1; }

OUT="out/${COND}-${ENVOY_TAG//\//_}"
rm -rf "$OUT" out/current; mkdir -p "$OUT"; ln -sfn "$(basename "$OUT")" out/current
mkdir -p "$OUT"

log(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

cleanup(){ docker compose down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

log "cond=$COND envoy=$ENVOY_TAG otelcol=$OTELCOL_TAG -> $OUT"
docker compose up -d --quiet-pull

log "waiting for envoy admin"
for i in $(seq 1 30); do curl -fsS localhost:9901/ready >/dev/null 2>&1 && break; sleep 1; done
curl -fsS localhost:9901/ready

log "versions"
{
  echo "envoy: $(docker compose exec -T envoy envoy --version 2>/dev/null | tail -1)"
  echo "envoy image: $(docker compose images envoy | tail -1)"
  echo "otelcol image: $(docker compose images collector | tail -1)"
  echo "date: $(date -u +%FT%TZ)"
} | tee "$OUT/versions.txt"

log "baseline stats (should be all zero)"
curl -fsS localhost:9901/stats | grep -E 'otel_cluster\.upstream_(cx|rq)_' | grep -vE ': 0$' || echo "(all zero)" 

log "generating 20 requests on :10000 (each is a sampled span)"
for i in $(seq 1 20); do curl -fsS -o /dev/null localhost:10000/hello-$i; done

if [[ "$COND" == "C" ]]; then
  log "cond C: 5 EXTERNAL HTTP/2 (h2c prior-knowledge) requests into the same otel_cluster via :10001"
  # The body is not a valid OTLP export; we only need the pool to open an HTTP/2 upstream connection.
  for i in $(seq 1 5); do
    curl -sS --http2-prior-knowledge -o /dev/null -w 'ext h2 -> HTTP/%{http_version} status=%{http_code}\n' \
      -H 'content-type: application/grpc' -X POST --data-binary '' \
      localhost:10001/opentelemetry.proto.collector.trace.v1.TraceService/Export || true
  done
fi

log "waiting 12s for tracer flush (flush_interval_ms default 5000)"
sleep 12

log "stats after"
curl -fsS localhost:9901/stats > "$OUT/stats.txt"
{
  grep -E 'otel_cluster\.upstream_cx_(total|http1_total|http2_total|http3_total|protocol_error|connect_fail|destroy_remote_with_active_rq|destroy_local_with_active_rq)' "$OUT/stats.txt" || true
  grep -E 'otel_cluster\.upstream_rq_(total|pending_total|200|5xx|503|retry|rx_reset|tx_reset)( |:)' "$OUT/stats.txt" || true
  grep -E '^tracing\.' "$OUT/stats.txt" | grep -vE ': 0$' || true
} | tee "$OUT/stats.key.txt"
echo "--- non-zero otel_cluster counters ---"
grep -E 'otel_cluster\.' "$OUT/stats.txt" | grep -vE ': 0$' | grep -vE 'P[0-9]|histogram' | tee "$OUT/stats.nonzero.txt" || true

log "admin dumps"
curl -fsS localhost:9901/clusters?format=json > "$OUT/clusters.json"
curl -fsS localhost:9901/config_dump > "$OUT/config_dump.json"

log "logs"
docker compose logs --no-color --no-log-prefix envoy     > "$OUT/envoy.log"
docker compose logs --no-color --no-log-prefix collector > "$OUT/collector.log"
docker compose stop tcpdump >/dev/null 2>&1 || true
sleep 1
[[ -f out/current/capture.pcap ]] && cp out/current/capture.pcap "$OUT/capture.pcap" 2>/dev/null || true

log "quick read"
echo "spans arrived at collector : $(grep -c 'ResourceSpans\|-> Name' "$OUT/collector.log" || true)"
echo "envoy tracer export errors : $(grep -ci 'export failed\|OTLP trace export' "$OUT/envoy.log" || true)"
echo "pool protocol lines        : "; grep -iE 'protocol_error|codec|http1|http2|new pool|creating a new connection' "$OUT/envoy.log" | grep -i otel | head -20 || true

log "done -> $OUT"
