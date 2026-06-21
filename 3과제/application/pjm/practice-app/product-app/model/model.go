package model

import (
	"errors"
	"strings"
)

type RequestMeta struct {
	RequestID string `json:"requestid" form:"requestid"`
	UUID      string `json:"uuid" form:"uuid"`
}

func (r RequestMeta) Validate() error {
	if strings.TrimSpace(r.RequestID) == "" {
		return errors.New("requestid is required")
	}
	if strings.TrimSpace(r.UUID) == "" {
		return errors.New("uuid is required")
	}
	return nil
}

type Product struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Price     float64 `json:"price"`
	ImagePath *string `json:"image_path,omitempty"`
}

type CreateRequest struct {
	RequestMeta
	ID    string  `json:"id"`
	Name  string  `json:"name"`
	Price float64 `json:"price"`
}

func (r CreateRequest) Validate() error {
	if err := r.RequestMeta.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(r.ID) == "" {
		return errors.New("id is required")
	}
	if strings.TrimSpace(r.Name) == "" {
		return errors.New("name is required")
	}
	if r.Price <= 0 {
		return errors.New("price must be positive")
	}
	return nil
}
