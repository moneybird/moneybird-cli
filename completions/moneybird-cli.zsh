#compdef moneybird-cli
# Zsh completion for moneybird-cli

_moneybird_cli() {
  local config_dir
  if [[ -n "${MONEYBIRD_CONFIG_DIR:-}" ]]; then
    config_dir="$MONEYBIRD_CONFIG_DIR"
  elif [[ -d ".moneybird-cli" ]]; then
    config_dir="$PWD/.moneybird-cli"
  else
    config_dir="$HOME/.config/moneybird-cli"
  fi
  local spec_file="$config_dir/openapi.json"

  local -a global_opts=(
    '--dev[Target moneybird.dev]'
    '--administration[Override administration]:id:'
    '--output[Output format]:mode:(raw pretty table)'
    '--fields[Return only specified fields]:fields:'
    '--select[Filter with jq expression]:expression:'
    '--verbose[Show debug info]'
    '--dry-run[Show request without executing]'
    '--help[Show help]'
    '--version[Show version]'
  )

  local -a builtin_cmds=(login logout administrations administration update update-spec config)

  # Get resources from spec
  local -a resources=($builtin_cmds)
  if [[ -f "$spec_file" ]]; then
    resources+=($(jq -r '
      .paths | keys[]
      | split("/")
      | if .[1] == "{administration_id}" then .[2] else .[1] end
      | select(test("^\\{") | not)
      | sub("\\{format\\}$"; "")
    ' "$spec_file" 2>/dev/null | sort -u | grep -v '^$'))
  fi

  local -a actions=(list get create update delete)

  _arguments -C \
    $global_opts \
    '1:resource:compadd -a resources' \
    '2:action:->action' \
    '3:id:' \
    '*:params:' \
    && return

  case "$state" in
    action)
      case "$words[2]" in
        administration) actions=(use current) ;;
        administrations) actions=(list) ;;
        config) actions=(get set) ;;
        *)
          if [[ -f "$spec_file" ]]; then
            local resource_path="${words[2]//\.//}"
            local custom
            custom=$(jq -r --arg r "$resource_path" '
              .paths | keys[]
              | select(test("/" + $r + "/"))
              | split("/") | last
              | sub("\\{format\\}$"; "")
              | select(. != "{id}" and . != $r and length > 0)
            ' "$spec_file" 2>/dev/null | sort -u)
            [[ -n "$custom" ]] && actions+=($=custom)
          fi
          ;;
      esac
      _describe 'action' actions
      ;;
  esac
}

_moneybird_cli "$@"
