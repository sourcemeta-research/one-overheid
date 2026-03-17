#!/usr/bin/env bash
set -euo pipefail

# Fetch all OpenAPI specifications from the Dutch government API register
# (developer.overheid.nl) into a local directory, organized by organisation.
#
# Environment variables:
#   API_KEY   (required)  API key for api.developer.overheid.nl
#   API_BASE  (optional)  Base URL, defaults to https://api.developer.overheid.nl/api-register/v1
#
# Usage:
#   API_KEY=xxx ./fetch.sh <output-directory>

usage() {
  echo "Usage: API_KEY=<key> $0 <output-directory>" >&2
  exit 1
}

if [ $# -ne 1 ]; then
  usage
fi

output_dir="$1"

if [ -z "${API_KEY:-}" ]; then
  echo "Error: API_KEY environment variable is not set" >&2
  usage
fi

api_base="${API_BASE:-https://api.developer.overheid.nl/api-register/v1}"
per_page=100

for cmd in curl jq; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Error: $cmd is required but not found in PATH" >&2
    exit 1
  fi
done

slug() {
  printf '%s' "$1" \
    | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null \
    | sed -E 's/([a-z])([A-Z])/\1-\2/g' \
    | sed -E 's/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-//; s/-$//'
}

# ── Fetch paginated API list ─────────────────────────────────────────────

echo "Fetching API list from $api_base ..."
page=1
total_pages=1
all_apis=$(mktemp)
echo '[]' > "$all_apis"

while [ "$page" -le "$total_pages" ]; do
  echo "  Page $page/$total_pages"
  headers_file=$(mktemp)
  body_file=$(mktemp)
  curl -s -f --retry 3 --retry-delay 2 \
    -D "$headers_file" \
    -o "$body_file" \
    -H "X-Api-Key: $API_KEY" \
    "$api_base/apis?page=$page&perPage=$per_page" 2>/dev/null

  tp=$(grep -i '^total-pages:' "$headers_file" | tr -d '\r' | awk '{print $2}')
  if [ -n "$tp" ]; then
    total_pages=$tp
  fi
  rm -f "$headers_file"

  merged=$(mktemp)
  jq -s '.[0] + .[1]' "$all_apis" "$body_file" > "$merged"
  mv "$merged" "$all_apis"
  rm -f "$body_file"
  page=$((page + 1))
done

api_count=$(jq length "$all_apis")
echo "Found $api_count APIs."
echo ""

# ── Download each OAS spec ───────────────────────────────────────────────

echo "Downloading OpenAPI specs to $output_dir ..."
mkdir -p "$output_dir"

fetched=0
cached=0
current=0

while IFS= read -r api; do
  current=$((current + 1))
  id=$(jq -r '.id' <<< "$api")
  title=$(jq -r '.title' <<< "$api")
  org_label=$(jq -r '.organisation.label // "unknown"' <<< "$api")

  org_dir=$(slug "$org_label")
  api_dir="$(slug "$title")/$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"

  mkdir -p "$output_dir/$org_dir/$api_dir"
  spec_path="$output_dir/$org_dir/$api_dir/openapi.json"

  if [ -f "$spec_path" ]; then
    cached=$((cached + 1))
    continue
  fi

  if ! curl -s -f --retry 3 --retry-delay 2 \
    -H "X-Api-Key: $API_KEY" \
    -o "$spec_path" \
    "$api_base/apis/$id/oas/3.1.json" < /dev/null 2>/dev/null; then
    rm -f "$spec_path"
    echo "Error: failed to fetch $title ($id) after retries" >&2
    exit 1
  fi
  echo "  ($current/$api_count) $title ($id)"
  fetched=$((fetched + 1))
done < <(jq -c '.[]' "$all_apis")

rm -f "$all_apis"

echo ""
echo "Done. Fetched: $fetched, cached: $cached"
