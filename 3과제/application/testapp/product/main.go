// testapp/product — 대회 스펙 호환 연습용 product 앱.
//
// 계약(인프라와 일치):
//
//	env  : MYSQL_* (DB) + S3_BUCKET, AWS_REGION (이미지 업로드; IRSA 자격증명)
//	table: product(id, name, price, image_path)
//	port : 8080
//
// 엔드포인트:
//
//	POST /v1/product {requestid,uuid,id,name,price}      -> 201
//	GET  /v1/product?id=..&requestid=..&uuid=..          -> 200 (없으면 404, 캐시)
//	PUT  /v1/product  multipart(id, image=<file>)        -> 200 (S3 업로드)
//	GET  /healthcheck                                     -> 200
//
// GET 은 sync.Map 캐시(10s TTL) — "같은 id 반복" 트래픽에서 DB 우회로 성능↑.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	_ "github.com/go-sql-driver/mysql"
)

var (
	db       *sql.DB
	s3c      *s3.Client
	bucket   string
	cache    sync.Map // id -> cacheEntry
	cacheTTL = 10 * time.Second
)

type cacheEntry struct {
	body []byte
	exp  time.Time
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&timeout=5s&readTimeout=5s&writeTimeout=5s",
		os.Getenv("MYSQL_USER"), os.Getenv("MYSQL_PASSWORD"),
		os.Getenv("MYSQL_HOST"), env("MYSQL_PORT", "3306"), os.Getenv("MYSQL_DBNAME"))
	db, _ = sql.Open("mysql", dsn)
	if db != nil {
		db.SetMaxOpenConns(30)
		db.SetMaxIdleConns(10)
		db.SetConnMaxLifetime(3 * time.Minute)
	}

	bucket = os.Getenv("S3_BUCKET")
	if cfg, err := config.LoadDefaultConfig(context.Background()); err == nil {
		s3c = s3.NewFromConfig(cfg)
	}

	http.HandleFunc("/healthcheck", logged("/healthcheck", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true})
	}))
	http.HandleFunc("/v1/product", logged("/v1/product", productHandler))

	fmt.Fprintln(os.Stderr, "product app :8080")
	http.ListenAndServe(":8080", nil)
}

func productHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		var req struct {
			RequestID string  `json:"requestid"`
			UUID      string  `json:"uuid"`
			ID        string  `json:"id"`
			Name      string  `json:"name"`
			Price     float64 `json:"price"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
			writeJSON(w, 400, map[string]any{"err": "bad request"})
			return
		}
		_, err := db.Exec("INSERT INTO product (id, name, price) VALUES (?,?,?)", req.ID, req.Name, req.Price)
		if err != nil {
			writeJSON(w, 500, map[string]any{"err": "insert failed"})
			return
		}
		cache.Delete(req.ID)
		writeJSON(w, 201, map[string]any{"id": req.ID, "name": req.Name, "price": req.Price})

	case http.MethodGet:
		id := r.URL.Query().Get("id")
		if id == "" {
			writeJSON(w, 400, map[string]any{"err": "id required"})
			return
		}
		if v, ok := cache.Load(id); ok {
			if e := v.(cacheEntry); time.Now().Before(e.exp) {
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-Cache", "hit")
				w.WriteHeader(200)
				w.Write(e.body)
				return
			}
		}
		var name, imagePath sql.NullString
		var price sql.NullFloat64
		err := db.QueryRow("SELECT name, price, image_path FROM product WHERE id=? LIMIT 1", id).
			Scan(&name, &price, &imagePath)
		if err == sql.ErrNoRows {
			writeJSON(w, 404, map[string]any{"err": "not found"})
			return
		}
		if err != nil {
			writeJSON(w, 500, map[string]any{"err": "query failed"})
			return
		}
		body, _ := json.Marshal(map[string]any{
			"id": id, "name": name.String, "price": price.Float64, "image_path": imagePath.String,
		})
		cache.Store(id, cacheEntry{body: body, exp: time.Now().Add(cacheTTL)})
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Cache", "miss")
		w.WriteHeader(200)
		w.Write(body)

	case http.MethodPut:
		putImage(w, r)

	default:
		writeJSON(w, 405, map[string]any{"err": "method not allowed"})
	}
}

// PUT /v1/product — multipart: id + image 파일 → S3 업로드, image_path 갱신.
func putImage(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(16 << 20); err != nil { // 16MB
		writeJSON(w, 400, map[string]any{"err": "multipart required"})
		return
	}
	id := r.FormValue("id")
	if id == "" {
		writeJSON(w, 400, map[string]any{"err": "id required"})
		return
	}
	file, hdr, err := r.FormFile("image")
	if err != nil {
		writeJSON(w, 400, map[string]any{"err": "image file required"})
		return
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		writeJSON(w, 500, map[string]any{"err": "read failed"})
		return
	}
	ext := path.Ext(hdr.Filename)
	if ext == "" {
		ext = ".jpg"
	}
	key := fmt.Sprintf("product%s%s", id, ext) // S3 key; 다운로드는 /images/product<id>.<ext>
	ctype := hdr.Header.Get("Content-Type")
	if ctype == "" {
		ctype = "application/octet-stream"
	}
	_, err = s3c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: &bucket, Key: &key, Body: readSeeker(data), ContentType: &ctype,
	})
	if err != nil {
		writeJSON(w, 500, map[string]any{"err": "s3 upload failed"})
		return
	}
	imagePath := "/" + key
	db.Exec("UPDATE product SET image_path=? WHERE id=?", imagePath, id)
	cache.Delete(id)
	writeJSON(w, 200, map[string]any{"id": id, "image_path": imagePath})
}

// ---- 공용 ----

func readSeeker(b []byte) *seeker { return &seeker{b: b} }

type seeker struct {
	b   []byte
	pos int
}

func (s *seeker) Read(p []byte) (int, error) {
	if s.pos >= len(s.b) {
		return 0, io.EOF
	}
	n := copy(p, s.b[s.pos:])
	s.pos += n
	return n, nil
}
func (s *seeker) Seek(off int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
		s.pos = int(off)
	case io.SeekCurrent:
		s.pos += int(off)
	case io.SeekEnd:
		s.pos = len(s.b) + int(off)
	}
	return int64(s.pos), nil
}

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
