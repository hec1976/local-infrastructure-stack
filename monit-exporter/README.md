# Monit Prometheus Exporter (Go)

Dependency-free Go exporter for Monit's local XML status endpoint.

Default flow:

```text
Monit 127.0.0.1:2812/_status?format=xml&level=full
                    |
                    v
       monit-prometheus-exporter (Go)
              127.0.0.1:9108
                    |
                    v
                Prometheus
                    |
                    v
                 Grafana
```

## Supported Monit service types

All nine service types documented by current Monit are handled:

| ID | Type | Semantic metrics |
|---:|---|---|
| 0 | filesystem | space, inode, status |
| 1 | directory | mode, uid, gid, timestamp, status |
| 2 | file | mode, uid, gid, timestamp, size, status |
| 3 | process | PID/PPID, uptime, threads, children, CPU, memory |
| 4 | host | ICMP and port response time, status |
| 5 | system | load, CPU, memory, swap |
| 6 | fifo | mode, uid, gid, timestamp, status |
| 7 | program | last start, exit status, service status |
| 8 | network | link, speed, duplex, RX/TX counters |

Additionally **every numeric XML leaf** is exported as:

```text
monit_value{service="...",type="...",path="..."} VALUE
```

This fallback is intentional. If a newer Monit adds a numeric field that the
exporter does not yet know semantically, the value is still visible to
Prometheus without silently disappearing.

## Security

- Monit HTTP binds to `127.0.0.1:2812` only.
- Monit HTTP uses `allow localhost` and binds only to loopback.
- The exporter itself exposes no Monit action/control endpoint.
- Exporter binds to `127.0.0.1:9108` by default.
- No shell execution, no Monit control/action API, no write endpoint.
- `/metrics` and `/healthz` accept GET/HEAD only.
- HTTP response body is not cached by clients.
- XML body is limited to 16 MiB.
- HTTP timeout and header timeout are bounded.
- systemd unit uses `DynamicUser`, `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, kernel protections and `MemoryDenyWriteExecute`.

## Build

```bash
go test ./...
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
  -o bin/monit-prometheus-exporter-linux-amd64 ./cmd/monit-prometheus-exporter
```

Das Repository enthaelt das `linux-amd64`-Binary absichtlich mit, weil der
Stack-Installer es ohne lokalen Go-Compiler installieren koennen soll. Nach
Source-Aenderungen ist das Binary neu zu bauen und zusammen mit den Tests zu
aktualisieren.

## Integration in the TEKO deployment

```bash
sudo ./setup_postfix_monit.sh
sudo ./setup_monit_exporter.sh
```

Then:

```bash
curl http://127.0.0.1:9108/healthz
curl http://127.0.0.1:9108/metrics
```

## Prometheus

See `../observability/prometheus/prometheus.yml.example`.

For a central Prometheus server, do **not** simply expose TCP/9108 to the
whole LAN. Use a dedicated monitoring network/firewall ACL or a TLS reverse
proxy and restrict the source to the Prometheus host(s).
