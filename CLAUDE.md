# CLAUDE.md

This file provides shared guidance to Claude Code and OpenAI Codex when working with code in this repository.

## Overview

GitHub Actions for [clrnd](https://github.com/masasuzu/clrnd), a Go CLI that deploys services to
Google Cloud Run. The actions are consumed with `uses:` and are **not** published to GitHub
Marketplace. That is what allows more than one action here: Marketplace requires a single
`action.yml` at the repository root, and nothing else does.

Each action lives in its own directory and is referenced as `masasuzu/clrnd-actions/<name>@<sha>`.
`setup` is the only one so far: it installs a verified clrnd release and puts it on `PATH`.

## Commands

There is no build step and no unit-test framework. The checks are:

```sh
bash -n lib/install.sh   # syntax
shellcheck lib/*.sh      # static analysis
actionlint               # workflows under .github/workflows (not action.yml files)
```

Use the ShellCheck and actionlint versions pinned in [ci.yml](.github/workflows/ci.yml). The
versions are written down only there on purpose (see Conventions), so do not copy them into this
file or the README.

`lib/install.sh` can be run locally by faking the runner environment. It needs `gh` authenticated
for the attestation check:

```sh
r=$(mktemp -d) && mkdir -p "$r/temp" "$r/cache" && : >"$r/path" && : >"$r/out"
RUNNER_OS=macOS RUNNER_ARCH=ARM64 RUNNER_TEMP="$r/temp" RUNNER_TOOL_CACHE="$r/cache" \
  GITHUB_PATH="$r/path" GITHUB_OUTPUT="$r/out" GH_TOKEN="$(gh auth token)" \
  CLRND_VERSION=0.5.1 CLRND_VERIFY_ATTESTATION=true \
  bash lib/install.sh
cat "$r/path" "$r/out"
```

Anything specific to a runner (the Windows path handling, Linux ARM64) is only exercised by CI.
Push a branch to see it.

## Architecture

- [setup/action.yml](setup/action.yml) is a composite action with a single step that runs
  [lib/install.sh](lib/install.sh). The logic lives in `lib/` rather than inline in `run:` so that
  future actions can install clrnd the same way. A composite action cannot usefully `uses:` a
  sibling action. `uses: ./setup` resolves against the **caller's** workspace, and
  `uses: masasuzu/clrnd-actions/setup@<ref>` cannot take its ref from an expression, so it could
  not follow whichever version of this repository the caller pinned. Call the shared script
  instead: `bash "${GITHUB_ACTION_PATH}/../lib/<script>.sh"`. The script is started through `bash`
  so that it does not depend on the committed executable bit.
- Inputs reach the script through `env:`, **never** as `${{ inputs.* }}` inside `run:`. An
  expression in `run:` is pasted into the script before bash parses it, which makes it a script
  injection. `required: true` is not enforced for composite actions, so the script validates
  every input itself, including an empty `version`.
- `install.sh` is coupled to clrnd's release pipeline, and each of these breaks it if clrnd changes:
  - The archive name `clrnd_<version>_<os>_<arch>.tar.gz` (`.zip` on Windows) and `checksums.txt`
    come from clrnd's `.goreleaser.yaml`. The binary is expected at the root of the archive.
  - The attestation must be signed by `masasuzu/clrnd/.github/workflows/release.yml`.
  - `clrnd --version` must print exactly `clrnd version <version>` without the `v` prefix.
- **Versions before v0.3.0 are refused**, even with `verify-attestation: false`. Those releases carry
  neither an attestation nor `--version`, so neither the provenance nor the version mix-up check
  could run. Allowing them would quietly turn off the last check as well.
- Verification happens in this order, and each check guards against something different:
  - **Checksum** against `checksums.txt`. This only catches a corrupted download: the file comes
    from the same place as the archive, so on its own it says nothing about tampering. The code
    comment and the README both say so; do not describe it as more than that.
  - **Attestation** with `gh attestation verify --repo … --signer-workflow … --source-ref
    refs/tags/<tag>`. `--source-ref` is what binds the archive to the *requested* tag. Without it,
    an archive the same workflow built for another release would pass. `gh` prints nothing on
    success, so the script logs a line saying the check passed. Without that line, a log cannot
    tell a verified install from a skipped one. `gh` requires a token even for a public repository;
    a `GITHUB_TOKEN` with only `contents: read` is enough, as confirmed in CI.
  - **`--version`** of the installed binary. This catches an archive for the wrong version or
    platform.
- `latest` is resolved from the redirect of `https://github.com/masasuzu/clrnd/releases/latest`,
  not from the REST API. The redirect needs no token, has no rate limit and needs no `jq`.
- **Tool cache**: the binary goes to `$RUNNER_TOOL_CACHE/clrnd/<version>/<arch>`, and a
  `<arch>.complete` marker is written only after every check has passed. When the marker exists, the
  download and **all verification are skipped**. GitHub-hosted runners start each job with a fresh
  tool cache, so in practice that only happens within a single job or on a self-hosted runner.
- **Windows**: steps run under Git Bash. `RUNNER_TEMP`, `RUNNER_TOOL_CACHE` and similar arrive as
  `D:\a\_temp`-style paths. They are converted with `cygpath -u` for bash, and back with `cygpath -w`
  for `$GITHUB_PATH`, the `path` output and PowerShell. `to_unix` and `to_native` are no-ops where
  `cygpath` does not exist. Zip archives are extracted with `unzip` when it exists, otherwise with
  `pwsh Expand-Archive`.
- Errors go through `error()`, which prints `::error::` so the message becomes an annotation.
  Progress goes to stdout as plain lines.

## Testing (ci.yml)

- The `setup` job runs the action on every runner in its matrix and checks the `version` and
  `path` outputs and `clrnd --version` from `PATH`. It then runs the action again in the same job
  to go through the cache. Windows ARM64 is not in the matrix.
- The `setup-inputs` job covers inputs and failure cases on a single runner. A case that must fail
  uses `continue-on-error: true`, and a later step asserts `steps.<id>.outcome == 'failure'`. The
  outcome alone does not show *why* it failed, so when adding such a case, check in the run log
  that the `::error::` is the intended one.
- **Beware the tool cache within a job.** A step that installs a version an earlier step already
  installed hits the cache and skips download and verification, so it passes without running the
  path it claims to test. The `verify-attestation: false` step did exactly that until it was given
  a version (`0.4.0`) that nothing else in the job installs. Any step meant to exercise the download
  or verification path needs a version of its own.
- Test versions must be real clrnd releases at v0.3.0 or later. `latest` follows clrnd's live
  releases, so that case depends on the state of the other repository.

## Conventions

- Everything written in the repository is in **English**: `action.yml` names and descriptions,
  `::error::` messages, code comments in shell and YAML alike, the README and this file.
- Commit messages (subject and body), issue titles and bodies, PR titles and descriptions, and
  review comments and replies are also written in **English**. The first commits are in Japanese;
  leave them as they are rather than rewriting history.
- Workflows follow the same hardening as clrnd:
  - Top-level `permissions: {}`, with each job granting only what it needs.
  - Every job has a `timeout-minutes`.
  - Every `actions/checkout` passes `persist-credentials: false`: CI runs code from pull requests,
    and nothing here does an authenticated git operation.
  - `ci.yml` uses a per-ref `concurrency` group with `cancel-in-progress: true`.
- Actions are pinned to a full commit SHA with the version in a trailing comment. Dependabot
  ([.github/dependabot.yml](.github/dependabot.yml)) moves those pins.
- **Tools that CI downloads itself** (ShellCheck, actionlint) are pinned to a release **with its
  SHA-256 checked**, not taken from the runner image, whose version changes underneath the check.
  Dependabot does not see these pins, so they are bumped by hand. Each version is written in
  exactly one place, its `env:` in `ci.yml`, which is why clrnd's `check-tool-pins.sh` is not
  needed here. If a version ever has to appear in a second place (the README, this file), add that
  kind of consistency check at the same time.
- Examples in the README pin the action as `@<sha>`, and user documentation should keep
  recommending SHA pins.
- When adding an action:
  - Create `<name>/action.yml` and put shared logic in `lib/`.
  - Do not mirror clrnd's flags as inputs. A command that is a single `run: clrnd …` line after
    `setup` gains nothing from being wrapped, and every mirrored flag drifts from the CLI.
  - An action earns its place by doing what one `run:` line cannot, such as outputs, a step summary
    or a PR comment. Commands without that belong in the README as workflow examples.
  - Add a CI job that runs the new action through `uses: ./<name>`.
- Never write Google Cloud project IDs or numbers, service names, revision names or `*.run.app`
  URLs into this public repository: code, workflows, docs, commit messages, issues and PRs alike.
  Use placeholders such as `<project>` and `my-svc`.
