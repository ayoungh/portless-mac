# Release Cycle

This repo follows a lightweight, repeatable release cycle for the macOS app bundle.

## Cadence

- Patch releases: as needed for bug fixes.
- Minor releases: every 2 to 4 weeks, grouped by completed features.
- Emergency hotfix: immediate patch release from `main`.

## Versioning

- SemVer tags: `vMAJOR.MINOR.PATCH` (example: `v0.1.0`).
- `MAJOR`: breaking UX/behavior changes.
- `MINOR`: backward-compatible features.
- `PATCH`: bug fixes and non-breaking polish.

## Branch + Release Flow

1. Merge tested work into `main`.
2. Run local verification and package app.
3. Create annotated tag `vX.Y.Z` on `main`.
4. Push branch and tag.
5. Publish GitHub release with notes + zipped `.app` asset.

## Release Checklist

1. Verify working tree is clean:
   - `git status --short`
2. Build + package with release version metadata:
   - `APP_VERSION=X.Y.Z BUILD_NUMBER=N ./scripts/package_app.sh`
3. Smoke test packaged app:
   - Launch `dist/PortlessMenu.app`
   - Validate menu opens and proxy controls respond.
4. Zip distributable:
   - `ditto -c -k --sequesterRsrc --keepParent dist/PortlessMenu.app dist/PortlessMenu-vX.Y.Z-macos.zip`
5. Commit any last docs/version updates.
6. Create/push tag:
   - `git tag -a vX.Y.Z -m "Release vX.Y.Z"`
   - `git push origin main --follow-tags`
7. Publish release:
   - `gh release create vX.Y.Z dist/PortlessMenu-vX.Y.Z-macos.zip --title "vX.Y.Z" --notes-file <notes-file>`

## Automated Path

Use the release script to execute the full flow:

- `./scripts/release.sh X.Y.Z --generate-notes`
- Optional:
  - `--notes-file <path>`
  - `--build-number <n>`
  - `--dry-run`

## Notes Template

- Summary: one paragraph about what changed.
- Added: new features.
- Improved: enhancements/polish.
- Fixed: bug fixes.
- Upgrade notes: anything users should do after installing.
