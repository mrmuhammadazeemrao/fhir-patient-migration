PG_BIN ?= /Applications/Postgres.app/Contents/Versions/18/bin
PYTHON = .venv/bin/python
PG_DATA = $(CURDIR)/.local/postgres

.PHONY: db-init db-start db-stop backend frontend check

# Initialize an isolated development database once, using the local .env password.
db-init:
	test -f .env
	test ! -f "$(PG_DATA)/PG_VERSION"
	mkdir -p .local
	set -a; . ./.env; set +a; printf '%s\n' "$$POSTGRES_PASSWORD" | "$(PG_BIN)/initdb" -D "$(PG_DATA)" -U "$$POSTGRES_USER" --auth=scram-sha-256 --pwfile=/dev/stdin --encoding=UTF8 --locale=C
	$(MAKE) db-start
	set -a; . ./.env; set +a; PGPASSWORD="$$POSTGRES_PASSWORD" "$(PG_BIN)/createdb" -h "$$POSTGRES_HOST" -p "$$POSTGRES_PORT" -U "$$POSTGRES_USER" "$$POSTGRES_DB"

db-start:
	@"$(PG_BIN)/pg_ctl" -D "$(PG_DATA)" status >/dev/null 2>&1 || { set -a; . ./.env; set +a; "$(PG_BIN)/pg_ctl" -D "$(PG_DATA)" -l "$(CURDIR)/.local/postgres.log" -o "-h 127.0.0.1 -p $$POSTGRES_PORT -c unix_socket_directories=''" start; }

db-stop:
	"$(PG_BIN)/pg_ctl" -D "$(PG_DATA)" stop -m fast

backend:
	$(PYTHON) backend/manage.py runserver 127.0.0.1:8000

frontend:
	cd frontend && npm run dev

check:
	$(PYTHON) -m pip check
	$(PYTHON) backend/manage.py check --database default
	cd frontend && npm run build
