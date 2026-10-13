// oc-retry-proxy keeps a session alive across a provider's bad weather.
//
// opencode gives up on a busy provider after 5 attempts (~1 minute) and nothing
// in its config or plugin API reaches that schedule. Rather than patch the
// binary, this sits in front of every outbound request as an intercepting HTTPS
// proxy: a 429 or 5xx is retried here, for as long as the policy allows, and
// opencode only ever sees the attempt that worked.
//
// It is provider-agnostic by construction -- it intercepts TLS rather than
// rewriting baseURLs -- so a provider added later is covered with no config.
//
// The policy comes from the request itself. The seeded opencode plugin stamps
// an x-oc-retry header on every model call, so retries can be changed in a
// running session; requests without the header fall back to the env defaults.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// where the TUI plugin reads retry state from
	statusPath = "/__oc/status"
	// a request body larger than this is forwarded without buffering, which
	// means it cannot be replayed and so cannot be retried
	maxReplayBody = 32 << 20
	// how often to write an SSE comment while holding a stream open
	keepAlive = 15 * time.Second
)

type policy struct {
	max      int           // attempts, total
	base     time.Duration // first backoff
	cap      time.Duration // ceiling per wait
	deadline time.Duration // give up after this much wall time
}

func (p policy) wait(attempt int, retryAfter time.Duration) time.Duration {
	if retryAfter > 0 {
		if retryAfter > p.cap {
			return p.cap
		}
		return retryAfter
	}
	d := p.base << (attempt - 1)
	if d > p.cap || d <= 0 {
		return p.cap
	}
	return d
}

func envDefaults() policy {
	p := policy{max: 200, base: 2 * time.Second, cap: 60 * time.Second, deadline: 3 * time.Hour}
	if v := os.Getenv("OC_RETRY_MAX"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			p.max = n
		}
	}
	if v := os.Getenv("OC_RETRY_BASE"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			p.base = time.Duration(n) * time.Millisecond
		}
	}
	if v := os.Getenv("OC_RETRY_CAP"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			p.cap = time.Duration(n) * time.Millisecond
		}
	}
	if v := os.Getenv("OC_RETRY_DEADLINE"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			p.deadline = d
		}
	}
	return p
}

// parseHeader reads "max=200;cap=60000;base=2000;deadline=3h" off a request.
// Anything missing or malformed keeps the env default, so a half-written plugin
// config degrades instead of breaking the session.
func (p policy) withHeader(v string) policy {
	for _, part := range strings.Split(v, ";") {
		k, val, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		switch k {
		case "max":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				p.max = n
			}
		case "base":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				p.base = time.Duration(n) * time.Millisecond
			}
		case "cap":
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				p.cap = time.Duration(n) * time.Millisecond
			}
		case "deadline":
			if d, err := time.ParseDuration(val); err == nil && d > 0 {
				p.deadline = d
			}
		}
	}
	return p
}

func retryableStatus(code int) bool {
	switch code {
	case http.StatusRequestTimeout, http.StatusTooManyRequests,
		http.StatusInternalServerError, http.StatusBadGateway,
		http.StatusServiceUnavailable, http.StatusGatewayTimeout,
		522, 524, 529:
		return true
	}
	return false
}

func retryAfter(h http.Header) time.Duration {
	if v := h.Get("retry-after-ms"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	if v := h.Get("retry-after"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Second
		}
		if t, err := http.ParseTime(v); err == nil {
			if d := time.Until(t); d > 0 {
				return d
			}
		}
	}
	return 0
}

// ──────────────── certificate authority ────────────────

type ca struct {
	cert  *x509.Certificate
	key   *ecdsa.PrivateKey
	leaf  map[string]*tls.Certificate
	mu    sync.Mutex
	pemCA []byte
}

