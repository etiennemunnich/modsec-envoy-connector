#!/usr/bin/env bash
# Install go-ftw, the OWASP CRS regression test runner, at the version CI uses
# (GO_FTW_VERSION in .github/workflows/live-e2e.yml).
#   https://github.com/coreruleset/go-ftw
# Downloads the release tarball for this OS/arch, verifies it against the
# release's ftw-checksums.txt, and installs `ftw` into ${PREFIX}/bin
# (default ~/.local/bin). demo/scripts/go-ftw.sh also looks there.
set -euo pipefail

GO_FTW_VERSION="${GO_FTW_VERSION:-2.6.0}"
PREFIX="${PREFIX:-${HOME}/.local}"
BIN_DIR="${PREFIX}/bin"

have_version() {
  # have_version <binary> — 0 if it reports exactly GO_FTW_VERSION.
  local v
  v="$("$1" -v 2>&1 | head -1)"
  [[ "${v}" == "go-ftw version ${GO_FTW_VERSION}" ]]
}

for bin in "${BIN_DIR}/ftw" "$(command -v ftw || true)" "$(command -v go-ftw || true)"; do
  if [[ -n "${bin}" && -x "${bin}" ]] && have_version "${bin}"; then
    echo "OK: go-ftw ${GO_FTW_VERSION} at ${bin}"
    exit 0
  fi
done

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 2 ;;
esac

base="https://github.com/coreruleset/go-ftw/releases/download/v${GO_FTW_VERSION}"
asset="ftw_${GO_FTW_VERSION}_${os}_${arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
echo "==> go-ftw ${GO_FTW_VERSION} (${os}/${arch})"
curl -fsSL --retry 3 -o "${tmp}/${asset}" "${base}/${asset}"
curl -fsSL --retry 3 -o "${tmp}/ftw-checksums.txt" "${base}/ftw-checksums.txt"
want="$(awk -v a="${asset}" '$2 == a {print $1}' "${tmp}/ftw-checksums.txt")"
[[ -n "${want}" ]] || { echo "no checksum for ${asset}" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  got="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
else
  got="$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')"
fi
[[ "${got}" == "${want}" ]] || { echo "checksum mismatch for ${asset}: ${got} != ${want}" >&2; exit 1; }
tar -xzf "${tmp}/${asset}" -C "${tmp}" ftw
mkdir -p "${BIN_DIR}"
install -m 0755 "${tmp}/ftw" "${BIN_DIR}/ftw"
have_version "${BIN_DIR}/ftw" || { echo "${BIN_DIR}/ftw does not report ${GO_FTW_VERSION}" >&2; exit 1; }
echo "OK: go-ftw ${GO_FTW_VERSION} at ${BIN_DIR}/ftw"
if [[ "${BIN_DIR}" != "${HOME}/.local/bin" ]]; then
  echo "note: demo/scripts/go-ftw.sh looks in ~/.local/bin and PATH; use FTW_BIN=${BIN_DIR}/ftw"
fi
