############################################################
# Example Makefile for showing usage of the Anchore Local
# CI/Test Harness.
############################################################


#### Docker Hub, git repos
############################################################
DEV_IMAGE_REPO := [your image repo]-dev
PROD_IMAGE_REPO := [your image repo]
TEST_HARNESS_REPO := https://github.com/anchore/test-infra.git


#### CircleCI environment variables (your use case may vary)
############################################################
export CI ?= false
export DOCKER_PASS ?=
export DOCKER_USER ?=
export LATEST_RELEASE_BRANCH ?=
export PROD_IMAGE_REPO ?=
export RELEASE_BRANCHES ?=

# Use $CIRCLE_BRANCH if it's set, otherwise use current HEAD branch
GIT_BRANCH := $(shell echo $${CIRCLE_BRANCH:=$$(git rev-parse --abbrev-ref HEAD)})

# Use $CIRCLE_PROJECT_REPONAME if it's set, otherwise the git project top level dir name
GIT_REPO := $(shell echo $${CIRCLE_PROJECT_REPONAME:=$$(basename `git rev-parse --show-toplevel`)})
TEST_IMAGE_NAME := $(GIT_REPO):dev

# Use $CIRCLE_SHA if it's set, otherwise use SHA from HEAD
COMMIT_SHA := $(shell echo $${CIRCLE_SHA:=$$(git rev-parse HEAD)})

# Use $CIRCLE_TAG if it's set
GIT_TAG ?= $(shell echo $${CIRCLE_TAG:=null})

CLUSTER_NAME := e2e-testing


# Environment configuration for make
############################################################
VENV := venv
ACTIVATE_VENV := . $(VENV)/bin/activate
PYTHON := $(VENV)/bin/python3
CI_USER := circleci

# Running make will invoke the help target
.DEFAULT_GOAL := help

# Run make serially. Note that recursively invoked make will still
# run recipes in parallel (unless they also contain .NOTPARALLEL)
.NOTPARALLEL:

CI_CMD := anchore-ci/ci_harness


#### Make targets
############################################################

.PHONY: all venv install install-dev build clean printvars help
.PHONY: test test-unit test-functional test-e2e lint
.PHONY: push push-dev push-rc push-prod push-rebuild

all: lint build test push ## Run all make targets

anchore-ci: ## Fetch test artifacts for the CI harness
	rm -rf /tmp/test-infra; git clone $(TEST_HARNESS_REPO) /tmp/test-infra
	mv ./anchore-ci ./anchore-ci-`date +%F-%H-%M-%S`; mv /tmp/test-infra/anchore-ci .

venv: $(VENV)/bin/activate ## Set up a virtual environment
$(VENV)/bin/activate:
	python3 -m venv $(VENV)

install: venv setup.py requirements.txt ## Install to virtual environment
	@$(ACTIVATE_VENV) && $(PYTHON) setup.py install

install-dev: venv setup.py requirements.txt ## Install to virtual environment in editable mode
	@$(ACTIVATE_VENV) && $(PYTHON) -m pip install --editable .

lint: venv anchore-ci ## Lint code (currently using flake8)
	@$(ACTIVATE_VENV) && $(CI_CMD) lint

# NOTE this is a local script - not provided as a shared task
# Included as an example
build: Dockerfile anchore-ci venv ## Build dev Docker image
	@$(CI_CMD) scripts/ci/build "$(COMMIT_SHA)" "$(GIT_REPO)" "$(TEST_IMAGE_NAME)"

test: ## Run all tests: unit, functional, and e2e
	@$(MAKE) test-unit
	@$(MAKE) test-functional
	@$(MAKE) test-e2e

test-unit: anchore-ci venv ## Run unit tests (tox)
	@$(ACTIVATE_VENV) && $(CI_CMD) test-unit

test-functional: anchore-ci venv ## Run functional tests (tox)
	@$(ACTIVATE_VENV) && $(CI_CMD) test-functional

# NOTE setup-e2e-tests and e2e-tests are local CI scripts
# Included here as an example
test-e2e: anchore-ci venv ## Set up and run end to end tests
test-e2e: CLUSTER_CONFIG := tests/e2e/kind-config.yaml
test-e2e: KUBERNETES_VERSION := 1.15.7
test-e2e: tests/e2e/kind-config.yaml
	$(CI_CMD) install-cluster-deps "$(VENV)"
	$(ACTIVATE_VENV) && $(CI_CMD) cluster-up "$(CLUSTER_NAME)" "$(CLUSTER_CONFIG)" "$(KUBERNETES_VERSION)"
	$(ACTIVATE_VENV) && $(CI_CMD) setup-e2e-tests '$(COMMIT_SHA)" "$(DEV_IMAGE_REPO)" "$(GIT_TAG)" "$(TEST_IMAGE_NAME)"
	$(ACTIVATE_VENV) && $(CI_CMD) e2e-tests
	$(ACTIVATE_VENV) && $(CI_CMD) cluster-down "$(CLUSTER_NAME)"

push-dev: anchore-ci ## Push dev Docker image to Docker Hub
	@$(CI_CMD) push-dev-image "$(COMMIT_SHA)" "$(DEV_IMAGE_REPO)" "$(GIT_BRANCH)" "$(TEST_IMAGE_NAME)"

push-rc: anchore-ci ## Push RC Docker image to Docker Hub (not available outside of CI)
	@$(CI_CMD) push-rc-image "$(COMMIT_SHA)" "$(DEV_IMAGE_REPO)" "$(GIT_TAG)"

push-prod: anchore-ci ## Push release Docker image to Docker Hub (not available outside of CI)
	@$(CI_CMD) push-prod-image-release "$(DEV_IMAGE_REPO)" "$(GIT_BRANCH)" "$(GIT_TAG)" "$(PROD_IMAGE_REPO)"

push-rebuild: anchore-ci ## Rebuild and push prod Docker image to Docker Hub (not available outside of CI)
	@$(CI_CMD) push-prod-image-rebuild "$(DEV_IMAGE_REPO)" "$(GIT_BRANCH)" "$(GIT_TAG)" "$(PROD_IMAGE_REPO)"

clean: anchore-ci ## Clean up the project directory and delete dev image
	@$(CI_CMD) clean "$(TEST_IMAGE_NAME)"

printvars: ## Print make variables
	@$(foreach V,$(sort $(.VARIABLES)),$(if $(filter-out environment% default automatic,$(origin $V)),$(warning $V=$($V) ($(value $V)))))

help: ## Show this usage message
	@printf "\n%s\n\n" "usage: make <target>"
	@grep -E '^[0-9a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[0;36m%-30s\033[0m %s\n", $$1, $$2}'