// loadCA reads the CA from dir, creating it on first run. The key never leaves
// the container's config dir -- shipping one inside a published image would let
// anyone holding the image intercept every user's traffic.
func loadCA(dir string) (*ca, error) {
	certPath := filepath.Join(dir, "ca.pem")
	keyPath := filepath.Join(dir, "ca.key")

	if certPEM, err := os.ReadFile(certPath); err == nil {
		keyPEM, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, err
		}
		cBlock, _ := pem.Decode(certPEM)
		kBlock, _ := pem.Decode(keyPEM)
		if cBlock == nil || kBlock == nil {
			return nil, errors.New("ca files present but unreadable")
		}
		cert, err := x509.ParseCertificate(cBlock.Bytes)
		if err != nil {
			return nil, err
		}
		key, err := x509.ParseECPrivateKey(kBlock.Bytes)
		if err != nil {
			return nil, err
		}
		return &ca{cert: cert, key: key, leaf: map[string]*tls.Certificate{}, pemCA: certPEM}, nil
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "opencode-terminal local retry proxy"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLenZero:        true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return nil, err
	}
	log.Printf("generated CA at %s", certPath)
	return &ca{cert: cert, key: key, leaf: map[string]*tls.Certificate{}, pemCA: certPEM}, nil
}

func (c *ca) certFor(host string) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if tc, ok := c.leaf[host]; ok {
		return tc, nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(1, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if ip := net.ParseIP(host); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	} else {
		tmpl.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.cert, &key.PublicKey, c.key)
	if err != nil {
		return nil, err
	}
	tc := &tls.Certificate{Certificate: [][]byte{der, c.cert.Raw}, PrivateKey: key}
	c.leaf[host] = tc
	return tc, nil
}

// ──────────────── proxy ────────────────

var hopByHop = []string{
	"Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
	"Te", "Trailer", "Transfer-Encoding", "Upgrade",
}

// retryState is what the TUI plugin polls. Without it a long retry is
// indistinguishable from the model simply thinking for a while.
type retryState struct {
	Host    string `json:"host"`
	Attempt int    `json:"attempt"`
	Max     int    `json:"max"`
	Reason  string `json:"reason"`
	NextIn  int64  `json:"next_in_ms"`
	Elapsed int64  `json:"elapsed_ms"`
}

// outcome is how an episode ended, kept briefly so the plugin can tell the
// difference between "the provider came back" and "we gave up".
type outcome struct {
	Host    string `json:"host"`
	Attempt int    `json:"attempt"`
	Elapsed int64  `json:"elapsed_ms"`
	OK      bool   `json:"ok"`
	AgeMs   int64  `json:"age_ms"`
}

type tracker struct {
	mu   sync.Mutex
	next int64
	live map[int64]retryState
	last *outcome
	at   time.Time
}

// finish records how an episode ended. Only episodes that actually retried are
// worth reporting -- a request that succeeded first time never had a state.
func (t *tracker) finish(id int64, ok bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	s, had := t.live[id]
	if !had {
		return
	}
	delete(t.live, id)
	t.last = &outcome{Host: s.Host, Attempt: s.Attempt, Elapsed: s.Elapsed, OK: ok}
	t.at = time.Now()
}

func (t *tracker) outcome() *outcome {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.last == nil || time.Since(t.at) > time.Minute {
		return nil
	}
	o := *t.last
	o.AgeMs = time.Since(t.at).Milliseconds()
	return &o
}

func (t *tracker) set(id int64, s retryState) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.live == nil {
		t.live = map[int64]retryState{}
	}
	t.live[id] = s
}

func (t *tracker) clear(id int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.live, id)
}

func (t *tracker) snapshot() []retryState {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]retryState, 0, len(t.live))
	for _, s := range t.live {
		out = append(out, s)
	}
	return out
}

func (t *tracker) id() int64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.next++
	return t.next
}

type proxy struct {
	ca        *ca
	retries   tracker
	transport *http.Transport
	defaults  policy
	// opencode aborts a request whose headers take longer than this (its
	// headerTimeout, 5 min by default). Past this point a streaming request has
	// to be answered with something, so the wait moves inside an open stream.
	headerBudget time.Duration
}

type oneConn struct {
	c    net.Conn
	done bool
	mu   sync.Mutex
}

func (l *oneConn) Accept() (net.Conn, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.done {
		return nil, io.EOF
	}
	l.done = true
	return l.c, nil
}
func (l *oneConn) Close() error   { return nil }
func (l *oneConn) Addr() net.Addr { return l.c.LocalAddr() }

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.mitm(w, r)
		return
	}
	// a request addressed to the proxy itself rather than through it
	if r.URL.Host == "" && r.URL.Path == statusPath {
		w.Header().Set("content-type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"retrying": p.retries.snapshot(),
			"last":     p.retries.outcome(),
		})
		return
	}
	p.forward(w, r, "http")
}

