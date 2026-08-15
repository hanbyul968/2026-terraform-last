// color - System Operation 데모용 연습 애플리케이션
//
// 문제지 스펙에 동등하게 맞춘 구현:
//   - GET /v1/color   -> 200, 랜덤 색상 JSON 반환
//   - GET /healthcheck -> 200
//   - TCP/8080 바인딩 (PORT 환경변수로 변경 가능)
//   - access log 를 stdout 으로 출력
//   - requestid, uuid 등 쿼리스트링은 변조하지 않고 그대로 둠
//
// 표준 라이브러리만 사용한다(외부 모듈 의존 없음) -> `go build` 가
// 네트워크 없이 오프라인에서도 동작하므로 어떤 계정/리전/날짜에서도
// EC2 부팅 시 안정적으로 빌드된다.
package main

import (
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"
)

var colorNames = []string{
	"red", "orange", "yellow", "green", "blue", "indigo", "violet",
	"black", "white", "cyan", "magenta", "teal", "lime", "navy",
}

func randomHex() string {
	const hex = "0123456789abcdef"
	b := make([]byte, 7)
	b[0] = '#'
	for i := 1; i < len(b); i++ {
		b[i] = hex[rand.Intn(16)]
	}
	return string(b)
}

// accessLog 는 클라이언트 요청을 stdout 으로 남긴다(요구사항: stdout/stderr 로깅).
func accessLog(r *http.Request, status int) {
	log.Printf("method=%s path=%s query=%q status=%d remote=%s ua=%q",
		r.Method, r.URL.Path, r.URL.RawQuery, status, r.RemoteAddr, r.UserAgent())
}

func colorHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		accessLog(r, http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"color": colorNames[rand.Intn(len(colorNames))],
		"hex":   randomHex(),
	})
	accessLog(r, http.StatusOK)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
	accessLog(r, http.StatusOK)
}

func main() {
	rand.Seed(time.Now().UnixNano())

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/color", colorHandler)
	mux.HandleFunc("/healthcheck", healthHandler)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	log.Printf("color app listening on :%s", port)
	log.Fatal(srv.ListenAndServe())
}
