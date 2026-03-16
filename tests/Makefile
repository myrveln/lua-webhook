# Portable local + CI test runner.
# Usage (from ./tests):
#   make test all
#   make test auth
#
# This Makefile is intentionally thin so it works on both:
# - macOS / Xcode CLT make (BSD make)
# - Linux make (GNU make)

ROOT=..

PYTHON?=python3
VENV?=.venv
PIP=$(VENV)/bin/pip
PY=$(VENV)/bin/python

# Keep output clean.
PIP_DISABLE_PIP_VERSION_CHECK=1
PIP_FLAGS=--disable-pip-version-check -q

DEPS_STAMP=$(VENV)/.deps.stamp

BASE_URL?=http://localhost:8080/webhook
BASE_URL_CONFIG?=http://localhost:8081/webhook

TEST_API_KEY?=test-api-key
TEST_CONFIG_API_KEY?=test-config-key

COMPOSE?=docker compose

# Extra args to pass through to pytest (CI uses this for coverage flags)
PYTEST_ARGS?=

TEST_MODES=all noauth auth cors rate_limit hash_auth callback_allowlist

.PHONY: test deps venv clean $(TEST_MODES)

venv:
	@test -x "$(PY)" || $(PYTHON) -m venv "$(VENV)"

$(DEPS_STAMP): requirements.txt venv
	@PIP_DISABLE_PIP_VERSION_CHECK=1 "$(PIP)" install $(PIP_FLAGS) -r requirements.txt >/dev/null
	@touch "$(DEPS_STAMP)"

deps: $(DEPS_STAMP)

clean:
	@rm -rf "$(VENV)" "$(DEPS_STAMP)" || true

test: deps
	@:

all: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh all

noauth: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh noauth

auth: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh auth

cors: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh cors

rate_limit: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh rate_limit

hash_auth: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh hash_auth

callback_allowlist: deps
	@BASE_URL="$(BASE_URL)" BASE_URL_CONFIG="$(BASE_URL_CONFIG)" \
	TEST_API_KEY="$(TEST_API_KEY)" TEST_CONFIG_API_KEY="$(TEST_CONFIG_API_KEY)" \
	COMPOSE="$(COMPOSE)" PYTEST_ARGS="$(PYTEST_ARGS)" \
	bash ./run_tests.sh callback_allowlist
