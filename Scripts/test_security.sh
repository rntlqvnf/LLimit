#!/usr/bin/env bash
# Security and correctness tests for LLimit.
# Runs without Xcode — only needs Swift CLI tools.
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

echo "==> Building"
swift build 2>&1 | tail -1

echo ""
echo "==> Security Tests"

# 1. No sensitive data in stderr logging
echo ""
echo "--- Logging Redaction ---"

# Check that no token/code values are logged
if grep -n 'code.prefix\|verifier.prefix\|body=\\$\|bodyStr.prefix\|body.prefix' \
    Sources/LLimit/Services/ClaudeOAuthLogin.swift \
    Sources/LLimit/Services/UsageAPI.swift 2>/dev/null; then
  fail "Sensitive data still present in log statements"
else
  pass "No sensitive data in log statements"
fi

# Check that auth URLs are not logged with query params
if grep -n 'authURL.absoluteString' Sources/LLimit/Services/ClaudeOAuthLogin.swift 2>/dev/null; then
  fail "Auth URL with query params still logged"
else
  pass "Auth URLs not logged with query params"
fi

# 2. File permissions
echo ""
echo "--- File Permissions ---"

if grep -n 'posixPermissions.*0o600' Sources/LLimit/Services/AccountStore.swift | grep -q 'save'; then
  pass "accounts.json gets 0o600 permissions on save"
else
  # Check if the permission setting is near the save function
  if grep -A5 'write(to: storeURL' Sources/LLimit/Services/AccountStore.swift | grep -q '0o600'; then
    pass "accounts.json gets 0o600 permissions on save"
  else
    fail "accounts.json missing 0o600 permissions"
  fi
fi

if grep -q 'posixPermissions.*0o600' Sources/LLimit/Services/AuthSource.swift; then
  pass "Credential files get 0o600 permissions"
else
  fail "Credential files missing 0o600 permissions"
fi

if grep -q 'posixPermissions.*0o700' Sources/LLimit/Services/AuthSource.swift; then
  pass "Credentials directory gets 0o700 permissions"
else
  fail "Credentials directory missing 0o700 permissions"
fi

# 3. URL construction safety
echo ""
echo "--- URL Safety ---"

if grep -q 'URLComponents' Sources/LLimit/Services/UsageAPI.swift; then
  pass "organizationId uses URLComponents (not string interpolation)"
else
  fail "organizationId uses unsafe string interpolation"
fi

# 4. Config dir validation
echo ""
echo "--- Config Dir Validation ---"

if grep -q 'isValidConfigDir' Sources/LLimit/Views/SettingsView.swift; then
  pass "Config directory validation exists"
else
  fail "Config directory validation missing"
fi

# 5. HTTPS only
echo ""
echo "--- Network Security ---"

HTTP_URLS=$(grep -n 'http://' Sources/LLimit/Services/UsageAPI.swift Sources/LLimit/Services/ClaudeOAuthLogin.swift 2>/dev/null \
  | grep -v 'localhost\|127\.0\.0\.1\|redirectHost\|redirectPort' | head -5 || true)
if [ -z "$HTTP_URLS" ]; then
  pass "All external API calls use HTTPS"
else
  fail "Found non-HTTPS URLs: $HTTP_URLS"
fi

# 6. OAuth PKCE
echo ""
echo "--- OAuth Security ---"

if grep -q 'S256' Sources/LLimit/Services/ClaudeOAuthLogin.swift; then
  pass "PKCE uses S256 challenge method"
else
  fail "PKCE not using S256"
fi

if grep -q 'SecRandomCopyBytes\|CryptoKit' Sources/LLimit/Services/ClaudeOAuthLogin.swift; then
  pass "Cryptographically secure random for PKCE verifier"
else
  fail "PKCE verifier may not use secure random"
fi

if grep -q 'state.*mismatch\|cbState.*!=.*state' Sources/LLimit/Services/ClaudeOAuthLogin.swift; then
  pass "OAuth state parameter validated"
else
  fail "OAuth state parameter not validated"
fi

# 7. No hardcoded secrets
echo ""
echo "--- Secrets ---"

if grep -rn 'sk-ant-\|sk_live\|OPENAI_API_KEY.*=.*"sk-' Sources/LLimit/ 2>/dev/null | grep -v 'prefix\|CodingKey\|Decodable'; then
  fail "Possible hardcoded API keys found"
else
  pass "No hardcoded API keys"
fi

# Summary
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
