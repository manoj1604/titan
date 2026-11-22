# 8. Working in a team

**Time:** 5 minutes · **You'll learn to:** give every teammate the exact same setup, and
update it safely

## The idea

Two files in your repository describe the whole environment:

| File | Role |
|---|---|
| `.devcontainer/devcontainer.json` | **What** the environment is (runtime, ports, services, setup) |
| `titan.lock` | **Exactly which** builds to use (pinned digests) |

Commit both, and every teammate's VM is identical to yours.

## Set it up once (one person)

```bash
cd my-project
titan create        # writes devcontainer.json and titan.lock, starts the VM
git add .devcontainer/devcontainer.json titan.lock
git commit -m "Add Titan dev environment"
git push
```

## A teammate joins

They install Titan once ([guide](01-install.md)), then:

```bash
git clone <repo> && cd my-project
npm test            # or any command: the first one builds the identical VM
```

That's the entire onboarding. There's no "install Node 22, then Postgres 16, then…" README.

**Teammates who don't use Titan** can still use the same `devcontainer.json` with VS Code
Dev Containers or GitHub Codespaces, because it's the standard format.

## Change the environment

Say you need Redis now:

1. Add it to `devcontainer.json` (or run `titan add redis` and paste the lines).
2. Run `titan up` and check that it works.
3. Commit `devcontainer.json` and `titan.lock`.

When teammates pull the change, they run **`titan up`** (or `titan up --rebuild`) once:

- `titan up` starts new services and, if the VM is stopped, recreates it with the new config.
- If their VM is still running, `titan up` and `titan status` say
  "config changed… run `titan up --rebuild`". Rebuilding keeps their code and database data.

Until then, their running VM keeps working with the old setup, so nothing breaks mid-task.

## Update versions on purpose

Pinned versions never change by themselves, and that's the point. To move to the newest
builds of your tags (security fixes, patch releases):

```bash
rm titan.lock
titan up --rebuild        # pins the newest builds again and recreates the VM
```

Then run your tests and commit `titan.lock`.

**To change a major version** (for example Node 22 → 24): change the version in
`devcontainer.json`, then `titan up --rebuild`.

See what's currently pinned: open `titan.lock` (or look at the `lock` line in
`titan status`).

## Good habits

- **Always commit `titan.lock`** together with `devcontainer.json` changes.
- **Put setup steps in `postCreateCommand`,** not in a README. Anything a new teammate
  would have to do by hand belongs there.
- **Never commit secrets** in `devcontainer.json`. Use `.env` files (gitignored) that your
  app reads.
- **`.titan/` is local.** It hides itself from git automatically, so there's nothing to do.

Next: [Editors →](09-editors.md)
