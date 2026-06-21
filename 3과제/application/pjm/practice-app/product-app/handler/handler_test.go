package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/practice/apdev-product/model"
	"github.com/practice/apdev-product/storage"
)

type memRepo struct {
	mu sync.Mutex
	m  map[string]model.Product
}

func newMemRepo() *memRepo { return &memRepo{m: map[string]model.Product{}} }

func (r *memRepo) Create(_ context.Context, p model.Product) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.m[p.ID] = p
	return nil
}

func (r *memRepo) Get(_ context.Context, id string) (model.Product, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.m[id]
	if !ok {
		return p, ErrNotFound
	}
	return p, nil
}

func (r *memRepo) UpdateImagePath(_ context.Context, id, ip string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.m[id]
	if !ok {
		return ErrNotFound
	}
	p.ImagePath = &ip
	r.m[id] = p
	return nil
}

type memStore struct {
	mu    sync.Mutex
	items map[string][]byte
	cts   map[string]string
}

func newMemStore() *memStore {
	return &memStore{items: map[string][]byte{}, cts: map[string]string{}}
}

func (m *memStore) Mode() string { return "memory" }

func (m *memStore) Put(_ context.Context, k string, body io.Reader, ct string) error {
	b, err := io.ReadAll(body)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items[k] = b
	m.cts[k] = ct
	return nil
}

func (m *memStore) Get(_ context.Context, k string) (io.ReadCloser, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.items[k]
	if !ok {
		return nil, "", storage.ErrNotFound
	}
	return io.NopCloser(bytes.NewReader(b)), m.cts[k], nil
}

func newRouter(repo Repo, st storage.Storage) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	(&Handler{Repo: repo, Storage: st}).Register(r)
	return r
}

func TestCreate_OK(t *testing.T) {
	r := newRouter(newMemRepo(), newMemStore())
	body := `{"requestid":"1","uuid":"u","id":"p1","name":"n","price":1234}`
	req := httptest.NewRequest(http.MethodPost, "/v1/product", bytes.NewReader([]byte(body)))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("got %d body=%s", w.Code, w.Body.String())
	}
}

func TestGet_NotFound(t *testing.T) {
	r := newRouter(newMemRepo(), newMemStore())
	req := httptest.NewRequest(http.MethodGet, "/v1/product?id=missing&requestid=1&uuid=u", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("got %d", w.Code)
	}
}

func TestPut_UploadsAndDownloads(t *testing.T) {
	repo := newMemRepo()
	repo.Create(context.Background(), model.Product{ID: "p1", Name: "n", Price: 1234})
	st := newMemStore()
	r := newRouter(repo, st)

	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	mw.WriteField("requestid", "1")
	mw.WriteField("uuid", "u")
	mw.WriteField("id", "p1")
	fw, _ := mw.CreateFormFile("image", "p1.jpg")
	fw.Write([]byte("jpeg-bytes"))
	mw.Close()

	req := httptest.NewRequest(http.MethodPut, "/v1/product", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["image_path"] != "/p1.jpg" {
		t.Fatalf("image_path: %v", resp["image_path"])
	}
	if _, ok := st.items["p1.jpg"]; !ok {
		t.Fatalf("not stored: %v", st.items)
	}

	dl := httptest.NewRequest(http.MethodGet, "/images/p1.jpg", nil)
	dw := httptest.NewRecorder()
	r.ServeHTTP(dw, dl)
	if dw.Code != http.StatusOK || dw.Body.String() != "jpeg-bytes" {
		t.Fatalf("download failed: %d %s", dw.Code, dw.Body.String())
	}
}

func TestDownload_NotFound(t *testing.T) {
	r := newRouter(newMemRepo(), newMemStore())
	req := httptest.NewRequest(http.MethodGet, "/images/x.jpg", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("got %d", w.Code)
	}
}

func TestHealthcheck(t *testing.T) {
	r := newRouter(newMemRepo(), newMemStore())
	req := httptest.NewRequest(http.MethodGet, "/healthcheck", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d", w.Code)
	}
}
