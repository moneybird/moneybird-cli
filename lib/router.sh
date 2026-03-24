#!/usr/bin/env bash
# Command → API endpoint resolution
# Routes are resolved by looking up paths in the cached OpenAPI spec.
# CRUD actions use convention-based path patterns validated against the spec.
# Custom actions are fully spec-driven.

# Standard CRUD action → HTTP method lookup (bash 3.2 compatible)
crud_method() {
  case "$1" in
    list)       echo "GET" ;;
    get)        echo "GET" ;;
    create)     echo "POST" ;;
    update)     echo "PATCH" ;;
    delete)     echo "DELETE" ;;
    *)          return 1 ;;
  esac
}

# Validate that a value is safe for URL path interpolation
validate_path_segment() {
  local value="$1" label="$2"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if [[ "$value" =~ [^a-zA-Z0-9_.~:@-] ]]; then
    echo "Error: Invalid characters in ${label}: ${value}" >&2
    return 1
  fi
}

# Convert a spec path (with {format}, {administration_id}) to a real URL path
# Uses bash parameter substitution instead of sed to avoid injection
spec_path_to_url() {
  local spec_path="$1" api_prefix="$2" admin_id="$3" id="${4:-}" parent_id="${5:-}"
  local path="$spec_path"

  path="${path//\{format\}/.json}"
  path="${path//\{administration_id\}/$admin_id}"

  if [[ -n "$parent_id" ]]; then
    # Replace all known parent ID patterns
    path="${path//\{contact_id\}/$parent_id}"
    path="${path//\{sales_invoice_id\}/$parent_id}"
    path="${path//\{recurring_sales_invoice_id\}/$parent_id}"
    path="${path//\{external_sales_invoice_id\}/$parent_id}"
    path="${path//\{estimate_id\}/$parent_id}"
    path="${path//\{project_id\}/$parent_id}"
    path="${path//\{parent_id\}/$parent_id}"
  fi

  if [[ -n "$id" ]]; then
    path="${path//\{id\}/$id}"
    # Replace any remaining single path params (e.g. {invoice_id}, {reference})
    # Only if they look like a placeholder
    while [[ "$path" =~ \{[a-z_]+\} ]]; do
      local placeholder="${BASH_REMATCH[0]}"
      path="${path//$placeholder/$id}"
    done
  fi

  echo "${api_prefix}${path}"
}

# Find the spec path for a given resource pattern
# Returns the spec path key if found, empty otherwise
spec_find_path() {
  local spec_path="$1"
  spec_query --arg p "$spec_path" '.paths | has($p) | if . then $p else empty end' 2>/dev/null
}

route_resolve() {
  local resource="$1" action="$2" id="${3:-}"

  local admin_id=""
  admin_id=$(config_get_admin_id) || return 1
  validate_path_segment "$admin_id" "administration ID" || return 1
  validate_path_segment "$id" "ID" || return 1

  local host api_prefix
  host=$(config_get_host)
  api_prefix=$(spec_api_prefix)

  # Handle sub-resources (contacts:notes → contacts/{parent_id}/notes)
  local parent="" parent_id=""
  if [[ "$resource" == *":"* ]]; then
    parent="${resource%%:*}"
    resource="${resource#*:}"
    parent_id="$id"
    id="$OPT_CHILD_ID"
    validate_path_segment "$parent_id" "parent ID" || return 1
    validate_path_segment "$id" "child ID" || return 1
  fi

  # Replace dots with slashes for nested resources (documents.purchase_invoices)
  local resource_path
  resource_path=$(echo "$resource" | sed 's/\./\//g')

  # Try standard CRUD first
  local method
  if method=$(crud_method "$action"); then
    if [[ -n "$parent" ]]; then
      route_sub_resource "$method" "$host" "$api_prefix" "$admin_id" "$parent" "$parent_id" "$resource_path" "$action" "$id"
      return $?
    fi

    # Build spec path to validate against
    local spec_path
    case "$action" in
      list|create)
        spec_path="/{administration_id}/${resource_path}{format}" ;;
      get|update|delete)
        if [[ -z "$id" ]]; then
          echo "Error: ${action} requires an ID" >&2
          return 1
        fi
        spec_path="/{administration_id}/${resource_path}/{id}{format}" ;;
    esac

    # Validate endpoint exists in spec with the correct method
    local method_lower
    method_lower=$(echo "$method" | tr '[:upper:]' '[:lower:]')
    local exists
    exists=$(spec_query --arg p "$spec_path" --arg m "$method_lower" \
      '.paths[$p][$m] // empty' 2>/dev/null)
    if [[ -z "$exists" ]]; then
      echo "Error: '${resource} ${action}' is not a valid API endpoint" >&2
      echo "Run: moneybird-cli ${resource} --help" >&2
      return 1
    fi

    local path
    path=$(spec_path_to_url "$spec_path" "$api_prefix" "$admin_id" "$id")

    ROUTE_METHOD="$method"
    ROUTE_URL="${host}${path}"
    ROUTE_SPEC_PATH="$spec_path"
    return 0
  fi

  # Sync aliases: sync → GET synchronization, sync_fetch → POST synchronization
  case "$action" in
    sync)
      local sync_path="/{administration_id}/${resource_path}/synchronization{format}"
      local sync_url
      sync_url=$(spec_path_to_url "$sync_path" "$api_prefix" "$admin_id")
      ROUTE_METHOD="GET"
      ROUTE_URL="${host}${sync_url}"
      ROUTE_SPEC_PATH="$sync_path"
      return 0
      ;;
    sync_fetch)
      local sync_path="/{administration_id}/${resource_path}/synchronization{format}"
      local sync_url
      sync_url=$(spec_path_to_url "$sync_path" "$api_prefix" "$admin_id")
      ROUTE_METHOD="POST"
      ROUTE_URL="${host}${sync_url}"
      ROUTE_SPEC_PATH="$sync_path"
      return 0
      ;;
  esac

  # Custom action — fully spec-driven lookup
  route_custom_action "$host" "$api_prefix" "$admin_id" "$resource_path" "$action" "$id" "$parent" "$parent_id"
}

