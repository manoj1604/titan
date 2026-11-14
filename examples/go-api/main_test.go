package main

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()
	healthHandler(rec, httptest.NewRequest("GET", "/health", nil))
	var body map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["platform"] != "linux arm64" {
		t.Fatalf("expected linux arm64, got %v", body["platform"])
	}
	if len(body["id"].(string)) != 36 {
		t.Fatalf("bad uuid %v", body["id"])
	}
}
