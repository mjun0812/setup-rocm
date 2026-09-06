# AGENTS.md

Project-local instructions for coding agents working in this repository.

## Language

Write everything that lands in this repository or on GitHub in English:

- Pull request titles and descriptions
- Commit messages (Conventional Commits)
- Issues and issue comments
- Code comments, log messages, and error messages
- Documentation (`README.md`, `docs/`)

Conversations with the maintainer may happen in another language, but the
artifacts above must be English.

## Development

The toolchain, verification commands, CI workflows, and release process are
described in [docs/dev.md](docs/dev.md). Run the full local verification before
committing:

```bash
vp check && tsc --noEmit && vp test run && vp pack
```

`dist/` is committed and must be rebuilt with `vp pack` whenever `src/` changes.
