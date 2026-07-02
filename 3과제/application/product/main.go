package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/gin-gonic/gin"
	_ "github.com/go-sql-driver/mysql"
)

var (
	db       *sql.DB
	s3Client *s3.Client
	s3Bucket string
)

// in-memory cache for GET by id (same id is frequently requested per spec)
type cacheEntry struct {
	p       Product
	expires time.Time
}

var (
	cache    sync.Map
	cacheTTL = 10 * time.Second
)

func cacheGet(id string) (Product, bool) {
	v, ok := cache.Load(id)
	if !ok {
		return Product{}, false
	}
	e := v.(cacheEntry)
	if time.Now().After(e.expires) {
		cache.Delete(id)
		return Product{}, false
	}
	return e.p, true
}

func cachePut(id string, p Product) {
	cache.Store(id, cacheEntry{p: p, expires: time.Now().Add(cacheTTL)})
}

func cacheDelete(id string) {
	cache.Delete(id)
}

type Product struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Price     float64 `json:"price"`
	ImagePath string  `json:"image_path,omitempty"`
}

type CreateProductReq struct {
	RequestID string  `json:"requestid"`
	UUID      string  `json:"uuid"`
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Price     float64 `json:"price"`
}

// jitter introduces variable per-request latency: a small base jitter on
// every call plus a rare (~1/20) larger spike, so the latency profile is
// uneven under load rather than flat.
func jitter() {
	d := time.Duration(rand.Intn(8)) * time.Millisecond
	if rand.Intn(20) == 0 {
		d += time.Duration(50+rand.Intn(70)) * time.Millisecond
	}
	time.Sleep(d)
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func initDB() {
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&timeout=5s&interpolateParams=true",
		env("MYSQL_USER", "app"),
		env("MYSQL_PASSWORD", ""),
		env("MYSQL_HOST", "localhost"),
		env("MYSQL_PORT", "3306"),
		env("MYSQL_DBNAME", "dev"),
	)
	var err error
	db, err = sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	db.SetMaxOpenConns(50)
	db.SetMaxIdleConns(25)
	db.SetConnMaxLifetime(5 * time.Minute)

	for i := 0; i < 30; i++ {
		if err = db.Ping(); err == nil {
			break
		}
		log.Printf("waiting for db: %v", err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("db ping: %v", err)
	}
}

func initS3() {
	s3Bucket = env("S3_BUCKET", "")
	if s3Bucket == "" {
		log.Fatal("S3_BUCKET env var required")
	}
	cfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(env("AWS_REGION", "ap-northeast-2")),
	)
	if err != nil {
		log.Fatalf("s3 config: %v", err)
	}
	s3Client = s3.NewFromConfig(cfg)
}

func main() {
	initDB()
	defer db.Close()
	initS3()

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.LoggerWithConfig(gin.LoggerConfig{
		Formatter: func(p gin.LogFormatterParams) string {
			return fmt.Sprintf(`{"ts":"%s","method":"%s","path":"%s","status":%d,"dur_ms":%d,"client_ip":"%s"}`+"\n",
				p.TimeStamp.UTC().Format(time.RFC3339Nano),
				p.Method, p.Path, p.StatusCode,
				p.Latency.Milliseconds(), p.ClientIP)
		},
		Output: os.Stdout,
	}))
	r.Use(gin.Recovery())

	r.GET("/healthcheck", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	r.POST("/v1/product", createProduct)
	r.GET("/v1/product", getProduct)
	r.PUT("/v1/product", updateProductImage)

	addr := ":" + env("PORT", "8080")
	log.Printf(`{"ts":"%s","msg":"listening %s"}`, time.Now().UTC().Format(time.RFC3339Nano), addr)
	if err := r.Run(addr); err != nil {
		log.Fatal(err)
	}
}

func createProduct(c *gin.Context) {
	var req CreateProductReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"err": "bad json"})
		return
	}
	if req.ID == "" || req.Name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"err": "id and name required"})
		return
	}
	jitter()

	_, err := db.ExecContext(c.Request.Context(),
		"INSERT INTO product (id, name, price) VALUES (?, ?, ?)",
		req.ID, req.Name, req.Price)
	if err != nil {
		log.Printf(`{"ts":"%s","err":"insert product: %v"}`, time.Now().UTC().Format(time.RFC3339Nano), err)
		c.JSON(http.StatusInternalServerError, gin.H{"err": "db"})
		return
	}

	p := Product{ID: req.ID, Name: req.Name, Price: req.Price}
	cachePut(req.ID, p)
	c.JSON(http.StatusCreated, p)
}

func getProduct(c *gin.Context) {
	id := c.Query("id")
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"err": "id required"})
		return
	}

	if p, ok := cacheGet(id); ok {
		c.Header("X-Cache", "HIT")
		c.JSON(http.StatusOK, p)
		return
	}

	jitter()
	var p Product
	var imagePath sql.NullString
	err := db.QueryRowContext(c.Request.Context(),
		"SELECT id, name, price, image_path FROM product WHERE id = ?", id).
		Scan(&p.ID, &p.Name, &p.Price, &imagePath)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"err": "not found"})
		return
	}
	if err != nil {
		log.Printf(`{"ts":"%s","err":"query product: %v"}`, time.Now().UTC().Format(time.RFC3339Nano), err)
		c.JSON(http.StatusInternalServerError, gin.H{"err": "db"})
		return
	}
	if imagePath.Valid {
		p.ImagePath = imagePath.String
	}

	cachePut(id, p)
	c.Header("Cache-Control", "public, max-age=10")
	c.JSON(http.StatusOK, p)
}

func updateProductImage(c *gin.Context) {
	id := c.PostForm("id")
	if id == "" {
		// try to parse from JSON part
		var req struct {
			ID string `json:"id"`
		}
		if err := c.ShouldBindJSON(&req); err == nil {
			id = req.ID
		}
	}
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"err": "id required"})
		return
	}

	file, err := c.FormFile("image")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"err": "image file required"})
		return
	}

	src, err := file.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"err": "file open"})
		return
	}
	defer src.Close()

	// namespace the key by product id so uploads for different products
	// (or different files with the same name) never overwrite each other
	objectKey := id + "/" + file.Filename
	contentType := file.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "image/jpeg"
	}

	_, err = s3Client.PutObject(c.Request.Context(), &s3.PutObjectInput{
		Bucket:      &s3Bucket,
		Key:         &objectKey,
		Body:        src,
		ContentType: &contentType,
	})
	if err != nil {
		log.Printf(`{"ts":"%s","err":"s3 put: %v"}`, time.Now().UTC().Format(time.RFC3339Nano), err)
		c.JSON(http.StatusInternalServerError, gin.H{"err": "s3"})
		return
	}

	imagePath := "/" + objectKey
	res, err := db.ExecContext(c.Request.Context(),
		"UPDATE product SET image_path = ? WHERE id = ?", imagePath, id)
	if err != nil {
		log.Printf(`{"ts":"%s","err":"update image_path: %v"}`, time.Now().UTC().Format(time.RFC3339Nano), err)
		c.JSON(http.StatusInternalServerError, gin.H{"err": "db"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		c.JSON(http.StatusNotFound, gin.H{"err": "not found"})
		return
	}

	cacheDelete(id)
	c.JSON(http.StatusOK, gin.H{"id": id, "image_path": imagePath})
}
