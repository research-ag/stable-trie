---
name: motoko-mops-package-maintenance
description: Automate maintaining a Motoko mops package — upgrade dependencies, fix compiler warnings, run tests and benchmarks, fix breakages, update CHANGELOG, review doc strings and docs, run the formatter, and prepare a patch release on a new git branch.
---

# Mops Package Maintenance

## What This Is

A step-by-step playbook for an AI agent to fully maintain a Motoko package
published on [MOPS](https://mops.one). The workflow upgrades all
dependencies, validates the package still works, polishes documentation,
formats the code, ensures a robust CI workflow, and prepares a versioned
release branch — all in one automated pass.

## When to Use

- Periodic dependency-bump maintenance runs.
- Before cutting a new release of a MOPS package.
- When the user asks to "update deps", "maintain the package", or
  "prepare a release".

## Prerequisites

The following tools must be available on the machine:

- `mops` CLI (install: `npm i -g ic-mops`)
- `moc` (Motoko compiler; usually ships with `dfx`, but can be standalone)
- `dfx` (DFINITY SDK; optional if `moc` and `mops` are otherwise available)
- `node` / `npm`
- `git`
- `prettier` and `prettier-plugin-motoko` (run via `npx -y`)

## Workflow

Work through every step in order. Do NOT skip steps. If a step fails,
fix the issue before moving on.

### Step 0 — Create a maintenance branch

```bash
git checkout -b chore/dependency-bump-$(date +%Y-%m-%d)
```

All subsequent changes are committed on this branch.

### Step 1 — Verify Package Quality on MOPS

1. Open `mops.toml` and check if it has a `[package]` section. If it only has `[canister]` sections or neither, this is not a published package; skip to Step 2.
2. If it is a package, find the `name` field under `[package]`.
3. Go to `https://mops.one/<name>` (replace `<name>` with the package name).
4. Locate the **Package Quality** section on the page.
5. Review the status of each quality metric (e.g., Documentation, License, Repository, Tests, Benchmarks).
6. If any metric is not **"yes"** or **"100%"**, attempt to fix it:
    - **Documentation < 95%**: You MUST run the `motoko-doc-strings` skill to improve doc-string coverage.
    - **Documentation >= 95%**: Skip documentation improvements. Do NOT run the `motoko-doc-strings` skill, and skip Step 7 and Step 8.
    - **Missing License/Repository**: Ensure these fields are correctly set in `mops.toml` `[package]` section.
    - **Tests/Benchmarks failing/missing**: These will be addressed in Step 4 and Step 5. You MUST also ensure a proper CI workflow is in place by following Step 9c (especially if the `motoko-github-ci-workflow` skill is installed).
7. If a quality issue cannot be fixed automatically, raise a warning to the user.

### Step 2 — Discover outdated dependencies

Use the `mops outdated` command to identify which dependencies have newer versions available:

```bash
mops outdated
```

If `mops outdated` fails or is unavailable, you can manually check individual packages:

```bash
mops search <package-name>
```

Compare the installed versions in `mops.toml` with the latest available versions. Record which packages need upgrading.

**Important:** `moc` version in `[toolchain]` should usually be upgraded to the latest version to ensure a modern build environment. `moc` in `[requirements]` should be set to the **absolute minimum** version required for compatibility with upgraded dependencies (identified through exhaustive, non-skipping iterative testing), rather than blindly aligned with the latest toolchain version or dependency requirements. This avoids unnecessarily restricting consumers to the latest compiler.

### Step 3 — Upgrade dependencies in `mops.toml`

For each outdated dependency in `[dependencies]` and `[dev-dependencies]`, update the version string in `mops.toml`
to the latest version.

**Upgrading `moc` and `[requirements]`:**
- **Check latest `moc`**:
  ```bash
  mops toolchain update moc
  ```
- `[toolchain] moc`: Upgrade this to the latest version. (Note: This is for development only and should NOT be listed in the CHANGELOG).
- `[requirements]`: Determine the minimum `moc` version required for the package to function correctly.
    1. **Initial version:**
       - Identify the maximum `moc` version required by all **regular dependencies** (those in `[dependencies]`), EXCLUDING the `core` package.
       - To do this:
         1. Take exactly the dependencies from your root `mops.toml` `[dependencies]` section (excluding `core`).
         2. Parse each dependency name and version.
         3. Look at exactly the file `.mops/<name>@<version>/mops.toml`.
         4. Extract the `moc` version from the `[requirements]` section (skip if no such section).
         5. Take the maximum over all of them. This is your **Initial version**.
       - If this calculated version is lower than the `moc` version currently set in your root `mops.toml` `[requirements]` section, use your current version instead.
    2. **Check `core` requirement:** Identify the exact version of the `core` package from the `[dependencies]` section of your root `mops.toml`. After running `mops install`, look at the `moc` version in the `[requirements]` section of `.mops/core@<version>/mops.toml` (where `<version>` is the exact version of core under [dependency] section in our main mops.toml).
    3. **Iterative Validation (if `core` requirement is higher):**
       If the `core`'s `moc` requirement is greater than your initial version, you MUST find the minimum version between them that works.
        - Identify all intermediate `moc` versions from your initial version to the `core`'s required version (inclusive).
        - For each version `X` in this range (starting from the lowest):
            - **CRITICAL:** You MUST test EVERY version in the range sequentially. Do NOT skip any versions (e.g., if 1.0.0 fails, do NOT jump to 1.4.0; you MUST test 1.1.0, 1.2.0, 1.3.0, etc.).
            1. Temporarily set `[toolchain] moc = "X"` in `mops.toml`.
            2. Run: `mops test` (if tests exist).
            3. Run: `mops bench` (if benchmarks exist).
            4. Build examples (if they exist). Build **Motoko canisters only** (ignore asset or Rust canisters). To build examples:
               ```bash
               # Detect and build examples/example
               EXAMPLES_DIR=""
               if [ -d "examples" ]; then EXAMPLES_DIR="examples"; elif [ -d "example" ]; then EXAMPLES_DIR="example"; fi
               if [ -n "$EXAMPLES_DIR" ]; then
                 cd "$EXAMPLES_DIR"
                 mops install
                 # Build Motoko canisters only
                 if [ -f "icp.yaml" ] && command -v icp >/dev/null; then icp build --all; elif [ -f "dfx.json" ]; then dfx build; fi
                 cd ..
               fi
               ```
            5. If ALL steps pass without errors, set `[requirements] moc = "X"` in `mops.toml` and STOP. This is your new requirement.
    4. **Failure Handling:** If something fails even on the highest version (the one required by `core`), revert `[requirements] moc` to your initial version and print a warning to the user that you failed to find a `moc` version that fits.
    5. **Final sync:** Ensure `[toolchain] moc` is set back to the latest version after finding the requirement.

Then install (this will also download any missing dependencies to `.mops`):

```bash
mops install
```

Verify that `mops install` completed successfully without resolution errors (e.g., version conflicts or missing packages) and that `mops.lock` was updated correctly to reflect the changes.

#### Step 3a — Sync nested `mops.toml` files (examples/example, sub-projects)

Search the repository for any additional `mops.toml` files outside the
root (commonly under `examples/`, `example/`, `bench/`, or sub-canister folders):

```bash
find . -name mops.toml -not -path "./node_modules/*" -not -path "./.mops/*"
```

For **every** nested `mops.toml`, ensure:

- Third-party `[dependencies]` versions **usually** match the root. Examples may occasionally have extra dependencies, but common ones should be in sync.
- `[toolchain] moc` matches the root, and the version exists in the
  fork used by the CI `setup-mops` action.
- The package being maintained references itself by its **actual package name** with a **relative local path** to the directory containing the root `mops.toml` (e.g. `self-package-name = "../"` for `examples/mops.toml` or `example/mops.toml`). It should also include a comment with the latest version for easy manual replacement by consumers.
- **Replace relative imports in source code:** Look into the source code of examples and sub-projects (e.g. `examples/**/*.mo` or `example/**/*.mo`). Identify imports that use relative paths to the root package's source (e.g. `import "../../src/Main"` or `import "../src"`). Replace these with the package name (e.g. `import "mo:self-package-name/Main"` or `import "mo:self-package-name"`). This ensures the examples are ready for copy-pasting by users and work immediately in a new project.

Example `examples/mops.toml` (or `example/mops.toml`):

```toml
[dependencies]
core = "2.5.0"
self-package-name = "../"
# Replace with:
# self-package-name = "0.0.3"

[toolchain]
moc = "1.6.0"
```

#### Step 3b — Audit repo hygiene files

- **`.gitignore`**: If it does NOT exist, create it. Ensure it contains the following recommended entries. If it exists, add any missing entries:
  ```text
  .mops/
  .icp/
  mops.lock
  node_modules/
  package.json
  package-lock.json
  .dfx/
  build/
  skills-lock.json
  .agents
  ```
  *(Note: Personal files like `.idea`, `.vscode`, `.claude`, `.junie`, `.copilot`, `.tmp`, `*.swp`, and `.DS_Store` should NOT be added here; they should be managed in the developer's global ignore file, e.g., `~/.gitignore_global`.)*
- **`package-lock.json`**: If it does NOT exist, do NOT introduce it.
- **`package.json`**: If it exists, ensure the `license` field matches `mops.toml` `[package] license`. If it does NOT exist, do NOT introduce it (it may be created by `npm`, if so, do NOT commit it).
- **`mops.toml` `files` field**: If `mops.toml` contains a `files` field under `[package]`, it acts as an allow-list for the `mops publish` command.
    - **CRITICAL:** Do NOT modify the `files` field. Leave it exactly as it is. Trying to be smart about it can lead to including unintended files (like tests or benchmarks) or excluding necessary ones. Let the user edit this line manually if needed.
    - **Check & Report:** Report to the user which files/patterns are currently included in the `files` field. Warn the user if something looks off (e.g., if an `examples/` directory exists but is NOT included).
    - **Allowed Extensions:** Note that `mops publish` only supports the following extensions: `.mo`, `.did`, `.md`, `.toml`. If the `files` field includes other extensions (e.g., `.json`), warn the user that they might cause errors during publish.

### Step 3c — Fix compiler warnings

Run the `fix-compiler-warnings` skill as a sub-task.

**CRITICAL RULE:** Do NOT modify any code unless an explicit warning or error was produced by the compiler. Never apply "improvements" or "fixes" for perceived issues that the compiler does not actually complain about.

1. Run the build check to capture warnings for **Motoko canisters** (ignore asset or Rust canisters). Choose the command based on the project type:

   #### For DFX projects:
   ```bash
   dfx build --check 2>&1 | tee /tmp/dfx_build_output.txt
   ```

   #### For MOPS packages:
   ```bash
   find src -type f -name "*.mo" -print0 | xargs -0 -n1 $(mops toolchain bin moc) --check $(mops sources) 2>&1 | tee /tmp/moc_check_output.txt
   ```

   #### For ICP-CLI projects:
   ```bash
   icp build 2>&1 | tee /tmp/icp_build_output.txt
   ```

2. If warnings/errors are found:
    - Fix one type of error at a time.
    - Re-run the check to verify the fix.
    - Run `mops test` or `mops bench` if relevant to ensure no regressions.
    - Repeat until all warnings are resolved.

### Step 4 — Run tests

```bash
mops test
```

If tests fail:

1. Read the error output carefully.
2. Identify whether the failure is caused by an API change in an upgraded
   dependency.
3. Fix the source code to accommodate the new API.
4. Re-run `mops test` until all tests pass.

If a fix requires non-trivial changes (renamed functions, changed
signatures, new semantics), note each change — you will need it for the
CHANGELOG.

### Step 5 — Run benchmarks

```bash
mops bench
```

If benchmarks fail to compile or run:

1. Apply the same kind of fixes as in Step 4.
2. Re-run until benchmarks complete.

If benchmarks show a significant regression, note it for the CHANGELOG
but do not block the release unless the user explicitly asks.

### Step 6 — Update the CHANGELOG

Open (or create) `CHANGELOG.md`. Add a new section at the top for the
upcoming version (you will finalize the version number in Step 10).

Required bullet points:

- **Dependencies bumped** — list every dependency from the `[dependencies]` section that was upgraded and its old → new version.
    - **CRITICAL:** Do NOT include `[toolchain]` or `[dev-dependencies]` bumps here; users only care about `[requirements]` or actual library dependencies. Even if you upgraded `[toolchain] moc` or a dev-dependency in Step 3, do NOT list it in the CHANGELOG.
- **Breaking / notable changes** — if any source code had to change to
  accommodate new APIs, describe what changed and why.
- **Bug fixes** — if any bugs were discovered and fixed during the
  process.

Use the existing CHANGELOG style if one exists. If no CHANGELOG exists,
create one with this format:

```markdown
# Changelog

## Unreleased

### Changed

- Updated `core` from `2.0.0` to `2.5.0`.
- Bumped `bench` from `1.0.0` to `2.0.1`.
- Updated `[requirements] moc` from `1.2.0` to `1.3.0` (only include if requirements were actually changed).

### Fixed

- Adapted `<function>` to new `<dep>` API (renamed `old` → `new`).
```

### Step 7 — Review and improve doc strings

**Note:** If you determined in Step 1 that the MOPS Documentation quality is >= 95%, SKIP this step entirely.

Scan every `.mo` file under `src/` for public declarations. For each
public `type`, `func`, `actor`, `actor class`, `let`, and `module`:
1. Check that a `///` doc string exists directly above the declaration.
2. Read the doc string from a first-time user's perspective:
    - Is the purpose clear?
    - Are argument types/units/constraints documented?
    - Is trap / error behavior described?
    - Are examples present for non-trivial functions?
3. Improve or add doc strings where they are missing or unclear.

If a `motoko-doc-strings` skill is installed, follow its full checklist.

### Step 8 — Review README and other Markdown files

**Note:** If you determined in Step 1 that the MOPS Documentation quality is >= 95%, SKIP this step entirely.

Read `README.md` and every other `.md` file in the repository. For each:

1. Check factual accuracy (version numbers, API names, examples).
2. Fix outdated information.
3. Improve clarity, grammar, and completeness where possible.
4. Add any new sections that would help users (e.g., new API surface
   from upgraded deps).
5. **Format Instruction:** Ensure `README.md` contains instructions on how to format the code (e.g., `npx -y prettier --plugin prettier-plugin-motoko --write '**/*.{mo,json,md}'`). Add it to a "Development" or "Formatting" section if missing.

### Step 9 — Formatting

Maintain a consistent code style by formatting the repository with Prettier and ensuring CI enforces this.

#### 9a — Check for Prettier Configuration

Check if a `.prettierrc` file exists at the repo root.

1. If it does NOT exist, create one with the following content.
2. If it DOES exist but is "simple" (e.g., only contains `tabWidth`), replace it with the following content.

Recommended `.prettierrc`:

```json
{
  "plugins": ["prettier-plugin-motoko"],
  "bracketSpacing": true,
  "printWidth": 80,
  "semi": true,
  "tabWidth": 2,
  "trailingComma": "es5",
  "useTabs": false
}
```

#### 9b — Format the code

Run Prettier to format all supported files:

```bash
npx -y prettier --plugin prettier-plugin-motoko --write '**/*.{mo,json,md}'
```

#### 9c — Verify or Add CI Workflow

Search for GitHub Actions workflows (e.g., `.github/workflows/*.yml`).

**If the `motoko-github-ci-workflow` skill is installed:**
Follow its instructions to create or update a comprehensive CI workflow (usually `.github/workflows/ci.yml`) that includes tests, benchmarks, and formatting checks.

**If the `motoko-github-ci-workflow` skill is NOT installed:**
Create or update a consolidated GitHub Actions workflow (usually `.github/workflows/ci.yml`) that includes both code formatting checks and tests.

If no CI exists, create `.github/workflows/ci.yml` with the following content:

```yaml
name: CI

on:
  push:
    branches: [main, master]
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  test:
    name: Tests and Benchmarks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: latest
      - uses: caffeinelabs/setup-mops@v1
      - run: |
          mops toolchain init
          mops install
      - run: mops test   # Omit if no tests exist
      - run: mops bench --replica pocket-ic  # Omit if no benchmarks exist

  fmt:
    name: Formatting Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: latest
      - name: Prettier Check
        run: |
          npm install prettier prettier-plugin-motoko --no-save
          npx -y prettier --plugin prettier-plugin-motoko --check '**/*.{mo,json,md}'
```

**CRITICAL:** Do NOT add a "Compiler Check" or `moc --check` step to the CI. While the agent MUST run this check locally during maintenance (Step 3c), it should NOT be part of the automated CI suite.

### Step 10 — Bump the version

1. Open root `mops.toml` and increment the **patch** version. For example, if the
current version is `1.2.3`, change it to `1.2.4`.

```toml
[package]
name = "my-package"
version = "1.2.4"   # was 1.2.3
```

2. Update the CHANGELOG `Unreleased` header to the new version number:

```markdown
## 1.2.4
```

3. Update self-dependency comments in all nested `mops.toml` files (identified in Step 3a) to match the new version:

```toml
# In examples/mops.toml (or example/mops.toml):
self-package-name = "../"
# Replace with:
# self-package-name = "1.2.4"
```

### Step 11 — Commit and push

Stage all changes. **CRITICAL:** If `package.json` or `package-lock.json` did not exist at the start of the task, do NOT commit them if they were created during the process (e.g., by `npm install`).

```bash
# Stage all changes to tracked files (including deletions)
git add -u
# Stage intentional new files created by the maintenance task
git add .gitignore CHANGELOG.md .prettierrc .github/workflows/*.yml 2>/dev/null || true
# Verify staged changes
git status
```

Verify `git status` shows only intended staged files, then commit:

```bash
git commit -m "chore: bump dependencies and prepare v<NEW_VERSION>"
```

Inform the user that the branch is ready for review and/or pushing:

```text
Branch: chore/dependency-bump-YYYY-MM-DD
Ready for review. Run `git push -u origin HEAD` to push.
```

## Common Pitfalls

1. **Don't blindly bump major versions.** If a dependency from `mops.one` has a new major version number (e.g., `1.x` to `2.x`), you **MUST** read the CHANGELOG of that package. The API likely changed. If the migration is non-trivial, flag it to the user.

2. **`[requirements] moc` version.** While you shouldn't *blindly* bump it to the latest version, you must ensure it is at least the highest version required by any of your **regular dependencies** (EXCLUDING `core`). Audit these by looking at exactly the `.mops/<name>@<version>/mops.toml` file for each dependency in your `[dependencies]` section. For the `core` package specifically, you should test the package against a range of `moc` versions (from your initial calculated version up to the requirement found in `.mops/core@<version>/mops.toml`) to find the **minimum** version that works. **CRITICAL:** You MUST perform an exhaustive search by testing EVERY version in the range sequentially without skipping. Even if a dependency like `core` specifies a high version, it might still work with lower versions; your goal is to find the absolute minimum. If the package passes all checks with a version lower than what `core` requires, prefer the lower version to maximize compatibility for consumers. Revert and warn if no working version is found within the expected range.

3. **Lock file drift.** Always run `mops install` after editing
   `mops.toml` so the lock file stays in sync. Never commit a hand-edited
   lock file.

4. **Missing recommended entries in `.gitignore`.** Always ensure that
   `.gitignore` is present and contains the recommended entries (see Step 3b),
   especially `node_modules/`, `package.json`, `package-lock.json`, `.mops/`, `.icp/`, and `mops.lock`.

5. **Mismanaging the `mops.toml` `files` field.** Never attempt to automatically modify the `files` field in `mops.toml`. Report its contents to the user and warn about missing patterns or unsupported extensions (`.mo`, `.did`, `.md`, `.toml` only).

6. **CHANGELOG ordering.** Newest version goes at the top. Don't append
   to the bottom.

7. **Respect the documentation quality threshold.** If the MOPS documentation quality is >= 95%, do NOT perform a full doc-string review or README update. This avoids unnecessary noise and minor changes that don't significantly improve the package quality when it's already at a high standard. Only perform a full scan if quality is < 95% or if the package is not yet published.

8. **Adding Compiler Checks to CI.** Do not include `moc --check` in the CI configuration. This check should only be performed by the agent during the maintenance process to fix warnings, as different CI environments might have different compiler versions that could cause unexpected failures for the end user.

9. **Including toolchain or dev-dependency bumps in CHANGELOG.** Never include `[toolchain]` or `[dev-dependencies]` bumps in the CHANGELOG. They clutter the history with internal development details that do not affect the package's consumers. Only include `[requirements]` or `[dependencies]` if they were explicitly upgraded.

## Verify It Works

After completing all steps, run the validation suite:

```bash
mops install
mops test
mops bench
```

All commands must succeed with no errors.
