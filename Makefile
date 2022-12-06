.PHONY: help clean clean-all clean-assets upgrade-dev-deps dev build test code	\
	deploy release deploy-prod

pkg := textio-pyinflect
codedir := $(shell echo $(pkg) | sed 's/-/_/'g)
testdir := tests

syspython := python3

python := venv/bin/python
pip := venv/bin/pip-s3
aws := venv/bin/aws

codefiles := $(shell find $(codedir) -name '*.py' -not \( -path '*__pycache__*' \))
testfiles := $(shell find $(testdir) -name '*' -not \( -path '*__pycache__*' \))

# cite: https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
# automatically documents the makefile, by outputing everything behind a ##
help:
	@grep -E '^[0-9a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

clean:  ## Clean build artifacts but NOT downloaded assets
	# Python build
	find $ . -name '__pycache__' -exec rm -Rf {} +
	find $ . -name '*.py[co]' -delete
	rm -rf build
	rm -rf dist
	rm -rf *.egg-info
	rm -rf *.egg
	rm -rf *.eggs
	rm -rf *.whl
	rm -rf $(pkg)-*

	# Textio build
	rm -rf venv*
	rm -f pips3-master.tar.gz
	rm -f .venv
	rm -f .dev
	rm -f .assets
	rm -f .build
	rm -f .test
	rm -f .code
	rm -f .lint

	# Test
	rm -rf .cache/
	rm -f .coverage
	rm -rf htmlcov/
	rm -f pytest-out.xml
	rm -rf .pytest_cache/

clean-all: clean clean-assets  ## Clean everything

venv:
	$(syspython) -m venv venv

.venv: venv
	venv/bin/pip install --upgrade pip wheel setuptools --disable-pip-version-check
	venv/bin/pip install --progress-bar off "awscli~=1.0"
	$(aws) sts get-caller-identity
	$(aws) s3 cp s3://textio-pypi-us-west-2/pypi/0/dev/pips3/pips3-master.tar.gz .
	venv/bin/pip install --progress-bar off pips3-master.tar.gz
	$(pip) install --upgrade pips3
	touch .venv

pips3-master.tar.gz:
	rm -f .venv
	$(MAKE) .venv  # pips3-master.tar.gz downloaded as a side-effect

%_frozen.txt: %.txt
	$(MAKE) .venv
	$(syspython) -m venv "venv-$@"
	venv-$@/bin/pip install --upgrade pip wheel setuptools --disable-pip-version-check
	$(pip) --pip="venv-$@/bin/pip" install pips3 --disable-pip-version-check
	. "venv-$@/bin/activate" && \
		if [ -e "$@" ]; then pip-s3 install -r "$@"; fi && \
		pip-s3 install -r "$<" && \
		if [ -e "$@" ]; then chmod 644 "$@"; fi && \
		echo '# DO NOT EDIT, use Makefile' > "$@" && \
		pip freeze -l >> "$@" && \
		sed -E -i'.bak' -e 's/scikit-learn([^[])/scikit-learn[alldeps]\1/' "$@" && \
		rm -f "$@.bak" && \
		chmod 444 "$@"
	rm -rf "venv-$@"

upgrade-dev-deps:  ## Upgrade the dev-time dependencies
	rm -f requirements_dev_frozen.txt
	$(MAKE) clean
	$(MAKE) requirements_dev_frozen.txt

.dev: .venv requirements_dev_frozen.txt
	$(pip) install --progress-bar off -r requirements_dev_frozen.txt
	touch .dev

.assets: .dev
	touch .assets

clean-assets:  ## Clean only assets so they will be re-downloaded
	rm -f .assets

.build: .dev .assets $(codefiles)
	$(pip) install --progress-bar off -e .
	touch .build

# Arguments for pytest, e.g. "make test t='-k MyTest'"
t ?=
.test: .dev .build $(testfiles)
	venv/bin/py.test $(testdir) $(t) -vv --failed-first \
		--junit-xml=pytest-out.xml \
		--cov=$(codedir) --cov-report=term-missing --cov-report=html; \
		rc="$$?"; \
		if [ "$$rc" -eq 5 ]; then echo "No tests in './$(testdir)', skipping"; \
		elif [ "$$rc" -ne 0 ]; then exit "$$rc"; \
		fi
	touch .test

check ?=
.lint: .dev .build $(codefiles) $(testfiles)
ifeq ($(check), true)
	venv/bin/black --line-length=101 --safe -v --check $(codefiles) $(testfiles) setup.py
else
	venv/bin/black --line-length=101 --safe -v $(codefiles) $(testfiles) setup.py
endif
	venv/bin/isort --recursive $(codedir) $(testdir)
	venv/bin/flake8 $(codefiles) $(testfiles) setup.py
	$(python) setup.py check
	touch .lint

.code: .dev .build .test .lint
	touch .code

dev: .dev  ## Setup the local dev environment

build: .build  ## Build into local environment (for use in REPL, etc.)

test: .test  ## Run unit tests

lint: .lint

code: .code  ## Build code, and run all checks (tests, pep8, manifest check, etc.)

deploy: .dev .code  ## Upload to private PyPI under the branch.  Normally called by CircleCI
	. venv/bin/activate && deploy.sh ./setup.py dev

# Custom release message, e.g. "make release msg='jobtype model'"
msg ?=
release: .dev .code  ## Release a new prod version: add a tag and Circle builds and uploads. Add a release message with: "make release msg='My release message'"
	. venv/bin/activate && release.sh ./setup.py "$(msg)"

deploy-prod: .dev .code  ## EMERGENCY USE ONLY. Upload to private PyPI under the version number. Normally called by CircleCI
	. venv/bin/activate && deploy.sh ./setup.py prod