// mitm answers CONNECT itself and terminates TLS with a certificate minted for
// the requested host, so the request inside can be read, retried and replayed.
func (p *proxy) mitm(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		host = r.Host
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "no hijack", http.StatusInternalServerError)
		return
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		return
	}
	if _, err := conn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		conn.Close()
		return
	}
	tlsConn := tls.Server(conn, &tls.Config{
		NextProtos: []string{"http/1.1"},
		GetCertificate: func(hi *tls.ClientHelloInfo) (*tls.Certificate, error) {
			name := hi.ServerName
			if name == "" {
				name = host
			}
			return p.ca.certFor(name)
		},
	})
	if err := tlsConn.HandshakeContext(r.Context()); err != nil {
		tlsConn.Close()
		return
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.URL.Host = r.Host
		p.forward(w, r, "https")
	})}
	_ = srv.Serve(&oneConn{c: tlsConn})
}

type flushWriter struct{ w http.ResponseWriter }

func (f flushWriter) Write(b []byte) (int, error) {
	n, err := f.w.Write(b)
	if fl, ok := f.w.(http.Flusher); ok {
		fl.Flush()
	}
	return n, err
}

func (p *proxy) forward(w http.ResponseWriter, r *http.Request, scheme string) {
	pol := p.defaults
	if v := r.Header.Get("x-oc-retry"); v != "" {
		pol = pol.withHeader(v)
		r.Header.Del("x-oc-retry")
	}

	var body []byte
	replayable := true
	if r.Body != nil {
		limited := io.LimitReader(r.Body, maxReplayBody+1)
		b, err := io.ReadAll(limited)
		if err != nil {
			http.Error(w, "read body: "+err.Error(), http.StatusBadGateway)
			return
		}
		if len(b) > maxReplayBody {
			replayable = false
		}
		body = b
	}
	streaming := bytes.Contains(body, []byte(`"stream":true`)) ||
		strings.Contains(r.Header.Get("accept"), "text/event-stream")

	target := *r.URL
	target.Scheme = scheme
	if target.Host == "" {
		target.Host = r.Host
	}

	start := time.Now()
	id := p.retries.id()
	defer p.retries.clear(id)
	committed := false
	attempts := pol.max
	if !replayable {
		attempts = 1
	}

	for attempt := 1; ; attempt++ {
		out, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), bytes.NewReader(body))
		if err != nil {
			http.Error(w, "build request: "+err.Error(), http.StatusBadGateway)
			return
		}
		out.Header = r.Header.Clone()
		for _, h := range hopByHop {
			out.Header.Del(h)
		}
		out.Host = r.Host

		resp, err := p.transport.RoundTrip(out)
		switch {
		case err != nil && r.Context().Err() != nil:
			return // the client went away, nothing to answer
		case err == nil && !retryableStatus(resp.StatusCode):
			p.retries.finish(id, true)
			p.passThrough(w, resp, committed)
			return
		case attempt >= attempts:
			p.retries.finish(id, false)
			p.giveUp(w, resp, err, committed, attempt, time.Since(start))
			return
		}

		var ra time.Duration
		if resp != nil {
			ra = retryAfter(resp.Header)
			resp.Body.Close()
		}
		wait := pol.wait(attempt, ra)
		if time.Since(start)+wait > pol.deadline {
			p.retries.finish(id, false)
			p.giveUp(w, resp, err, committed, attempt, time.Since(start))
			return
		}
		reason := "transport error"
		if resp != nil {
			reason = strconv.Itoa(resp.StatusCode)
		}
		log.Printf("%s %s: %s, attempt %d/%d, waiting %s", r.Method, target.Host, reason, attempt, attempts, wait.Round(time.Second))
		p.retries.set(id, retryState{
			Host:    target.Host,
			Attempt: attempt,
			Max:     attempts,
			Reason:  reason,
			NextIn:  wait.Milliseconds(),
			Elapsed: time.Since(start).Milliseconds(),
		})

		// once the wait would outlast opencode's header timeout, answer now and
		// keep retrying inside the stream. SSE comments are ignored by the
		// client's parser but reset both its header and chunk timeouts.
		if streaming && !committed && time.Since(start)+wait > p.headerBudget {
			h := w.Header()
			h.Set("content-type", "text/event-stream")
			h.Set("cache-control", "no-cache")
			w.WriteHeader(http.StatusOK)
			if fl, ok := w.(http.Flusher); ok {
				fl.Flush()
			}
			committed = true
		}

		if !p.sleep(r, w, wait, committed) {
			return
		}
	}
}

