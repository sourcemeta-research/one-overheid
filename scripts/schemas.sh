#!/usr/bin/env bash
set -euo pipefail

# Split a directory of OpenAPI specifications into multi-file schemas.
#
# Usage:
#   ./schemas.sh <specs-directory> <output-directory>

usage() {
  echo "Usage: $0 <specs-directory> <output-directory>" >&2
  exit 1
}

if [ $# -ne 2 ]; then
  usage
fi

specs_dir="$1"
output_dir="$2"

if [ ! -d "$specs_dir" ]; then
  echo "Error: specs directory does not exist: $specs_dir" >&2
  exit 1
fi

if ! command -v npx > /dev/null 2>&1; then
  echo "Error: npx is required but not found in PATH" >&2
  exit 1
fi

if command -v nproc > /dev/null 2>&1; then
  jobs=$(nproc)
elif sysctl -n hw.ncpu > /dev/null 2>&1; then
  jobs=$(sysctl -n hw.ncpu)
else
  jobs=4
fi

# Build list of specs to process
specs=()
while IFS= read -r spec; do
  specs+=("$spec")
done < <(find "$specs_dir" -name 'openapi.json' -type f | sort)

total=${#specs[@]}
if [ "$total" -eq 0 ]; then
  echo "Error: no openapi.json files found in $specs_dir" >&2
  exit 1
fi

# Ensure redocly is cached before parallel runs
echo "Installing redocly ..."
npx -y @redocly/cli --version > /dev/null 2>&1

echo "Splitting $total specs ($jobs parallel) ..."

split_one() {
  local spec="$1" specs_dir="$2" output_dir="$3"
  local rel="${spec#"$specs_dir"/}"
  local api_dir
  api_dir=$(dirname "$rel")
  local outdir="$output_dir/$api_dir"
  local tmpdir
  tmpdir=$(mktemp -d)

  if ! npx -y @redocly/cli split "$spec" --outDir="$tmpdir" > /dev/null 2>&1; then
    rm -rf "$tmpdir"
    return 1
  fi

  mkdir -p "$outdir"
  if [ -d "$tmpdir/components/schemas" ]; then
    mv "$tmpdir/components/schemas"/* "$outdir/" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}

completed=0
for ((i = 0; i < total; i += jobs)); do
  batch_size=$((total - i))
  if [ "$batch_size" -gt "$jobs" ]; then
    batch_size=$jobs
  fi

  batch_labels=()
  for ((j = i; j < i + batch_size; j++)); do
    rel="${specs[j]#"$specs_dir"/}"
    api_dir=$(dirname "$rel")
    batch_labels+=("$api_dir")
    echo "  - $api_dir"
  done

  pids=()
  for ((j = i; j < i + batch_size; j++)); do
    split_one "${specs[j]}" "$specs_dir" "$output_dir" &
    pids+=($!)
  done

  for k in "${!pids[@]}"; do
    if ! wait "${pids[k]}"; then
      echo "Error: failed to split ${batch_labels[k]}" >&2
      exit 1
    fi
  done

  completed=$((completed + batch_size))
  echo "  ($completed/$total)"
done

# Work around case-insensitive collision that redocly split doesn't handle.
# The logius/api-overheidsorganisaties spec defines both "Wijzigingsgebeurtenis"
# and "wijzigingsgebeurtenis" as separate schemas. On macOS (case-insensitive FS)
# one silently overwrites the other, but on Linux both files exist and Sourcemeta
# ONE cannot register them as they map to the same lowercase URL.
rm -f "$output_dir"/logius/api-overheidsorganisaties/*/wijzigingsgebeurtenis.json

# Fix $ref paths that redocly split doesn't rewrite.
# These are nested refs like #/components/schemas/Foo/properties/bar
# that should be either self-refs (#/properties/bar) or cross-refs
# (./Foo.json#/properties/bar).
echo "Fixing unresolved \$ref paths ..."
grep -rl '"#/components/schemas/' "$output_dir" 2>/dev/null | while IFS= read -r file; do
  base=$(basename "$file" .json)
  # Self-references: strip #/components/schemas/BASENAME prefix
  sed -i.bak "s|\"#/components/schemas/${base}/|\"#/|g" "$file" && rm -f "$file.bak"
  # Cross-references: rewrite to relative file path
  sed -i.bak -E 's|"#/components/schemas/([^/"]+)/|"./\1.json#/|g' "$file" && rm -f "$file.bak"
done

echo ""
echo "Done. Split $total specs into $output_dir/"
