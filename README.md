# clrnd-actions

GitHub Actions for [clrnd](https://github.com/masasuzu/clrnd), a CLI that deploys services to
Google Cloud Run.

## setup

Installs a clrnd release and puts it on `PATH`. Before anything is installed, the archive is
checked against the release's `checksums.txt` and its
[build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
is verified: it must have been built by clrnd's `release.yml` from the tag of the version you asked
for.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # for Workload Identity Federation
    steps:
      - uses: actions/checkout@<sha>

      - uses: google-github-actions/auth@<sha>
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.DEPLOY_SERVICE_ACCOUNT }}

      - uses: masasuzu/clrnd-actions/setup@<sha> # v1.0.0
        with:
          version: 0.5.1

      - run: clrnd deploy --auto-approve
```

clrnd authenticates with Application Default Credentials, which `google-github-actions/auth`
sets up; this action does not handle credentials itself.

Pin the action to a full commit SHA, as above, and let Dependabot move the pin.

### Inputs

| Name | Default | Description |
| ---- | ------- | ----------- |
| `version` | (required) | The clrnd release to install: `0.5.1` or `v0.5.1`, v0.3.0 or later. `latest` resolves the newest release at run time, so the same workflow may install a different version on the next run. |
| `verify-attestation` | `true` | Verify the build provenance attestation with `gh attestation verify`. Requires `gh` on the runner, which GitHub-hosted runners have. Set to `false` only on runners where `gh` is not available; the checksum is still checked, but it comes from the same place as the archive and does not protect against a tampered release. |
| `github-token` | `${{ github.token }}` | The token `gh attestation verify` uses. |

### Outputs

| Name | Description |
| ---- | ----------- |
| `version` | The installed version, without the `v` prefix. |
| `path` | The absolute path of the installed binary. |

### Supported runners

Linux, macOS and Windows on x64 and ARM64. Steps run under `bash`, which Windows runners provide
through Git for Windows.

Releases before v0.3.0 are refused: they carry no attestation and no `--version`, so neither the
provenance nor the installed version can be checked.
