###############################################################################
# Makefile for drift-fixer Docker workflow
###############################################################################

IMAGE_NAME     := drift-fixer
IMAGE_TAG      := latest
TF_VERSION     := 1.9.5
AZ_CLI_VERSION := 2.64.0

# Path to your terraform project (override: make fix TF_DIR=../infra)
TF_DIR         ?= $(shell pwd)

.PHONY: build build-no-cache run fix plan shell lookup validate clean help

## Build the Docker image
build:
	docker build \
		--build-arg TERRAFORM_VERSION=$(TF_VERSION) \
		--build-arg AZURE_CLI_VERSION=$(AZ_CLI_VERSION) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

## Build with no cache (force fresh)
build-no-cache:
	docker build --no-cache \
		--build-arg TERRAFORM_VERSION=$(TF_VERSION) \
		--build-arg AZURE_CLI_VERSION=$(AZ_CLI_VERSION) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

## Run drift detection & fix generation
fix:
	docker run -it --rm \
		-v "$(TF_DIR)":/workspace \
		-v "$(HOME)/.azure":/root/.azure:ro \
		-v drift-fixer-cache:/root/.terraform.d/plugin-cache \
		$(IMAGE_NAME):$(IMAGE_TAG) fix --dir /workspace $(ARGS)

## Run terraform plan only
plan:
	docker run -it --rm \
		-v "$(TF_DIR)":/workspace \
		-v "$(HOME)/.azure":/root/.azure:ro \
		-v drift-fixer-cache:/root/.terraform.d/plugin-cache \
		$(IMAGE_NAME):$(IMAGE_TAG) plan $(ARGS)

## Interactive shell
shell:
	docker run -it --rm \
		-v "$(TF_DIR)":/workspace \
		-v "$(HOME)/.azure":/root/.azure:ro \
		-v drift-fixer-cache:/root/.terraform.d/plugin-cache \
		$(IMAGE_NAME):$(IMAGE_TAG) shell

## Look up Azure resources
lookup:
	docker run -it --rm \
		-v "$(HOME)/.azure":/root/.azure:ro \
		$(IMAGE_NAME):$(IMAGE_TAG) lookup $(ARGS)

## Validate environment
validate:
	docker run -it --rm \
		-v "$(TF_DIR)":/workspace \
		-v "$(HOME)/.azure":/root/.azure:ro \
		$(IMAGE_NAME):$(IMAGE_TAG) validate

## Run with service principal env vars
fix-sp:
	docker run -it --rm \
		-v "$(TF_DIR)":/workspace \
		-v drift-fixer-cache:/root/.terraform.d/plugin-cache \
		-e AZURE_CLIENT_ID \
		-e AZURE_CLIENT_SECRET \
		-e AZURE_TENANT_ID \
		-e AZURE_SUBSCRIPTION_ID \
		$(IMAGE_NAME):$(IMAGE_TAG) fix --dir /workspace $(ARGS)

## Clean up Docker artifacts
clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
	docker volume rm drift-fixer-cache 2>/dev/null || true

## Show help
help:
	@echo "╔═══════════════════════════════════════════════════════╗"
	@echo "║           Terraform Drift Fixer — Makefile           ║"
	@echo "╠═══════════════════════════════════════════════════════╣"
	@echo "║  make build          Build Docker image              ║"
	@echo "║  make fix            Run drift detection + fix gen   ║"
	@echo "║  make plan           Run terraform plan only         ║"
	@echo "║  make shell          Interactive shell               ║"
	@echo "║  make lookup ARGS=.. Azure resource lookup           ║"
	@echo "║  make validate       Validate environment            ║"
	@echo "║  make fix-sp         Fix using service principal     ║"
	@echo "║  make clean          Remove image and volumes        ║"
	@echo "╠═══════════════════════════════════════════════════════╣"
	@echo "║  Override TF project dir:                            ║"
	@echo "║    make fix TF_DIR=/path/to/project                  ║"
	@echo "║  Pass extra args:                                    ║"
	@echo "║    make fix ARGS='--execute --target azurerm_rg.x'   ║"
	@echo "╚═══════════════════════════════════════════════════════╝"