include .env
export

IMAGE_NAME=ghcr.io/$(GITHUB_USERNAME)/pocketbase
TAG=$(PB_VERSION)
DOCKERFILE=PocketBase.Dockerfile

NOMAD_OPS_REPO=https://github.com/nomad-ops/nomad-ops.git
NOMAD_OPS_BUILD_DIR=.nomad-ops-build
NOMAD_OPS_IMAGE_NAME=ghcr.io/$(GITHUB_USERNAME)/nomad-ops
NOMAD_OPS_TAG=latest
NOMAD_OPS_BUILDNUMBER = latest



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

.PHONY: nomad-ops-clone
nomad-ops-clone:
	rm -rf $(NOMAD_OPS_BUILD_DIR)
	git clone --depth 1 $(NOMAD_OPS_REPO) $(NOMAD_OPS_BUILD_DIR)

.PHONY: nomad-ops-docker-build
nomad-ops-docker-build: buildx-init docker-check nomad-ops-clone
	docker-buildx build --platform linux/arm64 \
		-f $(NOMAD_OPS_BUILD_DIR)/Dockerfile \
		--build-arg ARG_BUILDNUMBER=$(NOMAD_OPS_BUILDNUMBER) \
		-t $(NOMAD_OPS_IMAGE_NAME):$(NOMAD_OPS_TAG) \
		--push $(NOMAD_OPS_BUILD_DIR) \
		--provenance=false

.PHONY: nomad-ops-docker-all
nomad-ops-docker-all: buildx-init docker-login nomad-ops-docker-build
