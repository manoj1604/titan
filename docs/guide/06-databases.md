# 6. Databases and other services

**Time:** 10 minutes · **You'll learn to:** add Postgres or Redis, connect to them, and keep
your data safe

A **service** is something your app talks to, like a database or a cache. Titan runs each
service in **its own small VM** next to your app's VM, so you don't install Postgres on your
Mac.

```
 VM "shop"      ── connects to "postgres:5432" ──▶  VM "shop-postgres"   (data on a volume)
 (your app)     ── connects to "redis:6379"   ──▶  VM "shop-redis"
```

## Add a database

```bash
titan add postgres redis
```

- In a project **without** a `devcontainer.json`, this creates one with the services in it.
- If you **already have** a `devcontainer.json`, Titan shows the lines to paste. It won't
  rewrite your file, because that would lose your comments:

```console
Add this to .devcontainer/devcontainer.json
(merge it into an existing "customizations.titan" block if there is one), then run `titan up`:

  "customizations": {
    "titan": { "services": ["postgres", "redis"] }
  }
```

Then start everything:

```console
$ titan up
▸ Pulling postgres:16-bookworm
▸ Starting service postgres (postgres:16-bookworm)
▸ Pulling redis:7-bookworm
▸ Starting service redis (redis:7-bookworm)
▸ Creating VM titan-shop-… from node:22-bookworm
✓ shop is running in titan-shop-…
  service  postgres (postgres:16-bookworm)  localhost:5432  → DATABASE_URL
  service  redis (redis:7-bookworm)  localhost:6379  → REDIS_URL
```

Services start **before** your app, so database migrations in your setup command work on the
first run.

> You can also add services when setting up a project:
> `titan create node --with postgres`

## Connect from your app

Titan gives your app ready-made connection strings as environment variables:

| Service | Variable your app gets |
|---|---|
| Postgres | `DATABASE_URL=postgres://postgres:postgres@postgres:5432/app` |
| Redis | `REDIS_URL=redis://redis:6379` |

Most frameworks read these automatically. In code:

```js
// Node (pg)
const client = new Client({ connectionString: process.env.DATABASE_URL })
```

```python
# Python
import os, psycopg
conn = psycopg.connect(os.environ["DATABASE_URL"])
```

The **service name is the hostname**: inside the VM, the database is at `postgres`, not
`localhost`.

Check it:

```console
$ titan run -- printenv DATABASE_URL
postgres://postgres:postgres@postgres:5432/app
```

## Connect from your Mac (TablePlus, DBeaver, psql…)

Services are also opened on your Mac's `localhost`:

| Setting | Value |
|---|---|
| Host | `localhost` (or `127.0.0.1`) |
| Port | `5432` (check `titan status`; it may be `5433` if 5432 was busy) |
| User / password | `postgres` / `postgres` |
| Database | `app` |

## Your data is safe

Database data lives on a **volume**, separate storage that outlives the VM:

| Command | Your database data |
|---|---|
| `titan down` | kept |
| `titan down --rm` | kept |
| `titan up --rebuild` | kept |
| `titan down --volumes` | **deleted** (this is how you reset the database) |

## Change the defaults

Use the longer form in `devcontainer.json` to change a version, password or database name:

```jsonc
"customizations": {
  "titan": {
    "services": {
      "postgres": {
        "image": "postgres:15",
        "env": { "POSTGRES_PASSWORD": "secret", "POSTGRES_DB": "shop" }
      },
      "redis": "redis:7"
    }
  }
}
```

`DATABASE_URL` updates to match (`postgres://postgres:secret@postgres:5432/shop`). Run
`titan up --rebuild` to apply the change. Your data is kept, but note that Postgres only uses
`POSTGRES_PASSWORD`/`POSTGRES_DB` when it **first** creates its data. To start fresh with
the new values, run `titan down --volumes` first.

## Any other service

Any Docker/OCI image works. Tell Titan its port and where it keeps data:

```jsonc
"services": {
  "search": {
    "image": "getmeili/meilisearch:v1.8",
    "port": 7700,
    "data": "/meili_data",
    "env": { "MEILI_ENV": "development" }
  }
}
```

Your app reaches it at `search:7700`.

## Remove a service

Delete it from `devcontainer.json` and run `titan up`. Its VM is removed, but its data
volume is kept in case you add it back.

## If something goes wrong

- **The app can't reach `postgres`:** run `titan up`. It refreshes how the app finds its
  services (needed if a service restarted on its own).
- **"isn't listening yet":** the first Postgres start initializes the database and can take
  a few seconds. Check its log with `titan logs postgres` (`-f` to follow it live).

Next: [Ports, URLs and sharing →](07-ports-and-sharing.md)
