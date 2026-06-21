package handler

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/practice/apdev-product/model"
	"github.com/practice/apdev-product/storage"
)

var ErrNotFound = errors.New("not found")

type Repo interface {
	Create(ctx context.Context, p model.Product) error
	Get(ctx context.Context, id string) (model.Product, error)
	UpdateImagePath(ctx context.Context, id, imagePath string) error
}

type Handler struct {
	Repo    Repo
	Storage storage.Storage
}

func (h *Handler) Register(r *gin.Engine) {
	r.GET("/healthcheck", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.POST("/v1/product", h.create)
	r.GET("/v1/product", h.get)
	r.PUT("/v1/product", h.updateImage)
	r.GET("/images/*key", h.downloadImage)
}

func (h *Handler) create(c *gin.Context) {
	var req model.CreateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if err := req.Validate(); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	p := model.Product{ID: req.ID, Name: req.Name, Price: req.Price}
	if err := h.Repo.Create(c.Request.Context(), p); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusCreated, p)
}

func (h *Handler) get(c *gin.Context) {
	meta := model.RequestMeta{RequestID: c.Query("requestid"), UUID: c.Query("uuid")}
	if err := meta.Validate(); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	id := c.Query("id")
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id is required"})
		return
	}
	p, err := h.Repo.Get(c.Request.Context(), id)
	if errors.Is(err, ErrNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "product not found"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, p)
}

// updateImage: PUT /v1/product (multipart). fields: requestid, uuid, id, image
func (h *Handler) updateImage(c *gin.Context) {
	meta := model.RequestMeta{RequestID: c.PostForm("requestid"), UUID: c.PostForm("uuid")}
	if err := meta.Validate(); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	id := c.PostForm("id")
	if id == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "id is required"})
		return
	}

	fileHeader, err := c.FormFile("image")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "image file required: " + err.Error()})
		return
	}
	f, err := fileHeader.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	defer f.Close()

	ext := strings.ToLower(path.Ext(fileHeader.Filename))
	if ext == "" {
		ext = ".jpg"
	}
	key := fmt.Sprintf("%s%s", id, ext)
	ct := fileHeader.Header.Get("Content-Type")
	if ct == "" {
		ct = "application/octet-stream"
	}

	if err := h.Storage.Put(c.Request.Context(), key, f, ct); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "upload failed: " + err.Error()})
		return
	}

	imagePath := "/" + key
	if err := h.Repo.UpdateImagePath(c.Request.Context(), id, imagePath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"id":         id,
		"image_path": imagePath,
		"download":   "/images" + imagePath,
		"storage":    h.Storage.Mode(),
	})
}

func (h *Handler) downloadImage(c *gin.Context) {
	key := strings.TrimPrefix(c.Param("key"), "/")
	if key == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "key is required"})
		return
	}
	rc, ct, err := h.Storage.Get(c.Request.Context(), key)
	if errors.Is(err, storage.ErrNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "image not found"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	defer rc.Close()
	c.Header("Content-Type", ct)
	c.Status(http.StatusOK)
	_, _ = io.Copy(c.Writer, rc)
}
