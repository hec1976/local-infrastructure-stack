package monit

import (
	"bytes"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Metric struct {
	Name   string
	Labels map[string]string
	Value  float64
}

type Snapshot struct {
	Host         string
	MonitVersion string
	Services     int
	ByType       map[string]int
	Metrics      []Metric
}

func Build(root *Node) Snapshot {
	snap := Snapshot{ByType: map[string]int{}}
	if server := root.Child("server"); server != nil {
		snap.Host = server.PathText("localhostname")
		if snap.Host == "" {
			snap.Host = server.PathText("hostname")
		}
		snap.MonitVersion = server.PathText("version")
	}
	if snap.Host == "" {
		snap.Host = root.PathText("server", "localhostname")
	}

	for _, svc := range Services(root) {
		code := svc.AttrValue("type")
		typ := ServiceType(code)
		name := svc.PathText("name")
		if name == "" {
			name = "unnamed"
		}
		labels := map[string]string{"service": name, "type": typ}
		snap.Services++
		snap.ByType[typ]++
		add := func(n string, v float64) {
			snap.Metrics = append(snap.Metrics, Metric{Name: n, Labels: clone(labels), Value: v})
		}
		add("monit_service_info", 1)
		if v, ok := Float(svc.PathText("status")); ok {
			add("monit_service_status", v)
		}
		if v, ok := Float(svc.PathText("status_hint")); ok {
			add("monit_service_status_hint", v)
		}
		if v, ok := Float(svc.PathText("monitor")); ok {
			add("monit_service_monitor", v)
		}
		if v, ok := Float(svc.PathText("monitormode")); ok {
			add("monit_service_monitor_mode", v)
		}
		if v, ok := Float(svc.PathText("pendingaction")); ok {
			add("monit_service_pending_action", v)
		}

		// Stable semantic metrics for the common Monit fields.
		semanticMetrics(svc, typ, labels, &snap.Metrics)

		// Future-proof fallback: every numeric XML leaf is exported too.
		// This is intentionally a single metric with a path label to prevent
		// unbounded metric-name generation from unknown XML tags.
		walkNumeric(svc, "", labels, &snap.Metrics)
	}
	return snap
}

func clone(in map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range in {
		out[k] = v
	}
	return out
}
func appendMetric(dst *[]Metric, name string, labels map[string]string, v float64) {
	*dst = append(*dst, Metric{Name: name, Labels: clone(labels), Value: v})
}
func addPath(dst *[]Metric, svc *Node, labels map[string]string, metric string, factor float64, path ...string) {
	if v, ok := Float(svc.PathText(path...)); ok {
		appendMetric(dst, metric, labels, v*factor)
	}
}
func addNestedList(dst *[]Metric, svc *Node, child string, labels map[string]string, metric string, valuePath string) {
	for i, n := range svc.ChildrenNamed(child) {
		if v, ok := Float(n.PathText(valuePath)); ok {
			l := clone(labels)
			l["index"] = strconv.Itoa(i)
			if p := n.PathText("portnumber"); p != "" {
				l["port"] = p
			}
			if proto := n.PathText("protocol"); proto != "" {
				l["protocol"] = proto
			}
			appendMetric(dst, metric, l, v)
		}
	}
}

func semanticMetrics(svc *Node, typ string, labels map[string]string, dst *[]Metric) {
	switch typ {
	case "process":
		addPath(dst, svc, labels, "monit_process_pid", 1, "pid")
		addPath(dst, svc, labels, "monit_process_ppid", 1, "ppid")
		addPath(dst, svc, labels, "monit_process_threads", 1, "threads")
		addPath(dst, svc, labels, "monit_process_children", 1, "children")
		addPath(dst, svc, labels, "monit_process_uptime_seconds", 1, "uptime")
		addPath(dst, svc, labels, "monit_process_cpu_percent", 1, "cpu", "percent")
		addPath(dst, svc, labels, "monit_process_cpu_total_percent", 1, "cpu", "percenttotal")
		addPath(dst, svc, labels, "monit_process_memory_percent", 1, "memory", "percent")
		addPath(dst, svc, labels, "monit_process_memory_total_percent", 1, "memory", "percenttotal")
		addPath(dst, svc, labels, "monit_process_memory_bytes", 1024, "memory", "kilobyte")
		addPath(dst, svc, labels, "monit_process_memory_total_bytes", 1024, "memory", "kilobytetotal")
	case "system":
		addPath(dst, svc, labels, "monit_system_load1", 1, "system", "load", "avg01")
		addPath(dst, svc, labels, "monit_system_load5", 1, "system", "load", "avg05")
		addPath(dst, svc, labels, "monit_system_load15", 1, "system", "load", "avg15")
		addPath(dst, svc, labels, "monit_system_cpu_user_percent", 1, "system", "cpu", "user")
		addPath(dst, svc, labels, "monit_system_cpu_system_percent", 1, "system", "cpu", "system")
		addPath(dst, svc, labels, "monit_system_cpu_wait_percent", 1, "system", "cpu", "wait")
		addPath(dst, svc, labels, "monit_system_memory_percent", 1, "system", "memory", "percent")
		addPath(dst, svc, labels, "monit_system_memory_bytes", 1024, "system", "memory", "kilobyte")
		addPath(dst, svc, labels, "monit_system_swap_percent", 1, "system", "swap", "percent")
		addPath(dst, svc, labels, "monit_system_swap_bytes", 1024, "system", "swap", "kilobyte")
	case "filesystem":
		addPath(dst, svc, labels, "monit_filesystem_space_percent", 1, "block", "percent")
		addPath(dst, svc, labels, "monit_filesystem_space_bytes", 1024, "block", "usage")
		addPath(dst, svc, labels, "monit_filesystem_total_bytes", 1024, "block", "total")
		addPath(dst, svc, labels, "monit_filesystem_inode_percent", 1, "inode", "percent")
		addPath(dst, svc, labels, "monit_filesystem_inode_used", 1, "inode", "usage")
		addPath(dst, svc, labels, "monit_filesystem_inode_total", 1, "inode", "total")
	case "file", "directory", "fifo":
		addPath(dst, svc, labels, "monit_object_mode", 1, "mode")
		addPath(dst, svc, labels, "monit_object_uid", 1, "uid")
		addPath(dst, svc, labels, "monit_object_gid", 1, "gid")
		addPath(dst, svc, labels, "monit_object_timestamp_seconds", 1, "timestamp")
		addPath(dst, svc, labels, "monit_object_size_bytes", 1, "size")
	case "program":
		addPath(dst, svc, labels, "monit_program_started_seconds", 1, "program", "started")
		addPath(dst, svc, labels, "monit_program_exit_status", 1, "program", "status")
	case "host":
		if icmp := svc.Child("icmp"); icmp != nil {
			if v, ok := Float(icmp.PathText("responsetime")); ok {
				appendMetric(dst, "monit_host_icmp_response_seconds", labels, v)
			}
		}
		addNestedList(dst, svc, "port", labels, "monit_host_port_response_seconds", "responsetime")
	case "network":
		addPath(dst, svc, labels, "monit_network_link_state", 1, "link", "state")
		addPath(dst, svc, labels, "monit_network_speed", 1, "link", "speed")
		addPath(dst, svc, labels, "monit_network_duplex", 1, "link", "duplex")
		// Names observed across Monit generations. Generic fallback still covers unknown names.
		addPath(dst, svc, labels, "monit_network_rx_bytes_total", 1, "download", "bytes", "total")
		addPath(dst, svc, labels, "monit_network_tx_bytes_total", 1, "upload", "bytes", "total")
		addPath(dst, svc, labels, "monit_network_rx_packets_total", 1, "download", "packets", "total")
		addPath(dst, svc, labels, "monit_network_tx_packets_total", 1, "upload", "packets", "total")
		addPath(dst, svc, labels, "monit_network_rx_errors_total", 1, "download", "errors", "total")
		addPath(dst, svc, labels, "monit_network_tx_errors_total", 1, "upload", "errors", "total")
	}
}

func walkNumeric(n *Node, prefix string, labels map[string]string, dst *[]Metric) {
	for _, c := range n.Children {
		path := c.XMLName.Local
		if prefix != "" {
			path = prefix + "." + path
		}
		if len(c.Children) == 0 {
			if v, ok := Float(c.Text); ok && !math.IsNaN(v) && !math.IsInf(v, 0) {
				l := clone(labels)
				l["path"] = path
				appendMetric(dst, "monit_value", l, v)
			}
		} else {
			walkNumeric(c, path, labels, dst)
		}
	}
}

func escLabel(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\n", "\\n")
	s = strings.ReplaceAll(s, "\"", "\\\"")
	return s
}
func Render(snapshot Snapshot, fetchOK bool, duration time.Duration) []byte {
	var b bytes.Buffer
	fmt.Fprintln(&b, "# HELP monit_up Whether the Monit XML endpoint was successfully scraped.")
	fmt.Fprintln(&b, "# TYPE monit_up gauge")
	if fetchOK {
		fmt.Fprintln(&b, "monit_up 1")
	} else {
		fmt.Fprintln(&b, "monit_up 0")
	}
	fmt.Fprintln(&b, "# HELP monit_scrape_duration_seconds Time spent fetching and parsing Monit XML.")
	fmt.Fprintln(&b, "# TYPE monit_scrape_duration_seconds gauge")
	fmt.Fprintf(&b, "monit_scrape_duration_seconds %.6f\n", duration.Seconds())
	if !fetchOK {
		return b.Bytes()
	}
	if snapshot.Host != "" || snapshot.MonitVersion != "" {
		fmt.Fprintf(&b, "monit_server_info{host=\"%s\",version=\"%s\"} 1\n", escLabel(snapshot.Host), escLabel(snapshot.MonitVersion))
	}
	types := make([]string, 0, len(snapshot.ByType))
	for t := range snapshot.ByType {
		types = append(types, t)
	}
	sort.Strings(types)
	for _, t := range types {
		fmt.Fprintf(&b, "monit_services_total{type=\"%s\"} %d\n", escLabel(t), snapshot.ByType[t])
	}
	sort.Slice(snapshot.Metrics, func(i, j int) bool {
		a, c := snapshot.Metrics[i], snapshot.Metrics[j]
		if a.Name != c.Name {
			return a.Name < c.Name
		}
		return labelKey(a.Labels) < labelKey(c.Labels)
	})
	for _, m := range snapshot.Metrics {
		fmt.Fprint(&b, m.Name)
		if len(m.Labels) > 0 {
			fmt.Fprint(&b, "{")
			keys := make([]string, 0, len(m.Labels))
			for k := range m.Labels {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for i, k := range keys {
				if i > 0 {
					fmt.Fprint(&b, ",")
				}
				fmt.Fprintf(&b, "%s=\"%s\"", k, escLabel(m.Labels[k]))
			}
			fmt.Fprint(&b, "}")
		}
		fmt.Fprintf(&b, " %s\n", strconv.FormatFloat(m.Value, 'g', -1, 64))
	}
	return b.Bytes()
}
func labelKey(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(m[k])
		b.WriteByte(';')
	}
	return b.String()
}
