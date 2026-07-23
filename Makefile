include versions.env

IMAGE          ?= vcfctl:dev
REGISTRY_IMAGE ?= ghcr.io/devalexllc/vcfctl
PLATFORMS      ?= linux/amd64,linux/arm64

BUILD_ARGS = --build-arg VCF_CLI_VERSION=$(VCF_CLI_VERSION) \
             --build-arg VCF_PLUGIN_BUNDLE_VERSION=$(VCF_PLUGIN_BUNDLE_VERSION) \
             --build-arg KUBECTL_VERSION=$(KUBECTL_VERSION)

.PHONY: build buildx test run shell lint print-versions

build: ## Build the image for the local architecture
	docker build $(BUILD_ARGS) -t $(IMAGE) .

buildx: ## Cross-arch build check; add PUSH=1 to publish to $(REGISTRY_IMAGE)
	docker buildx build $(BUILD_ARGS) --platform $(PLATFORMS) \
		-t $(REGISTRY_IMAGE):$(VCF_CLI_VERSION) $(if $(PUSH),--push) .

test: ## Run the smoke test suite against $(IMAGE)
	IMAGE=$(IMAGE) ./test/smoke.sh

run: ## Run an interactive shell with a persistent home volume
	docker run -it --rm -v vcfctl-home:/home/vcfctl:z $(IMAGE)

shell: run

lint: ## Shellcheck all scripts
	shellcheck docker/entrypoint.sh docker/motd.sh bin/* test/smoke.sh
	shellcheck -s sh docker/profile-vcfctl.sh

print-versions:
	@echo "VCF_CLI_VERSION=$(VCF_CLI_VERSION)"
	@echo "VCF_PLUGIN_BUNDLE_VERSION=$(VCF_PLUGIN_BUNDLE_VERSION)"
	@echo "KUBECTL_VERSION=$(KUBECTL_VERSION)"
