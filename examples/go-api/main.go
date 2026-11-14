package main

import (
	"encoding/json"
	"log"
	"net/http"
	"runtime"

	"github.com/google/uuid"
)

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"ok":       true,
		"platform": runtime.GOOS + " " + runtime.GOARCH,
		"go":       runtime.Version(),
		"id":       uuid.NewString(),
	})
}

func main() {
	http.HandleFunc("/health", healthHandler)
	log.Println("go-api listening on :8080")
	log.Fatal(http.ListenAndServe("0.0.0.0:8080", nil))
}
