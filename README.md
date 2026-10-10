# FHIR Patient Migration

Initial project scaffold.

## Stack

| Tool | Version |
| --- | --- |
| Python | 3.14.6 |
| Django | 5.2.18 (LTS) |
| Django REST Framework | 3.18.3 |
| PostgreSQL | 18.6 (installed Postgres.app) |
| Psycopg | 3.3.6 |
| HTTPX | 0.28.1 |
| Tenacity | 9.2.1 |
| python-dotenv | 1.2.4 |
| Node.js | 22.23.2 |
| npm | 10.9.8 |
| Vue | 3.5.43 |
| TypeScript | 6.0.3 |
| Vite | 8.3.4 |

Python and Node reuse the versions already installed on this computer. Django
5.2 is the long-term-support series and supports Python 3.14:
[Django release notes](https://docs.djangoproject.com/en/5.2/releases/5.2/).
The frontend uses the official
[create-vue initializer](https://github.com/vuejs/create-vue), with TypeScript
and without example components. `backend/requirements.txt` and
`frontend/package-lock.json` lock the installed dependencies.

## Local setup

Run commands from the repository root. The virtual environment, dependencies,
local `.env`, and development database have already been initialized on this
computer. PostgreSQL and application servers are stopped after setup validation.

To recreate the dependencies:

```sh
/opt/homebrew/opt/python@3.14/bin/python3.14 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements.txt
cd frontend
npm ci
cd ..
```

On another computer, use a Python 3.14 interpreter in the first command. The
`.python-version` and `.nvmrc` files record the selected runtime versions; pyenv
and nvm are optional and have not been installed by this setup.

For a fresh checkout, copy `.env.example` to `.env`, replace both placeholder
secrets with random values, then run `make db-init` once. The `.env` file uses
shell-compatible `KEY=value` assignments because the database commands also
load it. Do not commit `.env`.

The development PostgreSQL cluster lives in `.local/postgres`, listens on
`127.0.0.1:55432`, and uses password authentication. It is separate from other
Postgres.app databases. The Makefile defaults to the installed PostgreSQL 18
binary directory. To use another installation, pass its binary path, e.g.
`make db-start PG_BIN=/path/to/postgresql/bin`.

## Run

```sh
make db-start
.venv/bin/python backend/manage.py migrate
make backend
```

In a second terminal at the repository root:

```sh
make frontend
```

Backend: http://127.0.0.1:8000 (Django starter page).
Frontend: http://127.0.0.1:5173 (placeholder page).
Vite is configured to proxy future `/api` requests to Django.
There are no application API routes yet.

Use Ctrl+C to stop each application server, then `make db-stop` to stop the
database. `make db-start` starts it again without reinitializing its data.

## Verify

With PostgreSQL running, run `make check` to check Python dependencies, Django
configuration, frontend types, and the production frontend build. Only Django's
built-in migrations are present; no assessment tests or functionality have been
added at this setup stage.
