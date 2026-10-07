# Plan 002: Run `flutter analyze` and `flutter test` on every push and pull request

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 1fd219d..HEAD -- .github/workflows pubspec.yaml analysis_options.yaml`
> This plan adds one new file. If `.github/workflows/ci.yml` already exists, or the Flutter version printed by
> `fvm flutter --version` is no longer `3.47.3`, STOP (see STOP conditions).

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (a new, isolated workflow)
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `1fd219d`, 2026-10-02

## Why this matters

The repo has 22 test files and a clean `flutter analyze`, but nothing runs them: there is no `.github/workflows/`.
A regression only shows up when the maintainer happens to run the checks by hand before a release. A CI job gives
every push to `main` and every pull request the same two gates, with no change to how releases are built.

## Current state

- No CI exists. `.github/` has only `ISSUE_TEMPLATE/` and `pull_request_template.md`.
- Local verification commands (run during recon, both pass on the current tree; the project runs Flutter through
  `fvm`, channel `stable`, currently Flutter 3.47.3):
  - `fvm flutter analyze` → `No issues found!`
  - `fvm flutter test` → `All tests passed!` (72 tests)
- **The tests need no `--dart-define`s.** `TOP_SITES`, `ANILIST_CLIENT_ID` etc. are only read at runtime
  (`lib/sources.dart` throws a `StateError` only when `topSources()` is actually called, and tests replace it via
  `Sites.load`). So CI does not need any secret.
- `analysis_options.yaml` is `include: package:flutter_lints/flutter.yaml` and excludes `build/**` and `android/**`,
  so analysis never touches the Kotlin sources.
- `pubspec.yaml`: `environment: sdk: ^3.13.3`; `.fvmrc` is `{"flutter": "stable"}`.
- Third-party actions are pinned to full commit SHAs (looked up from GitHub on 2026-10-02):
  - `actions/checkout` v7.0.1 → `3d3c42e5aac5ba805825da76410c181273ba90b1`
  - `subosito/flutter-action` v2.23.0 → `1a449444c387b1966244ae4d4f8c696479add0b2`
- Commit-message style: sentence-case imperative, no prefix, **no trailers** (no `Co-Authored-By`). Example from
  `git log`: `Pause the player while a picker, dialog or the episode drawer is open`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Analyze | `fvm flutter analyze` | `No issues found!`, exit 0 |
| Tests | `fvm flutter test` | `All tests passed!`, exit 0 |
| Parse the workflow | `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` | exit 0, no output |
| Lint the workflow (only if installed) | `actionlint .github/workflows/ci.yml` | exit 0 (skip if not installed) |

## Scope

**In scope** (the only files you should modify):
- `.github/workflows/ci.yml` (create)

**Out of scope** (do NOT touch):
- Building APKs or signing in CI — the release key is not in the repo and must not be added as a secret here.
- An Android/Kotlin compile job. It is a sensible follow-up (`./gradlew :app:compileDebugKotlin` works locally) but
  needs Java 17, the Android SDK and Flutter's generated `android/local.properties`, and cannot be verified without
  running on GitHub. Leave it for a separate plan.
- Any change to tests, `analysis_options.yaml`, or `pubspec.yaml` to make CI pass. If CI would fail, STOP.
- `.github/workflows/release-announce.yml` (plan 001) — independent.

## Git workflow

- Branch: `advisor/002-ci` (no branch convention is evident in the repo).
- One commit, message e.g. `Run analyze and tests on every push and pull request`. No trailers.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm the gates pass locally on the tree you are about to protect

**Verify**: `fvm flutter analyze` → `No issues found!`; `fvm flutter test` → `All tests passed!`.
If either fails, STOP: CI would be red on day one. Report the failure instead of changing code.

### Step 2: Create the workflow

Create `.github/workflows/ci.yml` with exactly this content:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

# A newer push to the same branch or PR supersedes a run still in progress.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2 # v2.23.0
        with:
          channel: stable
          # Pinned so a new Flutter release can't turn the build red on its own; bump it with the local fvm version.
          flutter-version: 3.47.3
          cache: true
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
```

**Verify**: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` → exit 0. If `actionlint`
is installed, `actionlint .github/workflows/ci.yml` → exit 0.

### Step 3: Commit

```sh
git add .github/workflows/ci.yml
git commit -m "Run analyze and tests on every push and pull request"
```

**Verify**: `git status --short` → clean; `git show --stat HEAD` lists only `.github/workflows/ci.yml`.

## Test plan

The workflow can only run on GitHub. After it is on `main` (or in a PR), the maintainer should open the Actions tab
and confirm the "CI" run is green. Expect it to take a few minutes; the first run populates the Flutter/pub cache.
If it fails on something that passes locally (a timezone- or locale-dependent test, say), that is a real finding —
report it rather than loosening a test.

## Done criteria

ALL must hold:

- [ ] `fvm flutter analyze` → `No issues found!`, and `fvm flutter test` → `All tests passed!` (before and after)
- [ ] `.github/workflows/ci.yml` exists and parses as YAML
- [ ] Both third-party actions are referenced by the full SHAs above (`grep -n "uses:" .github/workflows/ci.yml` shows 40-character SHAs, not tags)
- [ ] `git status --short` is clean after the commit and `git show --stat HEAD` lists only the workflow file
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `fvm flutter analyze` or `fvm flutter test` fails in Step 1.
- `.github/workflows/ci.yml` already exists.
- `fvm flutter --version` is not 3.47.3 (the pin in the workflow would then be wrong — report the version so the
  plan can be corrected).
- You are tempted to add build, signing, secrets or `--dart-define`s: out of scope.

## Maintenance notes

- Bump `flutter-version` whenever the local fvm Flutter is upgraded, and bump the two action SHAs deliberately
  (e.g. with Dependabot's `github-actions` ecosystem, which understands SHA pins with a trailing `# vX.Y.Z` comment).
- Natural follow-ups: an Android compile job; making the CI check required in branch protection once it has been
  green for a while; a `## Check` line in `README.md` (`fvm flutter analyze && fvm flutter test`).
- Reviewer: confirm the workflow has no `secrets.*` and `permissions` stays read-only.
