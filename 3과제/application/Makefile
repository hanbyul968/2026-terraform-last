GOOS=linux
GOARCH=amd64
CGO_ENABLED=0

.PHONY: all user product stress docker-user docker-product docker-stress

all: user product stress

user:
	GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) go build -o bin/user ./user/

product:
	GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) go build -o bin/product ./product/

stress:
	GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) go build -o bin/stress ./stress/

docker-user:
	docker build -f Dockerfile.user -t user-app:latest .

docker-product:
	docker build -f Dockerfile.product -t product-app:latest .

docker-stress:
	docker build -f Dockerfile.stress -t stress-app:latest .
