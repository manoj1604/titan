package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func setup(t *testing.T, password string) (*httptest.Server, *httptest.Server, string) {
	t.Helper()
	app := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "host="+r.Host+" auth="+r.Header.Get("Authorization"))
	}))
	u, _ := url.Parse(app.URL)
	logPath := filepath.Join(t.TempDir(), "visits.log")
	f, _ := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	g := httptest.NewServer(newGate(u, "localhost:5173", password, "shop", f))
	return app, g, logPath
}

func TestProxiesAndRewritesHost(t *testing.T) {
	app, g, logPath := setup(t, "")
	defer app.Close()
	defer g.Close()
	res, err := http.Get(g.URL + "/hello?x=1")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || !strings.Contains(string(body), "host=localhost:5173") {
		t.Fatalf("got %d %q", res.StatusCode, body)
	}
	// The line is written just after the response is sent, so give it a moment.
	var logged []byte
	for i := 0; i < 100 && !strings.Contains(string(logged), "/hello"); i++ {
		time.Sleep(10 * time.Millisecond)
		logged, _ = os.ReadFile(logPath)
	}
	if !strings.Contains(string(logged), "200  GET    /hello?x=1") {
		t.Fatalf("visit not logged: %q", logged)
	}
}

func TestPasswordIsRequiredAndNotForwarded(t *testing.T) {
	app, g, _ := setup(t, "s3cret")
	defer app.Close()
	defer g.Close()
	res, _ := http.Get(g.URL)
	if res.StatusCode != 401 || !strings.Contains(res.Header.Get("WWW-Authenticate"), "shop") {
		t.Fatalf("want 401 with realm, got %d", res.StatusCode)
	}
	req, _ := http.NewRequest("GET", g.URL, nil)
	req.SetBasicAuth("anyone", "wrong")
	if res, _ = http.DefaultClient.Do(req); res.StatusCode != 401 {
		t.Fatalf("wrong password accepted")
	}
	req.SetBasicAuth("anyone", "s3cret")
	res, _ = http.DefaultClient.Do(req)
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || strings.Contains(string(body), "auth=Basic") {
		t.Fatalf("got %d %q (password must not reach the app)", res.StatusCode, body)
	}
}

func TestFriendlyPageWhenAppIsDown(t *testing.T) {
	u, _ := url.Parse("http://127.0.0.1:1") // nothing listens on port 1
	g := httptest.NewServer(newGate(u, "", "", "shop", nil))
	defer g.Close()
	res, _ := http.Get(g.URL)
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 503 || !strings.Contains(string(body), "shop isn't answering yet") {
		t.Fatalf("got %d %q", res.StatusCode, body)
	}
}
