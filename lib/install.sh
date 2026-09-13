#!/usr/bin/env bash
# Download a clrnd release archive, verify it, and put the binary on PATH.
# Called from setup/action.yml. It is a separate script rather than inline in run: so that other
# actions in this repository can install clrnd the same way (a composite action cannot uses: a
# sibling action at the same ref, because the ref cannot come from an expression).
#
# Inputs arrive as environment variables. Expanding action inputs inside run: would be a script
# injection.
#   CLRND_VERSION             the version to install (0.5.1 / v0.5.1 / latest)
#   CLRND_VERIFY_ATTESTATION  true / false
#   GH_TOKEN                  the token gh attestation verify uses
set -euo pipefail

readonly repo="masasuzu/clrnd"
# This workflow is the only one that registers provenance. Pin the workflow, not just the
# repository, so an archive built by another workflow or in a fork does not pass.
readonly signer_workflow="${repo}/.github/workflows/release.yml"
readonly semver_re='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

error() {
  echo "::error::$*" >&2
  exit 1
}

for name in RUNNER_OS RUNNER_ARCH RUNNER_TEMP RUNNER_TOOL_CACHE GITHUB_PATH GITHUB_OUTPUT; do
  [[ -n "${!name:-}" ]] || error "$name is not set; this script runs inside a GitHub Actions job"
done

# On Windows runners, RUNNER_TEMP and friends arrive as D:\a\_temp-style paths. Bash commands get
# the Unix form; GITHUB_PATH and PowerShell get the Windows form.
to_unix() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# ---- Inputs -----------------------------------------------------------------

version="${CLRND_VERSION:-}"
# The runner does not enforce required: true for composite actions, so reject an empty value here.
[[ -n "$version" ]] || error "input 'version' is required (e.g. 0.5.1, or 'latest')"

verify="${CLRND_VERIFY_ATTESTATION:-true}"
case "$verify" in
  true | false) ;;
  *) error "input 'verify-attestation' must be 'true' or 'false', got '$verify'" ;;
esac

if [[ "$version" == latest ]]; then
  # Resolve from the releases/latest redirect rather than the API. The API needs a token and is
  # rate limited; the redirect needs neither, and no jq either.
  location=$(curl -fsS --retry 3 -o /dev/null -w '%{redirect_url}' "https://github.com/${repo}/releases/latest") ||
    error "could not resolve the latest clrnd release"
  version="${location##*/tag/}"
  [[ "$version" =~ $semver_re ]] || error "could not resolve the latest clrnd release (redirected to '$location')"
  echo "Resolved 'latest' to $version"
fi

[[ "$version" =~ $semver_re ]] || error "input 'version' must look like 0.5.1 or v0.5.1, got '$version'"
readonly tag="v${version#v}"
readonly bare="${version#v}"

# Releases before v0.3.0 have neither a provenance attestation nor --version, so neither check can
# run. Letting verify-attestation: false install them would also disable the final check against a
# mixed-up archive, so they are refused outright.
IFS=. read -r major minor _ <<<"$bare"
# Without 10#, a zero-padded number such as 08 is parsed as octal and fails.
if ((10#$major == 0 && 10#$minor < 3)); then
  error "clrnd $tag is not supported; this action installs v0.3.0 or later"
fi

case "$RUNNER_OS" in
  Linux) os=linux ext=tar.gz exe="" ;;
  macOS) os=darwin ext=tar.gz exe="" ;;
  Windows) os=windows ext=zip exe=".exe" ;;
  *) error "unsupported runner OS: $RUNNER_OS" ;;
esac
case "$RUNNER_ARCH" in
  X64) arch=amd64 ;;
  ARM64) arch=arm64 ;;
  *) error "unsupported runner architecture: $RUNNER_ARCH" ;;
esac
readonly os arch ext exe

readonly asset="clrnd_${bare}_${os}_${arch}.${ext}"
tool_cache=$(to_unix "$RUNNER_TOOL_CACHE")
readonly install_dir="${tool_cache}/clrnd/${bare}/${arch}"
readonly binary="${install_dir}/clrnd${exe}"
# Marks that verification finished. A binary alone cannot be told apart from what a failed run
# left behind.
readonly marker="${install_dir}.complete"

# ---- Download and verification ----------------------------------------------

if [[ -f "$marker" && -x "$binary" ]]; then
  echo "clrnd $tag is already installed at $install_dir"
else
  work=$(mktemp -d "$(to_unix "$RUNNER_TEMP")/clrnd.XXXXXX")
  trap 'rm -rf "$work"' EXIT

  base_url="https://github.com/${repo}/releases/download/${tag}"
  echo "Downloading $asset from $base_url"
  curl -fsSL --retry 3 -o "$work/$asset" "$base_url/$asset" ||
    error "could not download $asset; check that clrnd $tag exists and ships a $os/$arch build"
  curl -fsSL --retry 3 -o "$work/checksums.txt" "$base_url/checksums.txt" ||
    error "could not download checksums.txt for clrnd $tag"

  # checksums.txt is served from the same place as the archive, so on its own it guarantees
  # nothing against tampering. It catches a corrupted download; tampering is the attestation's job.
  expected=$(awk -v f="$asset" '$2 == f { print $1 }' "$work/checksums.txt")
  [[ -n "$expected" ]] || error "checksums.txt for clrnd $tag has no entry for $asset"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
  else
    actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
  fi
  [[ "$actual" == "$expected" ]] || error "checksum mismatch for $asset: expected $expected, got $actual"
  echo "Checksum matches checksums.txt"

  if [[ "$verify" == true ]]; then
    command -v gh >/dev/null 2>&1 ||
      error "gh is required to verify the build provenance attestation; install it, or set verify-attestation: false"
    [[ -n "${GH_TOKEN:-}" ]] ||
      error "gh attestation verify needs a token; pass github-token, or set verify-attestation: false"
    # --source-ref binds the archive to the tag. Without it, an archive the same workflow built for
    # another tag (an older release, say) would pass as the requested version.
    gh attestation verify "$work/$asset" \
      --repo "$repo" \
      --signer-workflow "$signer_workflow" \
      --source-ref "refs/tags/$tag" >&2 ||
      error "build provenance attestation for $asset did not verify"
    # gh prints nothing on success, so record here that the check passed.
    echo "Verified the build provenance attestation: built by $signer_workflow from refs/tags/$tag"
  else
    echo "Skipped the build provenance attestation (verify-attestation: false)"
  fi

  mkdir -p "$work/extract"
  if [[ "$ext" == zip ]]; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$work/$asset" "clrnd${exe}" -d "$work/extract"
    else
      pwsh -NoProfile -NonInteractive -Command \
        "Expand-Archive -LiteralPath '$(to_native "$work/$asset")' -DestinationPath '$(to_native "$work/extract")'"
    fi
  else
    tar -xzf "$work/$asset" -C "$work/extract" "clrnd${exe}"
  fi

  rm -rf "$install_dir" "$marker"
  mkdir -p "$install_dir"
  mv "$work/extract/clrnd${exe}" "$binary"
  chmod +x "$binary"
  touch "$marker"
  echo "Installed clrnd ${bare} to $install_dir"
fi

# One last check against a mix-up (an archive for another version or OS).
reported=$("$binary" --version)
[[ "$reported" == "clrnd version ${bare}" ]] ||
  error "installed binary reports '$reported', expected 'clrnd version ${bare}'"

to_native "$install_dir" >>"$GITHUB_PATH"
{
  echo "version=${bare}"
  echo "path=$(to_native "$binary")"
} >>"$GITHUB_OUTPUT"
