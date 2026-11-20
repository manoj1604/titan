# Contributing to Titan

Thanks for helping! Bug reports, docs fixes, new templates and presets, and code are all
welcome. For anything bigger than a small fix, please open an issue first so we can agree on
the approach before you spend time on it.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security
problems privately, as described in [SECURITY.md](SECURITY.md), not in public issues.

## Development setup

You need:

- a Mac with Apple silicon, macOS 26+ (to run VMs; unit tests also run on macOS 15)
- Swift 6: Xcode 16+, or just the Command Line Tools (`xcode-select --install`), or a swift.org toolchain
- Go 1.22+ (builds the in-VM port forwarder)
- [Apple `container`](https://github.com/apple/container) 1.7+ for end-to-end tests

```bash
git clone https://github.com/manoj1604/titan && cd titan
make test                         # Swift unit tests + Go tests
make install PREFIX=~/.local      # builds release + forwarder, installs bin/ and share/titan/
```

## Project layout

| Path | What |
|---|---|
| `Sources/titan/` | The CLI: argument parsing and output (`Titan.swift`) |
| `Sources/TitanCore/Config/` | devcontainer.json parsing, detection results, services, toolchains, catalog |
| `Sources/TitanCore/Detection/` | Zero-config stack detection |
| `Sources/TitanCore/Project/` | Project discovery, state, lockfile, registry |
| `Sources/TitanCore/Runtime/` | `ContainerRuntime` protocol and the Apple `container` backend |
| `Sources/TitanCore/Engine/` | Lifecycle: up/down/run, ports, services, toolchains, gc, overview |
| `Sources/TitanCore/Integrations/` | Shell hook, shims, setup, VS Code, tunnels |
| `forwarder/` | The in-VM port forwarder (Go, static linux/arm64 binary) |
| `Tests/TitanCoreTests/` | Unit tests (swift-testing), using a `FakeRuntime` |
| `scripts/` | End-to-end tests, packaging, docs generation |
| `examples/` | Sample projects used by the end-to-end tests |

## Tests

- **Unit tests** (`swift test`) must not need `container` or the network. Use `FakeRuntime`
  and `TempProject` (see `Tests/TitanCoreTests/Support.swift`), and `tempPaths()` so tests
  never touch `~/Library`. Port checks are injected (`portIsFree:`), so tests don't depend
  on what the Mac is running.
- **Shell hook tests** run real `/bin/zsh` and `/bin/bash` against a fake `titan`.
- **End-to-end tests** drive real VMs. They take minutes and download images:
  ```bash
  scripts/e2e.sh                # 16 checks against examples/todo-api
  scripts/e2e-langs.sh          # Python, Go, Rust, Ruby, Java examples
  ```
  Run them before submitting changes to the engine, runtime or forwarder, and say in the PR
  that you did.

Bug fixes should come with a test that fails without the fix.

## Pull requests

- Keep each PR focused, and describe *why* as well as what.
- Run `make test`. If you changed any command's help text, run `scripts/gen-cli-docs.sh` and
  commit `docs/cli.md` (CI checks that it's current).
- Add a line under **Unreleased** in `CHANGELOG.md` for user-visible changes.
- User-facing text style: plain words, say what happened and what to do next, and no
  surprises (ask before changing user files, show downloads before pulling).

## Design principles

1. **Standard config.** Prefer Dev Container spec features over Titan-only settings, and put
   Titan-only settings under `customizations.titan`.
2. **Isolation by default.** One VM per project. Share only what's safe to share (read-only
   or lock-free).
3. **Never surprise.** No silent takeover, no deletion without asking, measurements over
   guesses.
4. **Verify against the real runtime.** Behaviour of Apple `container` (JSON shapes, mounts,
   networking) is checked live and captured in tests; see `docs/how-it-works.md`.

## Releasing (maintainers)

0. First release only: `scripts/set-repo.sh <github-owner>` fills in the repository
   placeholders; enable private vulnerability reporting in the repo settings; create the tap
   repository `<owner>/homebrew-titan`.
1. Update `Sources/TitanCore/Version.swift` and move the **Unreleased** notes in
   `CHANGELOG.md` under the new version with today's date.
2. `scripts/gen-cli-docs.sh`, `make test`, `scripts/e2e.sh`.
3. Commit, tag `vX.Y.Z`, and push the tag. The release workflow builds
   `titan-X.Y.Z-macos-arm64.tar.gz` (plus `.sha256`) and publishes a GitHub release.
4. Update `packaging/homebrew/titan.rb` (URL and sha256) in the tap repository.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE). Contributors keep their copyright; the project is
"Copyright The Titan Authors".
