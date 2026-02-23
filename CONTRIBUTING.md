# Contributing

## Scope

This repository is a thin macOS wrapper around the `portless` CLI.
Keep changes focused on wrapper UX, process management, and diagnostics.

## Local Development

```bash
swift build
swift run PortlessMenu
```

Package app bundle:

```bash
./scripts/package_app.sh
open ./dist/PortlessMenu.app
```

## Pull Request Guidelines

- Keep PRs small and focused.
- Include reproduction steps for bug fixes.
- Include screenshots for menu/UI changes.
- Do not vendor or copy Portless source code into this repo.
- Preserve attribution and licensing notes in `NOTICE` and `README.md`.

## License

By contributing, you agree your contributions are licensed under Apache-2.0.
