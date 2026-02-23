#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PortlessMenu"
DEFAULT_BUILD_NUMBER="1"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release.sh <version> [options]

Examples:
  ./scripts/release.sh 0.1.1
  ./scripts/release.sh 0.2.0 --build-number 3 --notes-file /tmp/notes.md
  ./scripts/release.sh 0.2.0 --generate-notes

Options:
  --build-number <n>     CFBundleVersion build number (default: 1)
  --notes-file <path>    Markdown file for release notes
  --generate-notes       Let GitHub auto-generate release notes
  --allow-dirty          Continue even when working tree has changes
  --dry-run              Print planned commands without executing
  -h, --help             Show help
EOF
}

VERSION=""
BUILD_NUMBER="$DEFAULT_BUILD_NUMBER"
NOTES_FILE=""
GENERATE_NOTES=0
ALLOW_DIRTY=0
DRY_RUN=0

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

VERSION="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --generate-notes)
      GENERATE_NOTES=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be SemVer without the leading v (example: 0.1.0)." >&2
  exit 1
fi

if [[ "$BUILD_NUMBER" =~ [^0-9] ]]; then
  echo "Build number must be numeric." >&2
  exit 1
fi

if [[ "$GENERATE_NOTES" -eq 1 && -n "$NOTES_FILE" ]]; then
  echo "Use either --notes-file or --generate-notes, not both." >&2
  exit 1
fi

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "Notes file not found: $NOTES_FILE" >&2
  exit 1
fi

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

run_sh() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    bash -lc "$*"
  fi
}

cd "$ROOT"

TAG="v$VERSION"
ZIP_PATH="dist/${APP_NAME}-${TAG}-macos.zip"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Install GitHub CLI first." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  gh auth status >/dev/null
fi

if [[ "$ALLOW_DIRTY" -eq 0 ]]; then
  if [[ -n "$(git status --short)" ]]; then
    echo "Working tree is not clean. Commit/stash changes or use --allow-dirty." >&2
    exit 1
  fi
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag already exists locally: $TAG" >&2
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub release already exists for $TAG" >&2
  exit 1
fi

run_sh "APP_VERSION=$VERSION BUILD_NUMBER=$BUILD_NUMBER ./scripts/package_app.sh"
run ditto -c -k --sequesterRsrc --keepParent "dist/${APP_NAME}.app" "$ZIP_PATH"

run git tag -a "$TAG" -m "Release $TAG"
run git push origin main --follow-tags

if [[ "$GENERATE_NOTES" -eq 1 ]]; then
  run gh release create "$TAG" "$ZIP_PATH" --title "$TAG" --generate-notes
elif [[ -n "$NOTES_FILE" ]]; then
  run gh release create "$TAG" "$ZIP_PATH" --title "$TAG" --notes-file "$NOTES_FILE"
else
  run gh release create "$TAG" "$ZIP_PATH" --title "$TAG" --notes "Release $TAG"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete: $TAG"
else
  echo "Release complete: $TAG"
fi
