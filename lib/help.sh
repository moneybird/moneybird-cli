#!/usr/bin/env bash
# Dynamic help generation from OpenAPI spec

help_global() {
  cat <<'USAGE'
Usage: moneybird-cli [options] <resource> <action> [args...] [--param value...]

Built-in commands:
  login [token]           Authenticate and select administration
  login --oauth           Authenticate via OAuth (requires client app)
  logout [id|--all]       Log out of one or all administrations
  administration list     List logged-in administrations
  administration current  Show current administration
  administration use <id> Switch to another administration
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

  echo "Usage: moneybird-cli $resource <action> [args...] [--param value...]"
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

  # Map action to HTTP method for standard CRUD
  local method_lower
  case "$action" in
    list|get) method_lower="get" ;;
    create) method_lower="post" ;;
    update) method_lower="patch" ;;
    delete) method_lower="delete" ;;
    *) method_lower="" ;;
  esac

  # Find the matching spec path to build an accurate usage line
  local usage_args=""
  if [[ -f "$SPEC_FILE" ]]; then
    local base="/{administration_id}/${resource_path}"
    local matched_path=""

    case "$action" in
      list)   matched_path="${base}{format}" ;;
      create) matched_path="${base}{format}" ;;
      get)    matched_path="${base}/{id}{format}" ;;
      update) matched_path="${base}/{id}{format}" ;;
      delete) matched_path="${base}/{id}{format}" ;;
      *)
        # Custom action — search spec for exact match
        matched_path=$(spec_query --arg base "$base" --arg a "$action" '
          (.paths[$base + "/{id}/" + $a + "{format}"] // null) as $member
          | (.paths[$base + "/" + $a + "{format}"] // null) as $collection
          | if $member != null then $base + "/{id}/" + $a + "{format}"
            elif $collection != null then $base + "/" + $a + "{format}"
            else empty end
        ' 2>/dev/null | head -1)
        ;;
    esac

    # Extract path parameters that the user needs to provide
    # (exclude {administration_id} and {format} which are handled automatically)
    if [[ -n "$matched_path" ]]; then
      usage_args=$(echo "$matched_path" \
        | grep -oE '\{[a-z_]+\}' \
        | { grep -v '{administration_id}\|{format}' || true; } \
        | sed 's/{/</g' | sed 's/}/>/g' \
        | tr '\n' ' ' \
        | sed 's/ $//')
    fi
  fi

  if [[ -n "$usage_args" ]]; then
    echo "Usage: moneybird-cli $resource $action $usage_args [--param value...]"
  else
    echo "Usage: moneybird-cli $resource $action [--param value...]"
  fi
  echo ""

  if [[ ! -f "$SPEC_FILE" ]]; then
    return
  fi

  # Find the HTTP method for the matched path
  local spec_method="$method_lower"
  if [[ -z "$spec_method" && -n "$matched_path" ]]; then
    spec_method=$(spec_query --arg p "$matched_path" '
      .paths[$p] // {} | keys[] | select(test("^(get|post|put|patch|delete)$"))
    ' 2>/dev/null | head -1)
  fi

  # Show summary and description from the spec
  if [[ -n "$matched_path" && -n "$spec_method" ]]; then
    local summary description
    summary=$(spec_query --arg p "$matched_path" --arg m "$spec_method" \
      '.paths[$p][$m].summary // empty' 2>/dev/null)
    description=$(spec_query --arg p "$matched_path" --arg m "$spec_method" \
      '.paths[$p][$m].description // empty' 2>/dev/null)
    [[ -n "$summary" ]] && echo "$summary"
    if [[ -n "$description" && "$description" != "$summary" ]]; then
      echo "$description" | sed 's/^###/\n###/'
    fi
    echo ""
  fi

  # Show request body parameters
  local params=""
  if [[ -n "$matched_path" && -n "$spec_method" ]]; then
    params=$(spec_query --arg p "$matched_path" --arg m "$spec_method" '
      .paths[$p][$m]
      | select(.requestBody // null | . != null)
      | .requestBody.content | to_entries[0].value.schema.properties
      | to_entries[]
      | .value.properties // {}
      | to_entries[]
      | "  --\(.key) <\(.value.type // "string")>\t\(.value.description // "")"
    ' 2>/dev/null | head -30 || true)
  fi

  if [[ -n "$params" ]]; then
    echo "Parameters:"
    echo "$params" | column -t -s $'\t'
    echo ""
  fi

  # Show query parameters (resolve $ref pointers)
  local query_params=""
  if [[ -n "$matched_path" ]]; then
    query_params=$(spec_query --arg p "$matched_path" --arg m "$spec_method" '
      . as $root
      | ((.paths[$p].parameters // []) + (.paths[$p][$m].parameters // []))
      | map(if has("$ref") then
          (."$ref" | ltrimstr("#/") | split("/")) as $parts
          | $root | getpath($parts)
        else . end)
      | map(select(.in == "query"))[]
      | "  --\(.name) <\(.schema.type // "string")>\t\(.description // "")"
    ' 2>/dev/null | head -20)
  fi

  if [[ -n "$query_params" ]]; then
    echo "Query parameters:"
    echo "$query_params" | column -t -s $'\t'
    echo ""
  fi
}
