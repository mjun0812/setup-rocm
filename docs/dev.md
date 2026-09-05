# Development Guide

## Prerequisites

- Node.js >= 24.0.0
- Vite+ (`vp`) installed globally

## Setup

Install dependencies:

```bash
vp install
```

## Development Workflow

### 1. Create a Feature Branch

Always work on a feature branch, not directly on `main`:

```bash
git checkout -b <your-branch-name>
```

Branch naming convention (recommended):

- `feat/<feature-name>` - for new features
- `fix/<bug-name>` - for bug fixes
- `docs/<doc-name>` - for documentation
- `refactor/<refactor-name>` - for refactoring

### 2. Make Changes

After making code changes, run the following commands locally:

```bash
# Format code
vp fmt src test

# Lint and apply autofixes
vp lint src test --fix

# Type check
tsc --noEmit

# Run format, lint, and type-aware checks together
vp check

# Run tests
vp test run

# Build
vp pack

# Or run the full local verification flow
vp check && tsc --noEmit && vp test run && vp pack
```

**Important**: Always commit the `dist/` directory after building. The built files must be committed because GitHub Actions runs the action from the repository directly.

### 3. Commit Changes

Follow Conventional Commits format:

```bash
git add .
git commit -m "feat: add new feature"
```

Commit message format:

- `feat:` - new feature
- `fix:` - bug fix
- `docs:` - documentation changes
- `refactor:` - code refactoring
- `test:` - test changes
- `ci:` - CI/CD changes

### 4. Push and Create PR

```bash
git push origin <your-branch-name>
```

Then create a PR on GitHub targeting the `main` branch.

## CI/CD

### CI Workflow (`.github/workflows/ci.yml`)

Runs on:

- Pull requests to `main`
- Pushes to `main`

Jobs:

1. **Format-Lint-TypeCheck**
   - Runs `vp check` for formatting, lint, and type-aware checks
   - Runs unit tests with `vp test run`

2. **Test**
   - Tests the action on a small matrix (ubuntu-latest / windows-latest, method `auto`) via the reusable `_test.yml` workflow
   - Tests with the `latest` ROCm version

3. **ci-check**
   - Final status check that ensures all jobs passed

### Full Test Workflow (`.github/workflows/full-test.yml`)

Runs on:

- Manual trigger (`workflow_dispatch`): a single `os` / `version` / `method` combination, plus `expect-failure` to verify that an unresolvable version fails the action step as expected
- Weekly schedule (Sunday at 3 AM UTC): the full matrix below

Weekly matrix:

- OS: ubuntu-22.04, ubuntu-24.04, windows-2022, windows-2025
- Method: package-manager, runfile, auto (Windows only runs `auto`, since `method` is ignored there)
- ROCm version: latest

Both triggers call the reusable `.github/workflows/_test.yml` workflow, which installs ROCm via the local action and cross-compiles a minimal HIP kernel (`hipcc --offload-arch=gfx942 -c`) to verify the toolchain without a GPU.

### Container Test Workflow (`.github/workflows/container-test.yml`)

Runs on:

- Manual trigger (`workflow_dispatch`)

Tests one container environment per dispatch (`container` input, via the reusable `_test-container.yml` workflow), e.g.:

- almalinux:9
- quay.io/pypa/manylinux_2_28_x86_64

### CI Test Harness (`test/ci/*.sh`)

Since `full-test.yml` / `container-test.yml` are `workflow_dispatch`-only, verifying an Acceptance Criterion against a real GitHub-hosted runner is scripted instead of run by hand:

1. **Dispatch**: `gh workflow run <workflow>.yml --ref <branch> -f os=... -f version=... -f method=...` starts a run.
2. **Run ID cache**: the dispatched run's `databaseId` is looked up via `gh run list` and cached under `test/ci/.state/run-*.id`, so re-running the same script reuses the same run instead of dispatching a new one every time.
3. **Verify**: once the run completes, `gh run view --json conclusion` and `gh run view --log` are checked against the expected outputs, environment variables, and log messages.

Run a script directly for its Acceptance Criterion, e.g. `test/ci/run_full_test.sh ac1` or `test/ci/run_failure_test.sh ac2`; see the comment header of each script for its exact contract and usage.

## Release Process

### 1. Ensure `dist/` is Up-to-Date

Before creating a release, make sure the `dist/` directory is built and committed:

```bash
vp pack
git add dist/
git commit -m "build: update dist for release"
git push
```

### 2. Create and Push a Tag

Tags must follow the format `v<major>.<minor>.<patch>` (Semantic Versioning):

```bash
git tag v1.2.3
git push origin v1.2.3
```

### 3. Release Workflow Triggers

When a tag matching `v[0-9]+.[0-9]+.[0-9]+` is pushed, the release workflow (`.github/workflows/release.yml`) automatically:

1. Checks out the code
2. Sets up `vp` and installs dependencies
3. Builds the project
4. Verifies that `dist/` is up-to-date (fails if uncommitted changes exist)
5. Creates a GitHub release with auto-generated release notes
6. Updates the major version tag (e.g., `v1`) to point to the new release

Example:

- Push `v1.2.3` → Creates release and updates `v1` tag to point to `v1.2.3`
- This allows users to reference `mjun0812/setup-rocm@v1` to always get the latest v1.x.x

## Testing Locally

### Unit Tests

```bash
# Run tests once
vp test run

# Run tests in watch mode
vp test

# Run tests with coverage
vp test run --coverage
```

### Integration Test

To test the action locally, you can create a test workflow in `.github/workflows/` and trigger it manually, or use [act](https://github.com/nektos/act) to run GitHub Actions locally.

## Project Structure

```
.
├── src/              # TypeScript source code
├── dist/             # Compiled JavaScript (must be committed)
├── .github/
│   └── workflows/    # CI/CD workflows
├── docs/             # Documentation
├── test/
│   └── ci/           # CI test harness scripts (see above)
├── package.json      # Project metadata and scripts
├── action.yml        # GitHub Action definition
└── tsconfig.json     # TypeScript configuration
```

## Notes

- The `dist/` directory must always be committed after changes
- The release workflow will fail if `dist/` is not up-to-date
- Major version tags (e.g., `v1`) are automatically updated on release
- CI runs automatically on all PRs to ensure code quality
