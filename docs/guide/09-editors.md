# 9. Editors (VS Code and others)

**Time:** 3 minutes

**Any editor works.** Your files stay on your Mac, so open the project folder in VS Code,
Cursor, Zed, Xcode, Vim, or anything else, exactly as before. The VM sees every save
instantly.

## Open the editor from the terminal

**From your Mac's terminal** (even inside a project), editor commands run on the Mac as
usual:

```bash
code .          # VS Code
cursor .        # Cursor (install its `cursor` command from Cursor's command palette)
```

**From inside the VM** (`titan shell`), the same commands open the editor **on your Mac**:

```console
root@titan-shop-65578934:/workspaces/shop# code src/App.tsx     ← opens in VS Code on the Mac
root@titan-shop-65578934:/workspaces/shop# code                 ← opens the whole project
root@titan-shop-65578934:/workspaces/shop# open http://localhost:5173   ← opens your Mac's browser
```

| Inside `titan shell` | Opens on the Mac |
|---|---|
| `code`, `cursor`, `zed`, `subl` + files | That editor, at those files (the app itself if its command isn't installed) |
| `open` / `xdg-open` + a URL or file | Your default browser or app |
| Tools that open a browser (`vite --open`, `gh auth login`) | Your Mac's browser, through `$BROWSER` |

Only **files in the project folder** can open on the Mac, because those are the files the
Mac has. Something like `code /etc/hosts` explains that it only exists inside the VM. This
works while `titan shell` is open.

## The editor's built-in terminal

Editors like VS Code open your normal shell (zsh) in their terminal panel. That shell loads
the Titan hook, so **in a project folder, `npm`, `python` and the rest run in the VM**, just
like in Terminal.app.

```console
$ npm run dev
```

Not sure it's routed? `which npm` shows `…/shop/.titan/bin/npm` in a project folder. If it
shows your Mac's npm, open a new terminal tab, or run `titan create` in a project.

## VS Code terminals open *inside* the VM

If VS Code is installed, the first `titan create` sets its terminal to start as a Linux
shell **inside the VM** in every Titan project:

| Folder you open in VS Code | New terminal |
|---|---|
| A Titan project (`devcontainer.json`, `titan.lock`, or one you ran `titan up` in) | `root@titan-shop-…:/workspaces/shop#`, inside its VM |
| Any other folder | Your normal Mac shell |

- It adds one terminal profile, "Titan", to VS Code's user settings and makes it the default.
  Your other settings are left as they were, and a backup is saved first
  (`settings.json.titan-backup`).
- If the VM can't start, the terminal says why and opens a Mac shell instead.
- For a Mac terminal in a Titan project, use the **⌄** next to **+** in the terminal panel → **zsh**.
- It also hides each project's `.titan` folder (Titan's local helpers) from the explorer and
  search. To see it, set `"**/.titan": false` under `files.exclude` in VS Code's settings.
- To undo it, delete the "Titan" profile and the `terminal.integrated.defaultProfile.osx`
  line from VS Code's settings (or restore the backup).

If your settings file has comments or its own terminal profiles, Titan leaves it alone.

## Language features (autocomplete, go-to-definition)

Editors read your code on the Mac. Most language features work from the project's files
(`node_modules`, type definitions and so on), which the VM writes into your project folder.

Some language servers need the language installed on the Mac itself (for example a Python
extension looking for an interpreter). Two options:

- **Point the editor at the project's files.** Dependencies installed in the VM land in the
  project folder (`node_modules/`), which editors read directly.
- **Use VS Code Dev Containers** for a full in-VM editor. It reads the same
  `devcontainer.json` Titan uses.

## Debugging

Start your app in debug mode in the VM and attach from the editor over a forwarded port.
For example, with Node:

```jsonc
// devcontainer.json
"forwardPorts": [3000, 9229]
```

```bash
titan up --rebuild
node --inspect=0.0.0.0:9229 server.js     # in the project (runs in the VM)
```

Then attach your editor's debugger to `localhost:9229`.

Next: [Disk space, memory and cleanup →](10-disk-and-cleanup.md)
