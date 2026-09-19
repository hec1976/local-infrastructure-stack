package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"infrastructure.local/monit-prometheus-exporter/internal/monit"
)

type config struct {
	listen, url, user, pass string
	insecure                bool
	timeout                 time.Duration
	cache                   time.Duration
}
type collector struct {
	cfg      config
	client   *http.Client
	mu       sync.Mutex
	body     []byte
	at       time.Time
	ok       bool
	duration time.Duration
	err      error
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func envBool(k string, d bool) bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv(k)))
	if v == "" {
		return d
	}
	return v == "1" || v == "true" || v == "yes"
}
func main() {
	var c config
	flag.StringVar(&c.listen, "listen-address", env("MONIT_EXPORTER_LISTEN", "127.0.0.1:9108"), "HTTP listen address")
	flag.StringVar(&c.url, "monit-url", env("MONIT_URL", "http://127.0.0.1:2812/_status?format=xml&level=full"), "Monit XML URL")
	userDefault := env("MONIT_USER", os.Getenv("MONIT_USER"))
	passDefault := env("MONIT_PASSWORD", os.Getenv("MONIT_PASSWORD"))
	flag.StringVar(&c.user, "monit-user", userDefault, "Monit HTTP basic auth user")
	flag.StringVar(&c.pass, "monit-password", passDefault, "Monit HTTP basic auth password")
	flag.BoolVar(&c.insecure, "tls-insecure", envBool("MONIT_TLS_INSECURE", false), "Disable TLS certificate validation for Monit only")
	flag.DurationVar(&c.timeout, "timeout", 5*time.Second, "Monit request timeout")
	flag.DurationVar(&c.cache, "cache", 5*time.Second, "Minimum interval between Monit fetches")
	flag.Parse()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: c.insecure} // #nosec G402: explicit operator option
	col := &collector{cfg: c, client: &http.Client{Transport: tr, Timeout: c.timeout}}
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", col.metrics)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintln(w, "ok")
	})
	srv := &http.Server{Addr: c.listen, Handler: securityHeaders(mux), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	go func() {
		log.Printf("monit-prometheus-exporter listening on %s, source=%s", c.listen, c.url)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
func (c *collector) scrape() ([]byte, bool, time.Duration, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.body) > 0 && time.Since(c.at) < c.cfg.cache {
		return c.body, c.ok, c.duration, c.err
	}
	started := time.Now()
	req, err := http.NewRequest(http.MethodGet, c.cfg.url, nil)
	if err != nil {
		return nil, false, time.Since(started), err
	}
	req.Header.Set("Accept", "application/xml,text/xml;q=0.9")
	if c.cfg.user != "" {
		req.SetBasicAuth(c.cfg.user, c.cfg.pass)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		c.duration = time.Since(started)
		c.body = monit.Render(monit.Snapshot{}, false, c.duration)
		c.at = time.Now()
		c.ok = false
		c.err = err
		return c.body, false, c.duration, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		err = fmt.Errorf("monit returned HTTP %d", resp.StatusCode)
		c.duration = time.Since(started)
		c.body = monit.Render(monit.Snapshot{}, false, c.duration)
		c.at = time.Now()
		c.ok = false
		c.err = err
		return c.body, false, c.duration, err
	}
	root, err := monit.Parse(resp.Body)
	c.duration = time.Since(started)
	if err != nil {
		c.body = monit.Render(monit.Snapshot{}, false, c.duration)
		c.at = time.Now()
		c.ok = false
		c.err = err
		return c.body, false, c.duration, err
	}
	snap := monit.Build(root)
	c.body = monit.Render(snap, true, c.duration)
	c.at = time.Now()
	c.ok = true
	c.err = nil
	return c.body, true, c.duration, nil
}
func (c *collector) metrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, _, _, err := c.scrape()
	if err != nil {
		log.Printf("monit scrape failed: %v", err)
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	if r.Method == http.MethodGet {
		_, _ = w.Write(body)
	}
}
