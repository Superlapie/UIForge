# Contributing to UIForge

UIForge is a **community-built, AI-first** tool. Pull requests that improve reliability, authoring ergonomics, documentation, visual quality, or machine-facing workflows are welcome.

## If you are an AI agent

Use the CLI as the stable interface:

- discover capabilities before making assumptions;
- edit documents through stable IDs rather than tree indexes;
- preserve the `*.ui.json` source as canonical and regenerate scenes from it;
- keep machine output compact, deterministic, and valid JSON.

## Licensing and contributions

By contributing to this repository, you agree that:

1. Your contributions are licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).
2. You grant Superlapie the right to use, sublicense, and commercially license your contributions as part of UIForge under separate commercial license terms.

You keep copyright in your contributions, but you may not contribute code or assets you do not have the right to license under these terms. Commercial use of UIForge itself requires a separate commercial license; see [COMMERCIAL.md](COMMERCIAL.md).

## Before opening a PR

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the relevant authoring guide.
2. Run `./scripts/test` locally.
3. Keep changes focused and update the JSON source, schema, and docs together when a contract changes.
4. Do not hand-edit generated `.tscn` output when the source document can be changed instead.
5. Do not add secrets, credentials, or proprietary assets.

## Good first contributions

- documentation fixes and clearer diagnostics;
- new atlas examples or reusable components;
- CLI validation and machine-workflow improvements;
- editor usability and accessibility improvements;
- regression tests for stable-ID editing and scene compilation.

## Pull request checklist

- [ ] `./scripts/test` passes, or the PR explains why a smaller check is sufficient.
- [ ] JSON output and schema behavior remain compatible, or the change is documented.
- [ ] Generated scenes were rebuilt from their source documents.
- [ ] No secrets, credentials, or proprietary assets were added.

## Code of conduct

Be direct, be kind, and optimize for maintainability. Disagreement is fine; harassment is not.

## Questions

Open a [Discussion](https://github.com/Superlapie/UIForge/discussions) for design questions or integration help. Use [Issues](https://github.com/Superlapie/UIForge/issues) for reproducible bugs and focused feature requests.
