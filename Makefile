include .env
export

IMAGE_NAME=ghcr.io/$(GITHUB_USERNAME)/pocketbase
TAG=$(PB_VERSION)
DOCKERFILE=PocketBase.Dockerfile

install-deps:
	@command -v brew >/dev/null 2>&1 || { echo "Homebrew is not installed. Please install Homebrew: https://brew.sh/"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Installing Docker CLI..."; brew install docker; }
	@command -v colima >/dev/null 2>&1 || { echo "Installing Colima..."; brew install colima; }
	@docker buildx version >/dev/null 2>&1 || { echo "Installing Docker buildx..."; brew install docker-buildx; }

docker-check: install-deps
	@docker info >/dev/null 2>&1 || { echo "Docker daemon is not running. Please start Colima with 'colima start' or ensure another Docker daemon is running."; exit 1; }

docker-login: docker-check
	echo $$GITHUB_TOKEN | docker login ghcr.io -u $$GITHUB_USERNAME --password-stdin

ARCHS = amd64 arm64

buildx-init:
	docker-buildx create --name pocketbasebuilder || true
	docker-buildx use pocketbasebuilder
	docker-buildx inspect pocketbasebuilder --bootstrap

docker-build: buildx-init docker-check
	docker-buildx build --platform linux/amd64,linux/arm64 \
		--build-arg PB_VERSION=$(PB_VERSION) \
		-f $(DOCKERFILE) \
		-t $(IMAGE_NAME):$(TAG) \
		--push . \
		--provenance=false

docker-all: buildx-init docker-login docker-build
