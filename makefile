MIGRATION_DIR := migrations
AWS_PROFILE ?= personal
AWS_ACCOUNT_ID := 108359913979
AWS_DEFAULT_REGION := ap-south-1
AWS_ECR_DOMAIN := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_DEFAULT_REGION).amazonaws.com
GIT_SHA := $(shell git rev-parse HEAD)
BUILD_IMAGE := $(AWS_ECR_DOMAIN)/cloud-service
BUILD_TAG := $(if $(BUILD_TAG),$(BUILD_TAG),latest)
ECS_CLUSTER := default
ECS_SERVICE := cloud-service-1527
DOCKERIZE_HOST := $(shell echo $(GOOSE_DBSTRING) | cut -d "@" -f 2 | cut -d ":" -f 1)
DOCKERIZE_URL := tcp://$(if $(DOCKERIZE_HOST),$(DOCKERIZE_HOST):5432,localhost:5433)
.DEFAULT_GOAL := build

build:
	go build -o ./goals main.go

build-image:
	docker buildx build \
		--platform "linux/amd64" \
		--tag "$(BUILD_IMAGE):$(GIT_SHA)-build" \
		--target "build" \
		.
	docker buildx build \
		--platform "linux/amd64" \
		--tag "$(BUILD_IMAGE):$(GIT_SHA)" \
		.

build-image-login:
	aws ecr get-login-password \
		--region $(AWS_DEFAULT_REGION) \
		--profile $(AWS_PROFILE) | docker login \
		--username AWS \
		--password-stdin \
		$(AWS_ECR_DOMAIN)

build-image-push: build-image build-image-login
	docker image push $(BUILD_IMAGE):$(GIT_SHA)
	docker image tag $(BUILD_IMAGE):$(GIT_SHA) $(BUILD_IMAGE):$(BUILD_TAG)
	docker image push $(BUILD_IMAGE):$(BUILD_TAG)
	$(MAKE) ecs-redeploy

build-image-pull: build-image-login
	docker image pull $(BUILD_IMAGE):$(GIT_SHA)

build-image-migrate:
	docker container run \
		--entrypoint "dockerize" \
		--network "host" \
		--rm \
		$(BUILD_IMAGE):$(GIT_SHA) \
		-timeout 30s \
		-wait \
		$(DOCKERIZE_URL)
	docker container run \
		--entrypoint "goose" \
		--env "GOOSE_DBSTRING" \
		--env "GOOSE_DRIVER" \
		--network "host" \
		--rm \
		$(BUILD_IMAGE):$(GIT_SHA) \
		-dir $(MIGRATION_DIR) status
	docker container run \
		--entrypoint "goose" \
		--env "GOOSE_DBSTRING" \
		--env "GOOSE_DRIVER" \
		--network "host" \
		--rm \
		$(BUILD_IMAGE):$(GIT_SHA) \
		-dir $(MIGRATION_DIR) validate
	docker container run \
		--entrypoint "goose" \
		--env "GOOSE_DBSTRING" \
		--env "GOOSE_DRIVER" \
		--network "host" \
		--rm \
		$(BUILD_IMAGE):$(GIT_SHA) \
		-dir $(MIGRATION_DIR) up

build-show-volumes:
	docker images --format "{{.Repository}}:{{.Tag}} {{.Size}}"

ecs-redeploy:
	aws ecs update-service \
		--cluster $(ECS_CLUSTER) \
		--service $(ECS_SERVICE) \
		--force-new-deployment \
		--region $(AWS_DEFAULT_REGION) \
		--profile $(AWS_PROFILE) \
		--query "service.deployments[0].status" \
		--output text

down:
	docker compose down --remove-orphans --volumes

up: down
	docker compose up --detach

deploy:
	AWS_PROFILE=$(AWS_PROFILE) \
	AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) \
	AWS_DEFAULT_REGION=$(AWS_DEFAULT_REGION) \
	AWS_ECR_DOMAIN=$(AWS_ECR_DOMAIN) \
	./deploy.sh

migrate:
	goose -dir "$(MIGRATION_DIR)" up

migrate-status:
	goose -dir "$(MIGRATION_DIR)" status

migrate-validate:
	goose -dir "$(MIGRATION_DIR)" validate

start: build
	./goals