#!/usr/bin/env bash
# Dynamic help generation from OpenAPI spec

help_global() {
  cat <<'USAGE'
Usage: moneybird-cli [options] <resource> <action> [id] [--param value...]

Built-in commands:
  login [token]           Authenticate with a personal API token
  login --oauth           Authenticate via OAuth (requires client app)
  logout                  Remove stored credentials
  administrations list    List your administrations
  administration use <id> Set the current administration
  administration current  Show current administration
  completion <bash|zsh>   Output shell completion script
  update-spec             Update the cached OpenAPI spec
  config set <key> <val>  Set a configuration value
  config get <key>        Get a configuration value

Global options:
  --dev                   Target moneybird.dev instead of moneybird.com
  --administration <id>   Override the current administration
  --output <mode>         Output format: raw, pretty (default), table
  --fields <f1,f2,...>    Return only specified fields (supports nested: contact.company_name)
  --select <jq_expr>      Filter response with a jq expression
  --all                   Auto-paginate and return all results
  --verbose               Show debug information
  --dry-run               Show the request without executing
  --help                  Show help
  --version               Show version

USAGE

  if [[ -f "$SPEC_FILE" ]]; then
    echo "Resources:"
    help_list_resources
  else
    echo "Run 'moneybird-cli update-spec' to enable resource discovery."
  fi
}

help_list_resources() {
  spec_query '
    .paths | keys[]
    | split("/")
    | if .[1] == "{administration_id}" then .[2] else .[1] end
  ' | sed 's/{format}$//' | sort -u | grep -v '^$' | while read -r resource; do
    [[ "$resource" == "{"* ]] && continue
    printf "  %-35s\n" "$resource"
  done
}

help_resource() {
  local resource="$1"
  local resource_path
  resource_path=$(echo "$resource" | sed 's/\./\//g')

  echo "Usage: moneybird-cli $resource <action> [id] [--param value...]"
  echo ""

  if [[ ! -f "$SPEC_FILE" ]]; then
    echo "Standard actions: list, get, create, update, delete"
    return
  fi

  local base="/{administration_id}/${resource_path}"
  echo "Actions:"

  # Check each CRUD action against the spec, use spec summary for description
  local collection_path="${base}{format}"
  local member_path="${base}/{id}{format}"

  local summary

  summary=$(spec_query --arg p "$collection_path" '.paths[$p].get.summary // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "list" "$summary"

  summary=$(spec_query --arg p "$collection_path" '.paths[$p].post.summary // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "create [--param val...]" "$summary"

  summary=$(spec_query --arg p "$member_path" '.paths[$p].get.summary // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "get <id>" "$summary"

  summary=$(spec_query --arg p "$member_path" '(.paths[$p].patch.summary // .paths[$p].put.summary) // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "update <id> [--param val...]" "$summary"

  summary=$(spec_query --arg p "$member_path" '.paths[$p].delete.summary // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "delete <id>" "$summary"

  # Sync endpoints
  local sync_path="${base}/synchronization{format}"
  summary=$(spec_query --arg p "$sync_path" '.paths[$p].get.summary // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "sync" "$summary"
  summary=$(spec_query --arg p "$sync_path" '.paths[$p].post.summary // empty' 2>/dev/null)
  [[ -n "$summary" ]] && printf "  %-30s %s\n" "sync_fetch" "$summary"

  # Find custom actions from spec with their summaries
  local custom_actions
  custom_actions=$(spec_query --arg base "$base" '
    .paths | to_entries[]
    | select(.key | startswith($base))
    | .key as $path
    | .key | ltrimstr($base)
    | select(length > 0)
    | select(test("^/(\\{id\\})?\\{format\\}$") | not)
    | select(test("^/synchronization") | not)
    | sub("^/\\{id\\}/"; "<id> ")
    | sub("^/"; "")
    | sub("\\{format\\}$"; "")
    | sub("/\\{[a-z_]+\\}$"; " <value>")
  ' 2>/dev/null | sort -u)

  if [[ -n "$custom_actions" ]]; then
    echo ""
    echo "Custom actions:"
    while IFS= read -r action; do
      # Get summary from spec for this custom action
      local action_name
      action_name=$(echo "$action" | sed 's/^<id> //' | sed 's/ <value>$//')
      local action_summary=""
      # Try member path first, then collection path
      action_summary=$(spec_query --arg base "$base" --arg a "$action_name" '
        (.paths[$base + "/{id}/" + $a + "{format}"] //
         .paths[$base + "/" + $a + "{format}"] // {})
        | to_entries[]
        | select(.key | test("^(get|post|put|patch|delete)$"))
        | .value.summary // empty
      ' 2>/dev/null | head -1)
      if [[ -n "$action_summary" ]]; then
        printf "  %-30s %s\n" "$action" "$action_summary"
      else
        printf "  %s\n" "  $action"
      fi
    done <<< "$custom_actions"
  fi

  # Find sub-resources
  local sub_resources
  sub_resources=$(spec_query --arg r "$resource_path" '
    .paths | keys[]
    | select(test("/" + $r + "/\\{[a-z_]+\\}/"))
    | capture("/" + $r + "/\\{[a-z_]+\\}/(?<sub>[a-z_]+)")
    | .sub
  ' 2>/dev/null | sort -u)

  if [[ -n "$sub_resources" ]]; then
    echo ""
    echo "Sub-resources (use ${resource}:<sub-resource>):"
    while read -r sub; do
      printf "  %-25s\n" "$sub"
    done <<< "$sub_resources"
  fi
  echo ""
}

help_action() {
  local resource="$1" action="$2"
  local resource_path
  resource_path=$(echo "$resource" | sed 's/\./\//g')

  echo "Usage: moneybird-cli $resource $action [id] [--param value...]"
  echo ""

  if [[ ! -f "$SPEC_FILE" ]]; then
    return
  fi

  # Map action to HTTP method for standard CRUD
  local method_lower
  case "$action" in
    list|get) method_lower="get" ;;
    create) method_lower="post" ;;
    update) method_lower="patch" ;;
    delete) method_lower="delete" ;;
    *) method_lower="" ;;
  esac

  # Search for matching path in spec — use application/* content type
  local params
  params=$(spec_query --arg r "$resource_path" --arg a "$action" --arg m "$method_lower" '
    .paths | to_entries[]
    | select(.key | test($r))
    | select(
        if $m == "" then (.key | test($a)) else (.value[$m] // null | . != null) end
      )
    | .value[if $m == "" then (keys[] | select(test("^(get|post|put|patch|delete)$"))) else $m end]
    | select(.requestBody // null | . != null)
    | .requestBody.content | to_entries[0].value.schema.properties
    | to_entries[]
    | .value.properties // {}
    | to_entries[]
    | "  --\(.key) <\(.value.type // "string")>\t\(.value.description // "")"
  ' 2>/dev/null | head -30 || true)

  if [[ -n "$params" ]]; then
    echo "Parameters:"
    echo "$params" | column -t -s $'\t'
    echo ""
  fi

  # Show query parameters
  local query_params
  query_params=$(spec_query --arg r "$resource_path" --arg a "$action" --arg m "$method_lower" '
    .paths | to_entries[]
    | select(.key | test($r))
    | (.value.parameters // [])[]
    | select(.in == "query")
    | "  --\(.name) <\(.schema.type // "string")>\t\(.description // "")"
  ' 2>/dev/null | head -20)

  if [[ -n "$query_params" ]]; then
    echo "Query parameters:"
    echo "$query_params" | column -t -s $'\t'
    echo ""
  fi
}
