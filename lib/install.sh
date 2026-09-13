#!/usr/bin/env bash
# clrnd のリリース成果物を取ってきて、検証してから PATH に通す。
# setup/action.yml から呼ばれる。diff / deploy の action からも同じものを呼べるように、
# action.yml の run: に直接書かずスクリプトに分けている (composite action から同じ
# リポジトリの別の action を uses: で呼ぶと、ref を式で書けないので版が揃わない)。
#
# 入力は環境変数で受け取る。action の inputs を run: に式で埋め込むとスクリプト
# インジェクションになるため。
#   CLRND_VERSION             入れる版 (0.5.1 / v0.5.1 / latest)
#   CLRND_VERIFY_ATTESTATION  true / false
#   GH_TOKEN                  gh attestation verify が使うトークン
set -euo pipefail

readonly repo="masasuzu/clrnd"
# provenance を登録するのはこのワークフローだけ。別のワークフローや fork で作られた
# 成果物を通さないよう、リポジトリだけでなくワークフローまで指定する。
readonly signer_workflow="${repo}/.github/workflows/release.yml"
readonly semver_re='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

error() {
  echo "::error::$*" >&2
  exit 1
}

for name in RUNNER_OS RUNNER_ARCH RUNNER_TEMP RUNNER_TOOL_CACHE GITHUB_PATH GITHUB_OUTPUT; do
  [[ -n "${!name:-}" ]] || error "$name is not set; this script runs inside a GitHub Actions job"
done

# Windows の runner では RUNNER_TEMP などが D:\a\_temp の形で来る。bash のコマンドには
# Unix 形式で渡し、GITHUB_PATH や PowerShell には Windows 形式で渡す。
to_unix() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# ---- 入力の検査 -------------------------------------------------------------

version="${CLRND_VERSION:-}"
# composite action の required: true は runner が強制しないので、ここで弾く。
[[ -n "$version" ]] || error "input 'version' is required (e.g. 0.5.1, or 'latest')"

verify="${CLRND_VERIFY_ATTESTATION:-true}"
case "$verify" in
  true | false) ;;
  *) error "input 'verify-attestation' must be 'true' or 'false', got '$verify'" ;;
esac

if [[ "$version" == latest ]]; then
  # API ではなく releases/latest のリダイレクト先から解決する。API はトークンが要り
  # rate limit もあるが、こちらはどちらも無く jq も要らない。
  location=$(curl -fsS --retry 3 -o /dev/null -w '%{redirect_url}' "https://github.com/${repo}/releases/latest") ||
    error "could not resolve the latest clrnd release"
  version="${location##*/tag/}"
  [[ "$version" =~ $semver_re ]] || error "could not resolve the latest clrnd release (redirected to '$location')"
  echo "Resolved 'latest' to $version"
fi

[[ "$version" =~ $semver_re ]] || error "input 'version' must look like 0.5.1 or v0.5.1, got '$version'"
readonly tag="v${version#v}"
readonly bare="${version#v}"

# v0.3.0 より前のリリースには provenance attestation も --version も無く、どちらの検証も
# できない。verify-attestation: false でも入れられるようにすると、取り違えを弾く最後の
# 確認まで効かなくなるので、一律に断る。
IFS=. read -r major minor _ <<<"$bare"
# 10# を付けないと 08 のような先頭 0 付きの数字が 8 進数として解釈されて落ちる。
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
# 検証まで終わったことの印。バイナリがあるだけでは、途中で落ちた回の残骸と区別できない。
readonly marker="${install_dir}.complete"

# ---- ダウンロードと検証 -----------------------------------------------------

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

  # checksums.txt は成果物と同じ場所から配られるので、これだけでは改ざんに対する保証に
  # ならない。壊れたダウンロードを弾くためのもので、改ざんは attestation で見る。
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
    # --source-ref でタグまで縛る。無いと、同じワークフローが別のタグでビルドした
    # 成果物 (たとえば古い版) を、指定した版として通してしまう。
    gh attestation verify "$work/$asset" \
      --repo "$repo" \
      --signer-workflow "$signer_workflow" \
      --source-ref "refs/tags/$tag" >&2 ||
      error "build provenance attestation for $asset did not verify"
    # gh は成功しても何も出さないので、検証を通ったことはここで残す。
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

# 取り違え (別の版・別の OS の成果物) を最後にもう一度弾く。
reported=$("$binary" --version)
[[ "$reported" == "clrnd version ${bare}" ]] ||
  error "installed binary reports '$reported', expected 'clrnd version ${bare}'"

to_native "$install_dir" >>"$GITHUB_PATH"
{
  echo "version=${bare}"
  echo "path=$(to_native "$binary")"
} >>"$GITHUB_OUTPUT"
