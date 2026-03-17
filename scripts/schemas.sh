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

spec_count=$(find "$specs_dir" -name 'openapi.json' -type f | wc -l | tr -d ' ')
if [ "$spec_count" -eq 0 ]; then
  echo "Error: no openapi.json files found in $specs_dir" >&2
  exit 1
fi

echo "Splitting $spec_count specs from $specs_dir into $output_dir ..."

split_count=0

while IFS= read -r spec; do
  rel="${spec#"$specs_dir"/}"
  api_dir=$(dirname "$rel")
  outdir="$output_dir/$api_dir"

  tmpdir=$(mktemp -d)
  if ! npx -y @redocly/cli split "$spec" --outDir="$tmpdir" > /dev/null 2>&1; then
    echo "Error: failed to split $api_dir" >&2
    rm -rf "$tmpdir"
    exit 1
  fi

  mkdir -p "$outdir"
  if [ -d "$tmpdir/components/schemas" ]; then
    mv "$tmpdir/components/schemas"/* "$outdir/"
  fi
  rm -rf "$tmpdir"

  split_count=$((split_count + 1))
  schema_count=$(find "$outdir" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  ($split_count/$spec_count) $api_dir ($schema_count schemas)"
done < <(find "$specs_dir" -name 'openapi.json' -type f | sort)

echo ""
echo "Done. Split $split_count specs into $output_dir/"
