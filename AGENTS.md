# TurboBean

A fast Beancount implementation in Zig, providing a CLI, LSP server, and Web UI.

## Building & Testing

- **Zig version**: 0.15.2
- **Build**: `zig build`
- **Run**: `zig build run -- tree foo.bean`
- **Run all unit tests**: `zig build test`
- **Run a single file's tests**: `zig test src/<file>.zig`
- **Run golden tests**: `zig build golden`
- **Accept golden test output**: `zig build golden -Dgolden-accept=true`
- **VSCode extension tests**: `cd vscode && npm test`
- **Puppeteer tests**: `cd tests/puppeteer && bun test`

## Project Structure

- `src/` — Zig source code (lexer, parser, solver, LSP, HTTP server, CLI)
- `src/assets/` — Static web assets (JS, CSS, images)
- `src/templates/` — HTML templates for the web UI
- `src/lsp/` — LSP server implementation
- `src/server/` — HTTP server implementation
- `tests/golden/` — Golden tests (`.bean` input + expected output)
- `tests/puppeteer/` — Browser-based integration tests
- `vscode/` — VSCode extension (TypeScript)
- `build/` — Build helpers (e.g., `GoldenTest.zig`)

## Conventions

- Follow existing Zig code style and idioms.
- Source files use PascalCase for struct-types (`StringStore.zig`, `StackStack.zig`) and snake_case for modules (`lexer.zig`, `parser.zig`).
- Dependencies are managed via `build.zig.zon`; do not add dependencies without asking.
- Static assets can be embedded into the binary with `-Dembed-static`.