route_sub_resource() {
  local method="$1" host="$2" api_prefix="$3" admin_id="$4" parent="$5" parent_id="$6" child="$7" action="$8" child_id="${9:-}"

  if [[ -z "$parent_id" ]]; then
    echo "Error: Sub-resource requires a parent ID" >&2
    return 1
  fi

  # Search the spec for a matching sub-resource path
  local method_lower
  method_lower=$(echo "$method" | tr '[:upper:]' '[:lower:]')

  local found_path
  case "$action" in
    list|create)
      # Look for /{admin}/{parent}/{parent_id_param}/{child}{format}
      found_path=$(spec_query --arg parent "$parent" --arg child "$child" --arg m "$method_lower" '
        .paths | to_entries[]
        | select(.key | test("/" + $parent + "/\\{[a-z_]+\\}/" + $child + "\\{format\\}$"))
        | select(.value[$m] // null | . != null)
        | .key
      ' 2>/dev/null | head -1)
      ;;
    get|update|delete)
      if [[ -z "$child_id" ]]; then
        echo "Error: ${action} requires --child-id" >&2
        return 1
      fi
      found_path=$(spec_query --arg parent "$parent" --arg child "$child" --arg m "$method_lower" '
        .paths | to_entries[]
        | select(.key | test("/" + $parent + "/\\{[a-z_]+\\}/" + $child + "/\\{[a-z_]+\\}\\{format\\}$"))
        | select(.value[$m] // null | . != null)
        | .key
      ' 2>/dev/null | head -1)
      ;;
  esac

  if [[ -z "$found_path" ]]; then
    echo "Error: '${parent}:${child} ${action}' is not a valid API endpoint" >&2
    return 1
  fi

  local actual_path
  actual_path=$(spec_path_to_url "$found_path" "$api_prefix" "$admin_id" "$child_id" "$parent_id")

  ROUTE_METHOD="$method"
  ROUTE_URL="${host}${actual_path}"
  ROUTE_SPEC_PATH="$found_path"
}

route_custom_action() {
  local host="$1" api_prefix="$2" admin_id="$3" resource_path="$4" action="$5" id="${6:-}" parent="${7:-}" parent_id="${8:-}"

  # Build candidate spec paths (matching the spec format: /{administration_id}/...{format})
  local candidates
  if [[ -n "$parent" ]]; then
    local base="/{administration_id}/${parent}/{parent_id}/${resource_path}"
    candidates="${base}/{id}/${action}{format} ${base}/${action}{format}"
  else
    local base="/{administration_id}/${resource_path}"
    candidates="${base}/{id}/${action}{format} ${base}/${action}{format}"
  fi

  for candidate in $candidates; do
    local spec_result
    spec_result=$(spec_query --arg p "$candidate" '.paths[$p] // empty' 2>/dev/null)

    if [[ -n "$spec_result" && "$spec_result" != "null" ]]; then
      local method
      method=$(echo "$spec_result" | jq -r 'keys[] | select(test("^(get|post|put|patch|delete)$"))' | head -1)
      method=$(echo "$method" | tr '[:lower:]' '[:upper:]')

      local actual_path
      actual_path=$(spec_path_to_url "$candidate" "$api_prefix" "$admin_id" "$id" "$parent_id")

      ROUTE_METHOD="$method"
      ROUTE_URL="${host}${actual_path}"
      ROUTE_SPEC_PATH="$candidate"
      return 0
    fi
  done

  # Fallback: search spec paths containing resource with exact action segment
  # Matches both /action{format} and /action/{param}{format}
  local found
  found=$(spec_query --arg r "$resource_path" --arg a "$action" '
    .paths | to_entries[]
    | select(.key | test($r)) | select(.key | test("/" + $a + "(\\{format\\}|/)"))
    | .key as $p | (.value | keys[] | select(test("^(get|post|put|patch|delete)$"))) as $m
    | "\($p) \($m)"
  ' 2>/dev/null | head -1)

  if [[ -n "$found" ]]; then
    local found_path found_method
    found_path=$(echo "$found" | cut -d' ' -f1)
    found_method=$(echo "$found" | cut -d' ' -f2)

    local actual_path
    actual_path=$(spec_path_to_url "$found_path" "$api_prefix" "$admin_id" "$id" "$parent_id")

    ROUTE_METHOD=$(echo "$found_method" | tr '[:lower:]' '[:upper:]')
    ROUTE_URL="${host}${actual_path}"
    ROUTE_SPEC_PATH="$found_path"
    return 0
  fi

  echo "Error: Unknown action '${action}' for resource '${resource_path}'" >&2
  echo "Run: moneybird-cli ${resource_path} --help" >&2
  return 1
}
