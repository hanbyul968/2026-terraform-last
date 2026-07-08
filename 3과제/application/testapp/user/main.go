// testapp/user — 대회 스펙 호환 연습용 user 앱 (기존 공식 바이너리와 "다른 앱").
//
// 계약(인프라와 일치):
//
//	env : MYSQL_USER/PASSWORD/HOST/PORT/DBNAME
//	table: user(id, username, email)  (db-init 이 생성 + load_user.dump 시드)
//	port : 8080
//
// 엔드포인트:
//
//	POST /v1/user   {requestid,uuid,username,email} -> 201
//	GET  /v1/user?email=..&requestid=..&uuid=..     -> 200 (없으면 404)
//	GET  /healthcheck                                -> 200
//
// 접근로그를 JSON 으로 stdout 에 찍어 tools/ 대시보드가 파싱할 수 있게 한다.
// 튜닝 연습용 인공 지연: 환경변수 USER_DELAY_MS (기본 0).
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

var db *sql.DB
var delayMS int

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	delayMS, _ = strconv.Atoi(env("USER_DELAY_MS", "0"))

	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&timeout=5s&readTimeout=5s&writeTimeout=5s",
		os.Getenv("MYSQL_USER"), os.Getenv("MYSQL_PASSWORD"),
		os.Getenv("MYSQL_HOST"), env("MYSQL_PORT", "3306"), os.Getenv("MYSQL_DBNAME"))
	var err error
	db, err = sql.Open("mysql", dsn)
	if err == nil {
		db.SetMaxOpenConns(30)
		db.SetMaxIdleConns(10)
		db.SetConnMaxLifetime(3 * time.Minute)
	}

	http.HandleFunc("/healthcheck", logged("/healthcheck", health))
	http.HandleFunc("/v1/user", logged("/v1/user", userHandler))

	fmt.Fprintln(os.Stderr, "user app :8080")
	http.ListenAndServe(":8080", nil)
}

func health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"ok": true})
}

func userHandler(w http.ResponseWriter, r *http.Request) {
	if delayMS > 0 {
		time.Sleep(time.Duration(delayMS) * time.Millisecond)
	}
	switch r.Method {
	case http.MethodPost:
		var req struct {
			RequestID string `json:"requestid"`
			UUID      string `json:"uuid"`
			Username  string `json:"username"`
			Email     string `json:"email"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Username == "" || req.Email == "" {
			writeJSON(w, 400, map[string]any{"err": "bad request"})
			return
		}
		// id 는 username 과 동일하게 둔다(시드 데이터가 id==username 패턴).
		_, err := db.Exec("INSERT INTO user (id, username, email) VALUES (?,?,?)",
			req.Username, req.Username, req.Email)
		if err != nil {
			writeJSON(w, 500, map[string]any{"err": "insert failed"})
			return
		}
		writeJSON(w, 201, map[string]any{"id": req.Username, "username": req.Username, "email": req.Email})

	case http.MethodGet:
		email := r.URL.Query().Get("email")
		if email == "" {
			writeJSON(w, 400, map[string]any{"err": "email required"})
			return
		}
		var id, username, em string
		err := db.QueryRow("SELECT id, username, email FROM user WHERE email=? LIMIT 1", email).
			Scan(&id, &username, &em)
		if err == sql.ErrNoRows {
			writeJSON(w, 404, map[string]any{"err": "not found"})
			return
		}
		if err != nil {
			writeJSON(w, 500, map[string]any{"err": "query failed"})
			return
		}
		writeJSON(w, 200, map[string]any{"id": id, "username": username, "email": em})

	default:
		writeJSON(w, 405, map[string]any{"err": "method not allowed"})
	}
}

// ---- 공용: JSON 응답 + JSON 접근로그 ----

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
