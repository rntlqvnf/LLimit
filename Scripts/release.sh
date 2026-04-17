#!/usr/bin/env bash
# Tag and publish a GitHub Release with the universal LLMBar.app zipped.
#
# Requires `gh` authenticated against the repo and a clean working tree.
#
# Usage:
#   Scripts/release.sh 0.2.0
#   Scripts/release.sh 0.2.0 "Notes line one\nLine two"
set -euo pipefail

VERSION="${1:?version required, e.g. 0.2.0}"
NOTES="${2:-Release v${VERSION}}"
TAG="v${VERSION}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! git diff-index --quiet HEAD --; then
  echo "working tree has uncommitted changes — commit or stash before releasing" >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG already exists" >&2
  exit 1
fi

echo "==> packaging"
Scripts/package_app.sh "$VERSION" zip

ZIP="build/release/LLMBar-${VERSION}.zip"
if [ ! -f "$ZIP" ]; then
  echo "missing $ZIP after packaging" >&2
  exit 1
fi

echo "==> tagging $TAG"
git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "==> creating GitHub release"
gh release create "$TAG" "$ZIP" \
    --title "LLMBar $TAG" \
    --notes "$NOTES"

echo
echo "released $TAG"
echo "  asset: $ZIP"
