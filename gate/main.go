// titan-gate sits between a Cloudflare tunnel and a project's port on the Mac:
//
//	internet → cloudflared → titan-gate (127.0.0.1) → localhost:<project port> → VM
//
// It adds what a bare tunnel can't: an optional password (HTTP basic auth), a visit log,
// rewriting Host to localhost (dev servers with host checks), and a friendly page instead
// of a raw 502 when the app isn't running. WebSockets (hot reload) and streaming pass through.
//
// Usage: titan-gate -upstream http://127.0.0.1:5174 [-host localhost:5173] [-password pw]
//
//	[-log visits.log] [-name shop] [-listen 127.0.0.1:0]
//
// The first line on stdout is the address it listens on, e.g. "listening 127.0.0.1:53817".
package main

import (
	"crypto/subtle"
	"flag"
	"fmt"
	"html"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type gate struct {
	upstream *url.URL
	host     string
	password string
	name     string
	proxy    *httputil.ReverseProxy
	logMu    sync.Mutex
	logFile  *os.File
}

func newGate(upstream *url.URL, host, password, name string, logFile *os.File) *gate {
	g := &gate{upstream: upstream, host: host, password: password, name: name, logFile: logFile}
	p := httputil.NewSingleHostReverseProxy(upstream)
	director := p.Director
	p.Director = func(r *http.Request) {
		director(r)
		if g.host != "" {
			r.Host = g.host
		}
		r.Header.Del("Authorization") // the password is for the gate, not the app
	}
	p.FlushInterval = -1 // stream responses (server-sent events, progress)
	p.ErrorHandler = g.unavailable
	g.proxy = p
	return g
}

func (g *gate) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	start := time.Now()
	if g.password != "" && !g.authorized(r) {
		rec.Header().Set("WWW-Authenticate", `Basic realm="`+g.name+` (Titan)", charset="UTF-8"`)
		http.Error(rec, "Password required.", http.StatusUnauthorized)
	} else {
		g.proxy.ServeHTTP(rec, r)
	}
	g.logVisit(r, rec.status, time.Since(start))
}

func (g *gate) authorized(r *http.Request) bool {
	_, pw, ok := r.BasicAuth()
	return ok && subtle.ConstantTimeCompare([]byte(pw), []byte(g.password)) == 1
}

// unavailable explains a failed upstream in plain words instead of a bare 502.
func (g *gate) unavailable(w http.ResponseWriter, r *http.Request, err error) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Retry-After", "5")
	w.WriteHeader(http.StatusServiceUnavailable) // not 502: Cloudflare replaces 502 bodies with its own error page
	fmt.Fprintf(w, `<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="5"><title>%[1]s isn't answering</title>
<body style="font:16px -apple-system,sans-serif;max-width:560px;margin:15vh auto;padding:0 20px;color:#222">
<h1 style="font-size:22px">%[1]s isn't answering yet</h1>
<p>The tunnel is up, but nothing is listening behind it. Start the app (for example <code>npm run dev</code>) and this page reloads by itself.</p>
<p style="color:#888;font-size:13px">Titan · %[2]s</p></body>`, html.EscapeString(g.name), html.EscapeString(err.Error()))
}

func (g *gate) logVisit(r *http.Request, status int, took time.Duration) {
	if g.logFile == nil {
		return
	}
	ip := r.Header.Get("Cf-Connecting-Ip")
	if ip == "" {
		ip, _, _ = net.SplitHostPort(r.RemoteAddr)
	}
	country := r.Header.Get("Cf-Ipcountry")
	line := fmt.Sprintf("%s  %3d  %-6s %-40s %6dms  %s %s\n", time.Now().Format("15:04:05"), status, r.Method,
		truncate(r.URL.RequestURI(), 40), took.Milliseconds(), ip, country)
	g.logMu.Lock()
	g.logFile.WriteString(line)
	g.logMu.Unlock()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

// statusRecorder captures the status code and keeps WebSocket hijacking and flushing working.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) { s.status = code; s.ResponseWriter.WriteHeader(code) }
func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "address to listen on (port 0 = any free port)")
	upstreamFlag := flag.String("upstream", "", "the project's address, e.g. http://127.0.0.1:5173")
	host := flag.String("host", "", "Host header to send upstream (e.g. localhost:5173); empty keeps the public one")
	password := flag.String("password", "", "require this password (HTTP basic auth, any user name)")
	logPath := flag.String("log", "", "append one line per request to this file")
	name := flag.String("name", "app", "project name for pages and the password prompt")
	flag.Parse()

	if *password == "" {
		*password = os.Getenv("TITAN_GATE_PASSWORD") // keeps it out of `ps` output
	}
	upstream, err := url.Parse(*upstreamFlag)
	if err != nil || upstream.Scheme == "" || upstream.Host == "" {
		log.Fatalf("titan-gate: -upstream must be like http://127.0.0.1:5173")
	}
	if !strings.HasPrefix(*listen, "127.0.0.1:") && !strings.HasPrefix(*listen, "localhost:") {
		log.Fatalf("titan-gate: refusing to listen on %s; only 127.0.0.1 is allowed", *listen)
	}
	var logFile *os.File
	if *logPath != "" {
		if logFile, err = os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err != nil {
			log.Fatalf("titan-gate: %v", err)
		}
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("titan-gate: %v", err)
	}
	fmt.Printf("listening %s\n", ln.Addr())
	os.Stdout.Sync()
	srv := &http.Server{Handler: newGate(upstream, *host, *password, *name, logFile), ReadHeaderTimeout: 30 * time.Second}
	log.Fatal(srv.Serve(ln))
}
