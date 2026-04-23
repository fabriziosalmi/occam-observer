package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
)

func main() {
	port := os.Getenv("API_PORT")
	if port == "" {
		port = "9999"
	}

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/analyze", handleAnalyze)

	// Serve static files from the "public" directory
	fs := http.FileServer(http.Dir("./public"))
	http.Handle("/ui/", http.StripPrefix("/ui/", fs))

	addr := fmt.Sprintf("127.0.0.1:%s", port)
	log.Printf("Occam API Server running on http://%s", addr)
	
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

// handleRoot implements the CQRS read model, returning the JSON cache in O(1) latency
func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	cacheFile := os.Getenv("CACHE_FILE")
	if cacheFile == "" {
		cacheFile = "/tmp/occam_state.json"
	}

	data, err := os.ReadFile(cacheFile)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(`{"error": "cache not ready or observer not running"}`))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Write(data)
}

// handleAnalyze allows on-demand telemetry of any path using the --json headless mode
func handleAnalyze(w http.ResponseWriter, r *http.Request) {
	targetPath := r.URL.Query().Get("path")
	if targetPath == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error": "Missing 'path' query parameter"}`))
		return
	}

	engineScript := os.Getenv("ENGINE_SCRIPT")
	if engineScript == "" {
		engineScript = "../telemetry_observer.sh"
	}

	// Verify the script exists
	if _, err := os.Stat(engineScript); os.IsNotExist(err) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte(`{"error": "telemetry_observer.sh not found"}`))
		return
	}

	cmd := exec.Command(engineScript, "--json", targetPath)
	output, err := cmd.CombinedOutput()
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		
		// Attempt to parse standard output even on error just in case it returned JSON payload
		var js map[string]interface{}
		if json.Unmarshal(output, &js) == nil {
			w.Write(output)
			return
		}
		
		errorMsg := fmt.Sprintf(`{"error": "Failed to analyze path", "details": %q}`, err.Error())
		w.Write([]byte(errorMsg))
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Write(output)
}
