package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"

	"github.com/practice/apdev-product/handler"
	"github.com/practice/apdev-product/model"
)

type Config struct {
	User, Password, Host, Port, DBName string
}

func ConfigFromEnv() (Config, error) {
	c := Config{
		User:     os.Getenv("MYSQL_USER"),
		Password: os.Getenv("MYSQL_PASSWORD"),
		Host:     os.Getenv("MYSQL_HOST"),
		Port:     os.Getenv("MYSQL_PORT"),
		DBName:   os.Getenv("MYSQL_DBNAME"),
	}
	if c.User == "" || c.Password == "" || c.Host == "" || c.Port == "" || c.DBName == "" {
		return c, errors.New("MYSQL_USER/PASSWORD/HOST/PORT/DBNAME are required")
	}
	return c, nil
}

func (c Config) DSN() string {
	return fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4&loc=Asia%%2FSeoul",
		c.User, c.Password, c.Host, c.Port, c.DBName)
}

func Open(c Config) (*sql.DB, error) {
	db, err := sql.Open("mysql", c.DSN())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db, nil
}

type Repo struct{ DB *sql.DB }

func (r *Repo) Create(ctx context.Context, p model.Product) error {
	_, err := r.DB.ExecContext(ctx,
		"INSERT INTO product (id, name, price) VALUES (?, ?, ?)",
		p.ID, p.Name, p.Price)
	return err
}

func (r *Repo) Get(ctx context.Context, id string) (model.Product, error) {
	var (
		p   model.Product
		img sql.NullString
	)
	err := r.DB.QueryRowContext(ctx,
		"SELECT id, name, price, image_path FROM product WHERE id = ?", id).
		Scan(&p.ID, &p.Name, &p.Price, &img)
	if errors.Is(err, sql.ErrNoRows) {
		return p, handler.ErrNotFound
	}
	if img.Valid {
		s := img.String
		p.ImagePath = &s
	}
	return p, err
}

func (r *Repo) UpdateImagePath(ctx context.Context, id, ip string) error {
	res, err := r.DB.ExecContext(ctx,
		"UPDATE product SET image_path = ? WHERE id = ?", ip, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return handler.ErrNotFound
	}
	return nil
}
