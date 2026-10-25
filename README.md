# Envoy internal gRPC client × `use_downstream_protocol` — standalone repro kit

**Question under test**
When Envoy's *internal* gRPC client (here: the OpenTelemetry tracer's OTLP/gRPC
exporter) targets a cluster configured with `use_downstream_protocol_config`,
does it send gRPC over **HTTP/1.1** because `AsyncStreamImpl` hardcodes
`Protocol::Http11` in its `stream_info_`?

No Istio involved. One Envoy, one OTel Collector, one curl client.

## Conditions

| Cond | `otel_cluster` protocol options                       | Expectation (hypothesis)                   |
|------|-------------------------------------------------------|--------------------------------------------|
| A    | `use_downstream_protocol_config` (what Istio emits for an un-typed port) | tracer export goes **HTTP/1.1**, Collector rejects, `upstream_cx_http1_total` grows, `upstream_cx_protocol_error` grows |
| B    | `explicit_http_config.http2_protocol_options`          | export goes HTTP/2, spans arrive            |
| C    | same as A, **plus** an external h2 route to the same cluster | same cluster, two pools: external h2 traffic → `http2_total`, tracer → `http1_total`. Proves the *origin* of the request, not the cluster config, picked the protocol |

## Run

```bash
./run.sh A            # or B, C
./run.sh A 1.39.2     # pin a different envoy tag (default: v1.39-latest + latest; edit run.sh)
```

Each run writes `out/<cond>-<envoy_tag>/`:

- `stats.txt`         — `cluster.otel_cluster.*` counters (THE primary evidence)
- `clusters.json`     — admin `/clusters` dump
- `config_dump.json`  — admin `/config_dump` (shows the protocol options Envoy actually loaded)
- `envoy.log`         — envoy with `--component-log-level tracing:debug,grpc:debug,router:debug,pool:debug,http:debug`
- `collector.log`     — collector with debug exporter (span arrival = success)
- `capture.pcap`      — tcpdump on the compose network, port 4317

## What to look at

```bash
grep -E 'upstream_cx_http[123]_total|upstream_cx_protocol_error|upstream_rq_total|upstream_cx_total' out/A-*/stats.txt
grep -E 'upstream_cx_http[123]_total|upstream_cx_protocol_error' out/B-*/stats.txt
grep -ci 'ResourceSpans\|TraceService' out/*/collector.log
tshark -r out/A-*/capture.pcap -Y 'http.request' -T fields -e http.request.line   # HTTP/1.1 request lines, if any
tshark -r out/B-*/capture.pcap -Y 'http2.type == 1' -T fields -e http2.header.value  # h2 HEADERS, if any
```

Versions: run.sh records the exact `envoy --version` and collector image digest in `out/<dir>/versions.txt`.
