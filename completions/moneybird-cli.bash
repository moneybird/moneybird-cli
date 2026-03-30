#!/usr/bin/env bash
# Bash completion for moneybird-cli

_moneybird_cli() {
  local cur prev words cword
  _init_completion || return

  local config_dir="${MONEYBIRD_CONFIG_DIR:-$HOME/.config/moneybird-cli}"
  local spec_file="$config_dir/openapi.json"

  # Global flags
  local global_opts="--dev --administration --output --fields --select --verbose --dry-run --help --version --child-id"
  local builtin_cmds="login logout administrations administration update-spec config"

  # Position of resource/action in words (skip global flags)
  local resource="" action="" pos=0
  for ((i = 1; i < cword; i++)); do
    case "${words[i]}" in
      --dev|--verbose|--dry-run|--help|--version) ;;
      --administration|--output|--fields|--select|--child-id) ((i++)) ;;
      --*) ((i++)) ;;  # skip --param value pairs
      *)
        if [[ $pos -eq 0 ]]; then resource="${words[i]}"; pos=1
        elif [[ $pos -eq 1 ]]; then action="${words[i]}"; pos=2
        else pos=3
        fi
        ;;
    esac
  done

  # Completing global flags
  if [[ "$cur" == -* ]]; then
    if [[ -n "$resource" && -n "$action" && -f "$spec_file" ]]; then
      # Action-level: suggest parameters from spec
      local resource_path
      resource_path=$(echo "$resource" | sed 's/\./\//g')
      local params
      params=$(jq -r --arg r "$resource_path" '
        .paths | to_entries[]
        | select(.key | test($r))
        | .value[].requestBody?.content? // {}
        | to_entries[0]?.value?.schema?.properties? // {}
        | to_entries[].value.properties? // {}
        | keys[] | "--" + .
      ' "$spec_file" 2>/dev/null | sort -u)
      COMPREPLY=($(compgen -W "$global_opts $params" -- "$cur"))
    else
      COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
    fi
    return
  fi

  # Completing resource (first positional)
  if [[ $pos -eq 0 ]]; then
    local resources="$builtin_cmds"
    if [[ -f "$spec_file" ]]; then
      resources="$resources $(jq -r '
        .paths | keys[]
        | split("/")
        | if .[1] == "{administration_id}" then .[2] else .[1] end
        | select(test("^\\{") | not)
        | sub("\\{format\\}$"; "")
      ' "$spec_file" 2>/dev/null | sort -u | grep -v '^$')"
    fi
    COMPREPLY=($(compgen -W "$resources" -- "$cur"))
    return
  fi

  # Completing action (second positional)
  if [[ $pos -eq 1 ]]; then
    local actions="list get create update delete"
    if [[ -f "$spec_file" ]]; then
      local resource_path
      resource_path=$(echo "$resource" | sed 's/\./\//g')
      local custom
      custom=$(jq -r --arg r "$resource_path" '
        .paths | keys[]
        | select(test("/" + $r + "/"))
        | split("/") | last
        | sub("\\{format\\}$"; "")
        | select(. != "{id}" and . != $r and length > 0)
      ' "$spec_file" 2>/dev/null | sort -u)
      [[ -n "$custom" ]] && actions="$actions $custom"
    fi
    # Built-in sub-commands
    case "$resource" in
      administration) actions="use current" ;;
      administrations) actions="list" ;;
      config) actions="get set" ;;
    esac
    COMPREPLY=($(compgen -W "$actions" -- "$cur"))
    return
  fi
}

complete -F _moneybird_cli moneybird-cli
