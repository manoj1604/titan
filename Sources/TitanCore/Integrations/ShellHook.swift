import Foundation

/// `eval "$(titan hook zsh)"` — activates a project's shims when you cd into it.
public enum ShellHook {
    public static func script(for shell: String) -> String? {
        switch shell {
        case "zsh": return zsh
        case "bash": return bash
        default: return nil
        }
    }

    static let zsh = #"""
    export TITAN_HOOK=zsh
    _titan_hook() {
      local dir="$PWD" found=""
      while true; do
        if [[ -d "$dir/.titan/bin" ]]; then found="$dir"; break; fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
      done
      [[ "$found" == "${TITAN_PROJECT_ROOT:-}" ]] && return
      if [[ -n "${TITAN_PROJECT_ROOT:-}" ]]; then
        path=(${path:#"$TITAN_PROJECT_ROOT/.titan/bin"})
        unset TITAN_PROJECT_ROOT
      fi
      if [[ -n "$found" ]]; then
        export TITAN_PROJECT_ROOT="$found"
        path=("$found/.titan/bin" $path)
        if [[ -z "${TITAN_QUIET:-}" ]]; then
          local cmds=("$found"/.titan/bin/*(N:t))
          print -P "%F{cyan}titan%f: ${found:t} → VM  %F{8}(${cmds[*]})%f" >&2
        fi
      fi
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook chpwd _titan_hook
    _titan_hook
    """#

    static let bash = #"""
    export TITAN_HOOK=bash
    _titan_path_remove() {
      local p out="" IFS=:
      set -f
      for p in $PATH; do [ "$p" = "$1" ] || out="${out:+$out:}$p"; done
      set +f
      PATH="$out"
    }
    _titan_hook() {
      local dir="$PWD" found=""
      while :; do
        if [ -d "$dir/.titan/bin" ]; then found="$dir"; break; fi
        if [ "$dir" = "/" ] || [ -z "$dir" ]; then break; fi
        dir="$(dirname "$dir")"
      done
      [ "$found" = "${TITAN_PROJECT_ROOT:-}" ] && return
      if [ -n "${TITAN_PROJECT_ROOT:-}" ]; then
        _titan_path_remove "$TITAN_PROJECT_ROOT/.titan/bin"
        unset TITAN_PROJECT_ROOT
      fi
      if [ -n "$found" ]; then
        export TITAN_PROJECT_ROOT="$found"
        PATH="$found/.titan/bin:$PATH"
        [ -z "${TITAN_QUIET:-}" ] && echo "titan: $(basename "$found") → VM ($(ls "$found/.titan/bin" | tr '\n' ' '))" >&2
      fi
      hash -r
    }
    case ";${PROMPT_COMMAND:-};" in
      *";_titan_hook;"*) ;;
      *) PROMPT_COMMAND="_titan_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
    """#
}
