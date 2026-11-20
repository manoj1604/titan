# 9. Editors (VS Code and others)

**Time:** 3 minutes

**Any editor works.** Your files stay on your Mac, so open the project folder in VS Code,
Cursor, Zed, Xcode, Vim, or anything else, exactly as before. The VM sees every save
instantly.

## The editor's built-in terminal

Editors like VS Code open your normal shell (zsh) in their terminal panel. That shell loads
the Titan hook, so **in a project folder, `npm`, `python` and the rest run in the VM**, just
like in Terminal.app.

```console
titan: shop → VM  (node npm npx)
$ npm run dev
```

If you don't see the `titan:` line, the hook isn't loaded in that terminal. Open a new
terminal tab, or run `titan setup`.

## Make VS Code terminals open *inside* the VM

To have VS Code's terminal start as a shell **inside the Linux VM**, run this in the project:

```bash
titan vscode
```

```console
✓ Updated /Users/you/code/shop/.vscode/settings.json
  New VS Code terminals in this folder now open inside the Titan VM.
```

This adds a "Titan VM" terminal profile to the project's `.vscode/settings.json` and makes
it the default. To undo it, pick a different default terminal profile in VS Code, or remove
those lines from the file.

If your `settings.json` contains comments, Titan won't rewrite it. It prints the lines for
you to paste instead.

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
titan rebuild
node --inspect=0.0.0.0:9229 server.js     # in the project (runs in the VM)
```

Then attach your editor's debugger to `localhost:9229`.

Next: [Disk space, memory and cleanup →](10-disk-and-cleanup.md)