// sleep waits out the backoff, writing SSE comments if the stream is already
// open. Returns false if the client disconnected.
func (p *proxy) sleep(r *http.Request, w http.ResponseWriter, d time.Duration, committed bool) bool {
	deadline := time.After(d)
	if !committed {
		select {
		case <-deadline:
			return true
		case <-r.Context().Done():
			return false
		}
	}
	tick := time.NewTicker(keepAlive)
	defer tick.Stop()
	for {
		select {
		case <-deadline:
			return true
		case <-r.Context().Done():
			return false
		case <-tick.C:
			if _, err := io.WriteString(flushWriter{w}, ": oc-retry waiting\n\n"); err != nil {
				return false
			}
		}
	}
}

func (p *proxy) passThrough(w http.ResponseWriter, resp *http.Response, committed bool) {
	defer resp.Body.Close()
	if !committed {
		for k, vs := range resp.Header {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		for _, h := range hopByHop {
			w.Header().Del(h)
		}
		w.WriteHeader(resp.StatusCode)
	}
	_, _ = io.Copy(flushWriter{w}, resp.Body)
}

// giveUp reports the last failure. Before the stream is committed that is just
// the upstream response; afterwards the headers are long gone, so the error has
// to be delivered as a stream event instead.
func (p *proxy) giveUp(w http.ResponseWriter, resp *http.Response, err error, committed bool, attempts int, elapsed time.Duration) {
	if resp != nil && !committed {
		p.passThrough(w, resp, false)
		return
	}
	msg := fmt.Sprintf("oc-retry-proxy gave up after %d attempts over %s", attempts, elapsed.Round(time.Second))
	if err != nil {
		msg += ": " + err.Error()
	} else if resp != nil {
		msg += fmt.Sprintf(": upstream kept returning %d", resp.StatusCode)
	}
	if resp != nil {
		resp.Body.Close()
	}
	if committed {
		fmt.Fprintf(flushWriter{w}, "data: {\"error\":{\"message\":%q,\"type\":\"oc_retry_exhausted\"}}\n\ndata: [DONE]\n\n", msg)
		return
	}
	http.Error(w, msg, http.StatusBadGateway)
}

func main() {
	log.SetFlags(0)
	log.SetPrefix("[oc-retry-proxy] ")

	addr := os.Getenv("OC_PROXY_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8787"
	}
	caDir := os.Getenv("OC_PROXY_CA_DIR")
	if caDir == "" {
		caDir = filepath.Join(os.Getenv("HOME"), ".config", "opencode-terminal")
	}
	authority, err := loadCA(caDir)
	if err != nil {
		log.Fatalf("ca: %v", err)
	}

	budget := 240 * time.Second
	if v := os.Getenv("OC_PROXY_HEADER_BUDGET"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			budget = d
		}
	}

	p := &proxy{
		ca: authority,
		transport: &http.Transport{
			Proxy:                 nil, // never chain into ourselves
			ForceAttemptHTTP2:     true,
			MaxIdleConnsPerHost:   8,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   30 * time.Second,
			ExpectContinueTimeout: time.Second,
		},
		defaults:     envDefaults(),
		headerBudget: budget,
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	log.Printf("listening on %s, ca %s, defaults max=%d base=%s cap=%s deadline=%s",
		addr, filepath.Join(caDir, "ca.pem"), p.defaults.max, p.defaults.base, p.defaults.cap, p.defaults.deadline)

	srv := &http.Server{Handler: p}
	if err := srv.Serve(ln); err != nil {
		log.Fatal(err)
	}
}
