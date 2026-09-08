#!/bin/sh
# Links the defaults files into pandoc's data directory, so that
# `pandoc -d pandoc-pdf` works from any directory.
#
# Links rather than copies, so a git pull updates what pandoc uses. The filters
# stay in this repository: pandoc resolves ${.} in a defaults file through the
# symlink to the real file, and finds ../filters from there.
set -eu

repo=$(cd "$(dirname "$0")" && pwd)
data=${PANDOC_DATA_DIR:-$(pandoc --version | sed -n 's/^User data directory: //p')}

if [ -z "$data" ]; then
  echo "could not work out pandoc's data directory; set PANDOC_DATA_DIR" >&2
  exit 1
fi

mkdir -p "$data/defaults"
for file in "$repo"/defaults/*.yaml; do
  name=$(basename "$file")
  target="$data/defaults/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "leaving $target alone: it exists and is not a link" >&2
    continue
  fi
  ln -sf "$file" "$target"
  echo "linked $name"
done

echo
echo "Installed into $data/defaults"
echo "Try:  pandoc -d pandoc-pdf $repo/example/showcase.md -o showcase.pdf"
