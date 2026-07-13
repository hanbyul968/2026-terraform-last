package main

import (
	"crypto/sha256"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

type StressReq struct {
	RequestID string `json:"requestid"`
	UUID      string `json:"uuid"`
	Length    int    `json:"length"`
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			return f
		}
	}
	return def
}

// loadMult scales the synthetic per-request work. Tune LOAD_MULT in the
// deployment to raise or lower contest difficulty without rebuilding the image.
var loadMult = envFloat("LOAD_MULT", 1.0)

// maxLength is the documented upper bound of the stress API's length field.
const maxLength = 4096

func main() {
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

	r.POST("/v1/stress", handleStress)

	addr := ":" + env("PORT", "8080")
	log.Printf(`{"ts":"%s","msg":"listening %s"}`, time.Now().UTC().Format(time.RFC3339Nano), addr)
	if err := r.Run(addr); err != nil {
		log.Fatal(err)
	}
}

func handleStress(c *gin.Context) {
	var req StressReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"err": "bad json"})
		return
	}
	if req.Length <= 0 {
		req.Length = 1
	}
	// cap Length so a stray large value cannot request a multi-GB allocation.
	if req.Length > maxLength {
		req.Length = maxLength
	}

	// allocate (req.Length * 4) KB and compute hashes to generate CPU + memory pressure.
	// work grows ~quadratically with Length, so a small Length bump is a large load bump.
	size := req.Length * 4 * 1024
	buf := make([]byte, size)
	rand.Read(buf)

	// variable load: most requests run a 2x-5x burst, ~1/8 spike up to 12x.
	// identical Length therefore yields a spiky, uneven CPU profile.
	burst := 2 + rand.Intn(4)
	if rand.Intn(8) == 0 {
		burst = 6 + rand.Intn(7)
	}
	h := sha256.New()
	iters := int(float64(req.Length*4*burst) * loadMult)
	for i := 0; i < iters; i++ {
		h.Write(buf)
	}
	result := fmt.Sprintf("%x", h.Sum(nil))

	c.JSON(http.StatusCreated, gin.H{
		"requestid": req.RequestID,
		"uuid":      req.UUID,
		"length":    req.Length,
		"result":    result[:8],
	})
}
