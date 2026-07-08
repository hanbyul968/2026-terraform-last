// testapp/stress — 대회 스펙 호환 연습용 stress 앱.
//
// 계약: port 8080, DB/S3 불필요.
// 엔드포인트:
//
//	POST /v1/stress {requestid,uuid,length} -> 201 (length 에 비례한 CPU 작업)
//	GET  /healthcheck                        -> 200
//
// length 만큼 SHA-256 을 반복 계산해 CPU 를 태운다 → autotune/advise 가 튜닝할
// "느린 앱" 역할. STRESS_MULT(기본 400) 로 부하 강도 조절.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"
)

var mult int

func main() {
	mult = 400
	if v, err := strconv.Atoi(os.Getenv("STRESS_MULT")); err == nil && v > 0 {
		mult = v
	}
	http.HandleFunc("/healthcheck", logged("/healthcheck", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true})
	}))
	http.HandleFunc("/v1/stress", logged("/v1/stress", stress))
	fmt.Fprintln(os.Stderr, "stress app :8080")
	http.ListenAndServe(":8080", nil)
}

func stress(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 405, map[string]any{"err": "method not allowed"})
		return
	}
	var req struct {
		RequestID string `json:"requestid"`
		UUID      string `json:"uuid"`
		Length    int    `json:"length"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Length <= 0 {
		req.Length = 64
	}
	// length * mult 번 해시 → CPU 부하. 결과를 버리지 않게 누적.
	buf := []byte("seed")
	n := req.Length * mult
	var sum [32]byte
	for i := 0; i < n; i++ {
		sum = sha256.Sum256(buf)
		buf = sum[:]
	}
	writeJSON(w, 201, map[string]any{"ok": true, "length": req.Length, "digest": fmt.Sprintf("%x", sum[:4])})
}

// ---- 공용 ----

type logRespWriter struct {
	http.ResponseWriter
	status int
}

func (l *logRespWriter) WriteHeader(c int) { l.status = c; l.ResponseWriter.WriteHeader(c) }

func logged(path string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lw := &logRespWriter{ResponseWriter: w, status: 200}
		h(lw, r)
		rec := map[string]any{
			"ts": start.UTC().Format(time.RFC3339Nano), "method": r.Method, "path": path,
			"status": lw.status, "dur_ms": float64(time.Since(start).Microseconds()) / 1000.0,
			"client_ip": r.RemoteAddr,
			"requestid": r.URL.Query().Get("requestid"), "uuid": r.URL.Query().Get("uuid"),
		}
		b, _ := json.Marshal(rec)
		fmt.Println(string(b))
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
