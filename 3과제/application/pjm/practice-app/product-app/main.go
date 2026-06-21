package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/practice/apdev-product/db"
	"github.com/practice/apdev-product/handler"
	"github.com/practice/apdev-product/storage"
)

func main() {
	cfg, err := db.ConfigFromEnv()
	if err != nil {
		log.Fatalf("db config: %v", err)
	}
	conn, err := db.Open(cfg)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	defer conn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for {
		if err := conn.PingContext(ctx); err == nil {
			break
		}
		select {
		case <-ctx.Done():
			log.Fatalf("db ping: %v", ctx.Err())
		case <-time.After(time.Second):
		}
	}
	log.Println("[product] db connected")

	st, err := storage.FromEnv(context.Background())
	if err != nil {
		log.Fatalf("storage: %v", err)
	}
	log.Printf("[product] storage mode = %s", st.Mode())

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery(), gin.LoggerWithWriter(os.Stdout))
	(&handler.Handler{Repo: &db.Repo{DB: conn}, Storage: st}).Register(r)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		if err := r.Run(":8080"); err != nil {
			log.Fatalf("server: %v", err)
		}
	}()
	log.Println("[product] listening on :8080")
	<-stop
	log.Println("[product] shutting down")
}
