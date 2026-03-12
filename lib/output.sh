#!/usr/bin/env bash
# Response formatting (raw, pretty, table, fields)

output_format() {
  local response="$1"
  local mode="${OPT_OUTPUT:-pretty}"

  # Apply --fields filter: extract only specified fields from each object
  if [[ -n "$OPT_FIELDS" ]]; then
    local field_filter
    field_filter=$(output_build_fields_filter "$OPT_FIELDS") || return 1
    response=$(echo "$response" | jq "$field_filter")
  fi

  # Apply --select filter if provided
  if [[ -n "$OPT_SELECT" ]]; then
    response=$(echo "$response" | jq "$OPT_SELECT")
  fi

  case "$mode" in
    raw)
      echo "$response"
      ;;
    pretty)
      echo "$response" | jq '.'
      ;;
    table)
      output_table "$response"
      ;;
    *)
      echo "$response" | jq '.'
      ;;
  esac
}

# Build a jq filter from a comma-separated field list
# Validates field names to prevent jq injection
output_build_fields_filter() {
  local fields_csv="$1"
  local obj_parts=""
  local IFS=','

  for field in $fields_csv; do
    # Trim whitespace
    field=$(echo "$field" | sed 's/^ *//;s/ *$//')

    # Validate: only allow alphanumeric, underscore, dot (for nested access)
    if [[ ! "$field" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
      echo "Error: Invalid field name: ${field}" >&2
      echo "Field names may only contain letters, numbers, underscores, and dots." >&2
      return 1
    fi

    # If field contains a dot, use it as a path and alias to the last segment
    if [[ "$field" == *.* ]]; then
      local alias_name
      alias_name=$(echo "$field" | sed 's/.*\.//')
      obj_parts+="${alias_name}: .${field}, "
    else
      obj_parts+="${field}, "
    fi
  done
  # Remove trailing comma
  obj_parts=$(echo "$obj_parts" | sed 's/, $//')

  echo "if type == \"array\" then [.[] | {${obj_parts}}] else {${obj_parts}} end"
}

output_table() {
  local response="$1"

  local is_array
  is_array=$(echo "$response" | jq 'type == "array"')

  if [[ "$is_array" == "true" ]]; then
    local count
    count=$(echo "$response" | jq 'length')
    if (( count == 0 )); then
      echo "(empty)"
      return
    fi

    echo "$response" | jq -r '
      (.[0] | [to_entries[] | select(.value | type == "object" or type == "array" | not) | .key][0:8]) as $keys
      | ($keys | join("\t")),
        (.[] | [.[$keys[]]] | map(tostring) | join("\t"))
    ' 2>/dev/null | head -51 | column -t -s $'\t'
  else
    echo "$response" | jq -r '
      to_entries[]
      | select(.value | type == "object" or type == "array" | not)
      | "\(.key)\t\(.value)"
    ' | column -t -s $'\t'
  fi
}
