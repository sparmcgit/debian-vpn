#!/usr/bin/env bash
# Test suite for wg-fulltunnel.sh.
#
#   tests/unit/*.sh        - pure function/string checks, no root needed.
#   tests/integration/*.sh - runs wg-fulltunnel.sh for real against real
#                            nft/ip, inside an `unshare --user
#                            --map-root-user --net` sandbox (real root,
#                            throwaway network stack, auto-cleaned on
#                            exit) with wg/wg-quick/systemctl/curl/etc.
#                            mocked. Skipped automatically (with a message,
#                            not a failure) if unprivileged user namespaces
#                            aren't available, or if `nft` itself isn't
#                            installed here - it's deliberately NOT mocked,
#                            since verifying real rule state is the point.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

total=0
failed=0

run_file() {
  local f=$1
  shift
  total=$((total + 1))
  echo "=== ${f#"$HERE"/} ==="
  if "$@" bash "$f"; then
    :
  else
    failed=$((failed + 1))
  fi
  echo
}

echo "--- unit tests ---"
for f in "$HERE"/unit/test_*.sh; do
  run_file "$f"
done

echo "--- integration tests ---"
# nft commonly lives in /usr/sbin, which isn't on a normal user's PATH even
# though it will be on the sandbox's own curated PATH (see setup_sandbox())
# - check the same locations the tests will actually use, not just $PATH.
if ! PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH" command -v nft >/dev/null 2>&1; then
  echo "skipping: nft (nftables) is not installed in this environment"
elif ! unshare --user --map-root-user --net true 2>/dev/null; then
  echo "skipping: unprivileged user namespaces are not available in this environment"
else
  for f in "$HERE"/integration/test_*.sh; do
    run_file "$f" unshare --user --map-root-user --net
  done
fi

echo "======================================"
echo "$((total - failed))/$total test files passed"
[[ $failed -eq 0 ]]
