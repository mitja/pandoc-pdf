#!/bin/sh
# Downloads mermaid.min.js into vendor/, which the mermaid filter looks in
# first. Only needed if there is no copy near the documents you render: the
# filter also searches upwards from the file for a Hugo theme's copy or an
# npm install. See the README.
set -eu

version=${1:-11.12.0}
repo=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$repo/vendor"
url="https://cdn.jsdelivr.net/npm/mermaid@$version/dist/mermaid.min.js"

echo "downloading mermaid $version"
curl -fsSL "$url" -o "$repo/vendor/mermaid.min.js"
echo "wrote $repo/vendor/mermaid.min.js"
