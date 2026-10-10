#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dogsc-signing-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
mkdir "$fixture_root/bin"
cp "$project_root/build-app.sh" "$fixture_root/build-app.sh"

# Run the real script's validation without a Mac, keychain, or app build.
cat > "$fixture_root/bin/uname" <<'SH'
#!/bin/bash
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *) exit 1 ;;
esac
SH
cat > "$fixture_root/bin/security" <<'SH'
#!/bin/bash
[[ "$*" = "find-identity -v -p codesigning" ]] || exit 1
echo '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Fixture"'
echo '     1 valid identities found'
SH
cat > "$fixture_root/bin/swift" <<'SH'
#!/bin/bash
[[ "$*" = "build -c release --product DogSC" ]] || exit 1
touch "$DOGSC_TEST_BUILD_REACHED"
exit 23
SH
chmod +x "$fixture_root/bin/"*

failures=0
check_identity() {
  local label="$1" identity="$2" expected_status="$3" status=0
  rm -f "$fixture_root/build-reached"
  PATH="$fixture_root/bin:$PATH" \
    DEVELOPER_DIR="$fixture_root" \
    DOGSC_SIGNING_IDENTITY="$identity" \
    DOGSC_TEST_BUILD_REACHED="$fixture_root/build-reached" \
    bash "$fixture_root/build-app.sh" > "$fixture_root/output.log" 2>&1 || status=$?

  if [[ "$status" != "$expected_status" ]] \
      || { [[ "$expected_status" = 23 ]] && [[ ! -f "$fixture_root/build-reached" ]]; } \
      || { [[ "$expected_status" = 1 ]] && [[ -f "$fixture_root/build-reached" ]]; }; then
    printf 'FAIL: %s (expected exit %s, got %s)\n' "$label" "$expected_status" "$status" >&2
    cat "$fixture_root/output.log" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "$label"
  fi
}

# Exit 23 comes from the stub build command after validation succeeds.
check_identity uppercase AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 23
check_identity lowercase aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 23
check_identity mixed-case aAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaA 23
check_identity absent BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB 1
check_identity invalid ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ 1
[[ "$failures" = 0 ]]
