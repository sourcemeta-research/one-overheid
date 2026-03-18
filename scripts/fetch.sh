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

if command -v nproc > /dev/null 2>&1; then
  jobs=$(nproc)
elif sysctl -n hw.ncpu > /dev/null 2>&1; then
  jobs=$(sysctl -n hw.ncpu)
else
  jobs=4
fi

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

# ── Build download manifest ──────────────────────────────────────────────

echo "Preparing downloads ..."
mkdir -p "$output_dir"

urls=()
paths=()
labels=()
cached=0

while IFS= read -r api; do
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

  urls+=("$api_base/apis/$id/oas/3.0.json")
  paths+=("$spec_path")
  labels+=("$title ($id)")
done < <(jq -c '.[]' "$all_apis")

rm -f "$all_apis"
total=${#urls[@]}

if [ "$total" -eq 0 ]; then
  echo "Nothing to fetch (cached: $cached)."
  exit 0
fi

# ── Download in batches ──────────────────────────────────────────────────

echo "Downloading $total specs ($jobs parallel, cached: $cached) ..."

completed=0
for ((i = 0; i < total; i += jobs)); do
  batch_size=$((total - i))
  if [ "$batch_size" -gt "$jobs" ]; then
    batch_size=$jobs
  fi

  for ((j = i; j < i + batch_size; j++)); do
    echo "  - ${labels[j]}"
  done

  pids=()
  for ((j = i; j < i + batch_size; j++)); do
    curl -s -f --retry 3 --retry-delay 2 \
      -H "X-Api-Key: $API_KEY" \
      -o "${paths[j]}" \
      "${urls[j]}" 2>/dev/null &
    pids+=($!)
  done

  for k in "${!pids[@]}"; do
    if ! wait "${pids[k]}"; then
      idx=$((i + k))
      rm -f "${paths[idx]}"
      echo "Error: failed to fetch ${labels[idx]} after retries" >&2
      exit 1
    fi
  done

  completed=$((completed + batch_size))
  echo "  ($completed/$total)"
done

echo ""
echo "Done. Fetched: $total, cached: $cached"
