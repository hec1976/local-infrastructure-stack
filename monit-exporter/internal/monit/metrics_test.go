package monit

import (
	"os"
	"strings"
	"testing"
	"time"
)

func load(t *testing.T) *Node {
	t.Helper()
	f, err := os.Open("../../testdata/all-types.xml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	r, err := Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
func TestAllServiceTypes(t *testing.T) {
	r := load(t)
	s := Build(r)
	if s.Services != 9 {
		t.Fatalf("services=%d", s.Services)
	}
	for _, typ := range []string{"filesystem", "directory", "file", "process", "host", "system", "fifo", "program", "network"} {
		if s.ByType[typ] != 1 {
			t.Errorf("type %s count=%d", typ, s.ByType[typ])
		}
	}
}
func TestSemanticMetrics(t *testing.T) {
	out := string(Render(Build(load(t)), true, time.Millisecond))
	wants := []string{
		"monit_process_pid{service=\"postfix\",type=\"process\"} 1234",
		"monit_process_memory_bytes{service=\"postfix\",type=\"process\"} 1.048576e+07",
		"monit_object_size_bytes{service=\"monitrc-file\",type=\"file\"} 2048",
		"monit_filesystem_space_percent{service=\"rootfs\",type=\"filesystem\"} 42.5",
		"monit_system_load1{service=\"teko-test\",type=\"system\"} 0.1",
		"monit_program_exit_status{service=\"health-program\",type=\"program\"} 0",
		"monit_host_port_response_seconds{index=\"0\",port=\"443\",protocol=\"https\",service=\"example-host\",type=\"host\"} 0.045",
		"monit_network_rx_bytes_total{service=\"eth0\",type=\"network\"} 1.23456789e+08",
		"monit_value{path=\"link.speed\",service=\"eth0\",type=\"network\"} 1000",
	}
	for _, w := range wants {
		if !strings.Contains(out, w) {
			t.Errorf("missing %q\n%s", w, out)
		}
	}
}
func TestUnknownFutureNumericField(t *testing.T) {
	xml := `<monit><service type="99"><name>x</name><status>0</status><future><newcounter>42</newcounter></future></service></monit>`
	r, err := Parse(strings.NewReader(xml))
	if err != nil {
		t.Fatal(err)
	}
	out := string(Render(Build(r), true, 0))
	if !strings.Contains(out, `monit_value{path="future.newcounter",service="x",type="unknown_99"} 42`) {
		t.Fatal(out)
	}
}
func TestRejectWrongRoot(t *testing.T) {
	if _, err := Parse(strings.NewReader(`<x/>`)); err == nil {
		t.Fatal("expected error")
	}
}

func FuzzParseNeverPanics(f *testing.F) {
	f.Add([]byte(`<monit><service type="3"><name>x</name><status>0</status></service></monit>`))
	f.Add([]byte(`<?xml version="1.0" encoding="ISO-8859-1"?><monit/>`))
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = Parse(strings.NewReader(string(data)))
	})
}
