package main

import (
	"database/sql"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	_ "github.com/go-sql-driver/mysql"
)

var db *sql.DB

type User struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
}

type CreateUserReq struct {
	RequestID string `json:"requestid"`
	UUID      string `json:"uuid"`
	Username  string `json:"username"`
	Email     string `json:"email"`
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
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

func main() {
	initDB()
	defer db.Close()

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

	r.POST("/v1/user", createUser)
	r.GET("/v1/user", getUser)

	addr := ":" + env("PORT", "8080")
	log.Printf(`{"ts":"%s","msg":"listening %s"}`, time.Now().UTC().Format(time.RFC3339Nano), addr)
	if err := r.Run(addr); err != nil {
		log.Fatal(err)
	}
}

func createUser(c *gin.Context) {
	var req CreateUserReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"err": "bad json"})
		return
	}
	if req.Username == "" || req.Email == "" {
		c.JSON(http.StatusBadRequest, gin.H{"err": "username and email required"})
		return
	}

	jitter()
	id := fmt.Sprintf("%s-%d", req.Username, time.Now().UnixNano())
	_, err := db.ExecContext(c.Request.Context(),
		"INSERT INTO user (id, username, email) VALUES (?, ?, ?)",
		id, req.Username, req.Email)
	if err != nil {
		log.Printf(`{"ts":"%s","err":"insert user: %v"}`, time.Now().UTC().Format(time.RFC3339Nano), err)
		c.JSON(http.StatusInternalServerError, gin.H{"err": "db"})
		return
	}

	c.JSON(http.StatusCreated, User{ID: id, Username: req.Username, Email: req.Email})
}

func getUser(c *gin.Context) {
	email := c.Query("email")
	if email == "" {
		c.JSON(http.StatusBadRequest, gin.H{"err": "email required"})
		return
	}

	jitter()
	var u User
	err := db.QueryRowContext(c.Request.Context(),
		"SELECT id, username, email FROM user WHERE email = ?", email).
		Scan(&u.ID, &u.Username, &u.Email)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"err": "not found"})
		return
	}
	if err != nil {
		log.Printf(`{"ts":"%s","err":"query user: %v"}`, time.Now().UTC().Format(time.RFC3339Nano), err)
		c.JSON(http.StatusInternalServerError, gin.H{"err": "db"})
		return
	}

	c.JSON(http.StatusOK, u)
}
