# Makefile

.PHONY: all format check validate test test-cov mutation vulture complexity xenon bandit pyright fix reformat-ruff fix-ruff

# Default target: runs format and check
all: validate test

# Format the code using ruff
format:
	uv run ruff format --check --diff .

reformat-ruff:
	uv run ruff format .

# Check the code using ruff
check:
	uv run ruff check .

fix-ruff:
	uv run ruff check . --fix

fix: reformat-ruff fix-ruff
	@echo "Updated code."

test:
	uv run pytest

test-cov:
	uv run pytest --cov --cov-report=xml --cov-report=term-missing

# Mutation testing (mutates torrent_compress_recovery/, runs the test suite per mutant)
mutation:
	uv run mutmut run
	uv run mutmut results

vulture:
	uv run vulture . --exclude .venv,migrations,tests,mutants --make-whitelist

complexity:
	uv run radon cc . -a -nc -e mutants

xenon:
	uv run xenon -b D -m B -a B -i mutants .

bandit:
	uv run bandit -c pyproject.toml -r .

pyright:
	uv run pyright

# Validate the code (format + check)
validate: format check complexity xenon bandit pyright vulture
	@echo "Validation passed. Your code is ready to push."
