import Foundation

/// `eval "$(titan hook zsh)"`: routes a project's commands into its VM when you cd into it.
///
/// A project is picked up when it has `.titan/bin` (already set up) or has opted in by
/// committing `titan.lock` or a devcontainer.json. On first entry (or after the config
/// changes) the hook runs `titan activate`, which writes the shims without starting the
/// VM, so in a fresh clone `npm run dev` just works: the first command sets the VM up.
/// Plain repos (only package.json etc.) get a one-time hint instead of being taken over.
/// The hook itself only tests a few files; it spawns titan only to activate.
public enum ShellHook {
    public static func script(for shell: String, titan: String = "titan") -> String? {
        let template: String
        switch shell {
        case "zsh": template = zsh
        case "bash": template = bash
        default: return nil
        }
        return template.replacingOccurrences(of: "__TITAN__", with: shellQuote(titan))
    }

    /// Files that mark an opted-in project (relative to its root).
    public static let optInMarkers = ["titan.lock", ".devcontainer/devcontainer.json", ".devcontainer.json"]
    /// Manifests that earn the one-time "run titan up" hint.
    static let hintManifests = ["package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Gemfile", "pom.xml"]

    static let zsh = #"""
    export TITAN_HOOK=zsh
    typeset -gA _titan_hinted
    _titan_stale() {
      local r="$1" b="$1/.titan/bin" f
      [[ -d "$b" ]] || return 0
      for f in "$r/titan.lock" "$r/.devcontainer/devcontainer.json" "$r/.devcontainer.json"; do
        [[ -f "$f" && "$f" -nt "$b" ]] && return 0
      done
      return 1
    }
    _titan_hook() {
      local dir="$PWD" found="" activated=""
      while true; do
        if [[ -d "$dir/.titan/bin" || -f "$dir/titan.lock" || -f "$dir/.devcontainer/devcontainer.json" || -f "$dir/.devcontainer.json" ]]; then
          found="$dir"; break
        fi
        [[ "$dir" == "/" || "$dir" == "$HOME" || -z "$dir" ]] && break
        dir="${dir:h}"
      done
      if [[ -n "$found" ]] && _titan_stale "$found"; then
        if __TITAN__ activate -C "$found" --quiet; then activated=1; else found=""; fi
      fi
      if [[ "$found" != "${TITAN_PROJECT_ROOT:-}" || -n "$activated" ]]; then
        if [[ -n "${TITAN_PROJECT_ROOT:-}" ]]; then
          path=(${path:#"$TITAN_PROJECT_ROOT/.titan/bin"})
          unset TITAN_PROJECT_ROOT
        fi
        if [[ -n "$found" ]]; then
          export TITAN_PROJECT_ROOT="$found"
          path=("$found/.titan/bin" $path)
        fi
      fi
      if [[ -z "$found" && -z "${TITAN_QUIET:-}" && -z "${_titan_hinted[$PWD]:-}" ]]; then
        local m
        for m in package.json pyproject.toml requirements.txt go.mod Cargo.toml Gemfile pom.xml; do
          if [[ -f "$PWD/$m" ]]; then
            _titan_hinted[$PWD]=1
            print -P "%F{8}titan: run \`titan create\` to work on ${PWD:t} in its own VM%f" >&2
            break
          fi
        done
      fi
    }
    # Provides `titan` even when its folder isn't on PATH.
    titan() { __TITAN__ "$@"; }
    autoload -Uz add-zsh-hook
    add-zsh-hook chpwd _titan_hook
    _titan_hook
    """#

    static let bash = #"""
    export TITAN_HOOK=bash
    _titan_hinted=":"
    _titan_path_remove() {
      local p out="" IFS=:
      set -f
      for p in $PATH; do [ "$p" = "$1" ] || out="${out:+$out:}$p"; done
      set +f
      PATH="$out"
    }
    _titan_stale() {
      local r="$1" b="$1/.titan/bin" f
      [ -d "$b" ] || return 0
      for f in "$r/titan.lock" "$r/.devcontainer/devcontainer.json" "$r/.devcontainer.json"; do
        if [ -f "$f" ] && [ "$f" -nt "$b" ]; then return 0; fi
      done
      return 1
    }
    _titan_hook() {
      [ "$PWD" = "${_titan_last_pwd:-}" ] && return
      _titan_last_pwd="$PWD"
      local dir="$PWD" found="" activated=""
      while :; do
        if [ -d "$dir/.titan/bin" ] || [ -f "$dir/titan.lock" ] || [ -f "$dir/.devcontainer/devcontainer.json" ] || [ -f "$dir/.devcontainer.json" ]; then
          found="$dir"; break
        fi
        if [ "$dir" = "/" ] || [ "$dir" = "$HOME" ] || [ -z "$dir" ]; then break; fi
        dir="$(dirname "$dir")"
      done
      if [ -n "$found" ] && _titan_stale "$found"; then
        if __TITAN__ activate -C "$found" --quiet; then activated=1; else found=""; fi
      fi
      if [ "$found" != "${TITAN_PROJECT_ROOT:-}" ] || [ -n "$activated" ]; then
        if [ -n "${TITAN_PROJECT_ROOT:-}" ]; then
          _titan_path_remove "$TITAN_PROJECT_ROOT/.titan/bin"
          unset TITAN_PROJECT_ROOT
        fi
        if [ -n "$found" ]; then
          export TITAN_PROJECT_ROOT="$found"
          PATH="$found/.titan/bin:$PATH"
        fi
        hash -r
      fi
      if [ -z "$found" ] && [ -z "${TITAN_QUIET:-}" ]; then
        case "$_titan_hinted" in *":$PWD:"*) return ;; esac
        local m
        for m in package.json pyproject.toml requirements.txt go.mod Cargo.toml Gemfile pom.xml; do
          if [ -f "$PWD/$m" ]; then
            _titan_hinted="$_titan_hinted$PWD:"
            echo "titan: run \`titan create\` to work on $(basename "$PWD") in its own VM" >&2
            break
          fi
        done
      fi
    }
    # Provides `titan` even when its folder isn't on PATH.
    titan() { __TITAN__ "$@"; }
    case ";${PROMPT_COMMAND:-};" in
      *";_titan_hook;"*) ;;
      *) PROMPT_COMMAND="_titan_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
    """#
}
