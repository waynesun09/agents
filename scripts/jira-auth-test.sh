#!/usr/bin/env bash
# jira-auth-test.sh — Tests for scripts/lib/jira-auth.lib.sh (agents#1926).
#
# Covers the five credential cases: token + email (Basic), token only
# (Bearer), OAuth 2.0 client credentials (minted Bearer token, fake curl and
# fake fullsend on PATH), the CI OIDC token file whose token is sent to a
# self-hosted gateway, and conflicting settings. In client-credentials
# mode, asserts the client secret is in no curl or fullsend argv and in no
# stdout or stderr; in OIDC mode, the same for the OIDC token.
#
# Run from the repo root:
#   bash scripts/jira-auth-test.sh

set -euo pipefail

if [[ "${SCRIPT_TEST_TARGET:-source}" == "bundled" ]]; then
  echo "SKIP: jira-auth-test (lib tests skipped in bundled mode)"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tests set exactly the Jira credentials they need.
unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL FULLSEND_JIRA_CLIENT_ID \
  FULLSEND_JIRA_CLIENT_SECRET FULLSEND_JIRA_OIDC_TOKEN_FILE JIRA_TOKEN \
  JIRA_USER_EMAIL JIRA_API_URL
LIB="${SCRIPT_DIR}/lib/jira-auth.lib.sh"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT
MOCK_BIN="${TMPDIR_ROOT}/bin"
mkdir -p "${MOCK_BIN}"

# A secret with JSON metacharacters, to check the request body escaping.
SECRET='sec"ret\value-DO-NOT-LEAK'
CLIENT_ID="client-id-123"
API_URL="https://api.atlassian.com/ex/jira/cloud-1"
# Two JWT-shaped OIDC tokens (the file before and after a refresh) and a
# self-hosted gateway for the OIDC cases.
OIDC_TOKEN="test-header.test-payload.oidc-sig-one-DO-NOT-LEAK"
OIDC_TOKEN_2="test-header.test-payload.oidc-sig-two-DO-NOT-LEAK"
GATEWAY_URL="https://jira-gw.example.com/ex/jira/cloud-1"

# Fake curl: logs its argv, logs stdin when the body is read from stdin,
# logs the content of a --config file, writes a status line to a
# --dump-header file (FAKE_GATEWAY_STATUS, default 200), and answers the
# Atlassian token endpoint (body + "\n<status>", as --write-out produces).
# Other calls print a fixed body.
cat > "${MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOG_DIR}/curl-argv.log"
url=""
stdin_body=0
config=""
dump=""
prev=""
for arg in "$@"; do
  case "${prev}" in
    --config) config="${arg}" ;;
    --dump-header) dump="${arg}" ;;
  esac
  prev="${arg}"
  case "${arg}" in
    https://*) url="${arg}" ;;
    @-) stdin_body=1 ;;
  esac
done
if [[ -n "${config}" ]]; then
  cat "${config}" >> "${LOG_DIR}/curl-config.log"
fi
if [[ -n "${dump}" ]]; then
  printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "${FAKE_GATEWAY_STATUS:-200}" > "${dump}"
fi
if [[ "${stdin_body}" -eq 1 ]]; then
  cat >> "${LOG_DIR}/curl-stdin.log"
  printf '\n' >> "${LOG_DIR}/curl-stdin.log"
fi
if [[ "${url}" == "https://auth.atlassian.com/oauth/token" ]]; then
  n=0
  [[ -f "${LOG_DIR}/mint-count" ]] && n="$(cat "${LOG_DIR}/mint-count")"
  n=$((n + 1))
  printf '%s' "${n}" > "${LOG_DIR}/mint-count"
  case "${FAKE_MINT:-ok}" in
    ok) printf '{"access_token":"minted-token-%s","expires_in":%s,"token_type":"Bearer"}\n200' "${n}" "${FAKE_EXPIRES_IN:-3600}" ;;
    deny) printf '{"error":"access_denied","error_description":"leaky-response-body"}\n401' ;;
    bad-colons) printf '{"access_token":"bad-tok::warning::x","expires_in":3600}\n200' ;;
    bad-newline) printf '{"access_token":"bad-tok\\n::warning::x","expires_in":3600}\n200' ;;
    bad-encoded) printf '{"access_token":"bad-tok%%0A::warning::x","expires_in":3600}\n200' ;;
    bad-control) printf '{"access_token":"bad-tok\\u001bx","expires_in":3600}\n200' ;;
  esac
  exit 0
fi
printf '{"ok":true}'
MOCKEOF
chmod +x "${MOCK_BIN}/curl"

# Fake fullsend: logs its argv and which Jira variables it got. The secret
# value is compared here rather than logged.
cat > "${MOCK_BIN}/fullsend" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOG_DIR}/fullsend-argv.log"
secret_state="unset"
if [[ -n "${FULLSEND_JIRA_CLIENT_SECRET+x}" ]]; then
  secret_state="wrong"
  [[ "${FULLSEND_JIRA_CLIENT_SECRET}" == "${EXPECTED_SECRET:-}" ]] && secret_state="ok"
fi
printf 'token=%s email=%s id=%s secret=%s\n' "${FULLSEND_JIRA_TOKEN-unset}" \
  "${FULLSEND_JIRA_EMAIL-unset}" "${FULLSEND_JIRA_CLIENT_ID-unset}" "${secret_state}" \
  >> "${LOG_DIR}/fullsend-env.log"
printf 'oidc-file=%s oidc-token=%s\n' "${FULLSEND_JIRA_OIDC_TOKEN_FILE-unset}" \
  "${FULLSEND_JIRA_OIDC_TOKEN:+set}" >> "${LOG_DIR}/fullsend-oidc.log"
MOCKEOF
chmod +x "${MOCK_BIN}/fullsend"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1 — $2"
  FAILURES=$((FAILURES + 1))
}

# run_case NAME BODY — run BODY (bash code) in a fresh bash with the library
# sourced and the fakes first on PATH. Its stdout is a pipe, as on a CI
# runner. Sets CASE_DIR, CASE_RC, CASE_OUT and
# CASE_ERR (paths to the captured stdout and stderr).
run_case() {
  local name="$1"
  local body="$2"
  CASE_DIR="${TMPDIR_ROOT}/${name}"
  mkdir -p "${CASE_DIR}"
  CASE_OUT="${CASE_DIR}/stdout"
  CASE_ERR="${CASE_DIR}/stderr"
  CASE_RC=0
  env -u FULLSEND_JIRA_TOKEN -u FULLSEND_JIRA_EMAIL -u FULLSEND_JIRA_CLIENT_ID \
    -u FULLSEND_JIRA_CLIENT_SECRET -u JIRA_TOKEN -u JIRA_USER_EMAIL -u JIRA_API_URL \
    -u FULLSEND_JIRA_OIDC_TOKEN_FILE \
    PATH="${MOCK_BIN}:${PATH}" LOG_DIR="${CASE_DIR}" EXPECTED_SECRET="${SECRET}" \
    TEST_SECRET="${SECRET}" TEST_CLIENT_ID="${CLIENT_ID}" TEST_API_URL="${API_URL}" \
    TEST_OIDC="${OIDC_TOKEN}" TEST_OIDC_2="${OIDC_TOKEN_2}" TEST_GATEWAY="${GATEWAY_URL}" \
    FAKE_MINT="${FAKE_MINT:-ok}" FAKE_EXPIRES_IN="${FAKE_EXPIRES_IN:-3600}" \
    FAKE_GATEWAY_STATUS="${FAKE_GATEWAY_STATUS:-200}" \
    bash -c "set -euo pipefail; source '${LIB}'; ${body}" \
    2> "${CASE_ERR}" | cat > "${CASE_OUT}" || CASE_RC=$?
}

# Assert the secret is in no argv of any curl or fullsend call and in no
# stdout or stderr of the case.
assert_secret_hidden() {
  local name="$1"
  local f
  for f in "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-argv.log" "${CASE_OUT}" "${CASE_ERR}"; do
    [[ -f "${f}" ]] || continue
    if grep -qF -- "${SECRET}" "${f}"; then
      fail "${name}-secret-hidden" "client secret found in $(basename "${f}")"
      return
    fi
  done
  pass "${name}-secret-hidden"
}

# --- Case 1: token + email — Basic auth, unchanged ---
run_case token-email '
  jira_auth_select "tok-1" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_curl "tok-1" " bot@example.com " "https://site.atlassian.net/rest/api/3/myself" >/dev/null
  jira_auth_fullsend fullsend "tok-1" "bot@example.com" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=token" "${CASE_OUT}" \
  && grep -qF -- "--user bot@example.com:tok-1 " "${CASE_DIR}/curl-argv.log" \
  && grep -qx "token=tok-1 email=bot@example.com id=unset secret=unset" "${CASE_DIR}/fullsend-env.log" \
  && [[ ! -f "${CASE_DIR}/mint-count" ]]; then
  pass "token-email-basic-auth"
else
  fail "token-email-basic-auth" "rc=${CASE_RC}; $(cat "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-env.log" "${CASE_ERR}" 2>/dev/null)"
fi

# Without jira_auth_select the helpers keep the token behaviour.
run_case token-no-select '
  jira_auth_curl "tok-1" "bot@example.com" "https://site.atlassian.net/x" >/dev/null
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qF -- "--user bot@example.com:tok-1 " "${CASE_DIR}/curl-argv.log"; then
  pass "token-without-select-unchanged"
else
  fail "token-without-select-unchanged" "rc=${CASE_RC}"
fi

# --- Case 2: token only — Bearer auth, unchanged ---
run_case token-only '
  export FULLSEND_JIRA_EMAIL=inherited@example.com
  jira_auth_select "tok-2" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "tok-2" "  " "https://site.atlassian.net/rest/api/3/myself" >/dev/null
  jira_auth_fullsend fullsend "tok-2" "" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] \
  && grep -qF -- "--oauth2-bearer tok-2 " "${CASE_DIR}/curl-argv.log" \
  && ! grep -qF -- "--user" "${CASE_DIR}/curl-argv.log" \
  && grep -qx "token=tok-2 email=unset id=unset secret=unset" "${CASE_DIR}/fullsend-env.log"; then
  pass "token-only-bearer-auth"
else
  fail "token-only-bearer-auth" "rc=${CASE_RC}; $(cat "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-env.log" "${CASE_ERR}" 2>/dev/null)"
fi

run_case token-empty '
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  echo "mode=${JIRA_AUTH_MODE}"
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=none" "${CASE_OUT}"; then
  pass "nothing-set-selects-none"
else
  fail "nothing-set-selects-none" "rc=${CASE_RC}"
fi

# --- Case 3: client credentials ---
run_case client '
  export JIRA_API_URL="${TEST_API_URL}"
  export FULLSEND_JIRA_TOKEN=inherited-token FULLSEND_JIRA_EMAIL=inherited@example.com
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_require_api_url
  jira_auth_mint
  # A call in a command substitution reuses the token minted above, and its
  # captured output is the curl output only.
  captured="$(jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself")"
  echo "captured=${captured}"
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/search/jql" >/dev/null
  printf "body" | jira_auth_fullsend fullsend "" "" issues post-comment --result -
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=client" "${CASE_OUT}"; then
  pass "client-selects-client-mode"
else
  fail "client-selects-client-mode" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
if grep -c "https://auth.atlassian.com/oauth/token" "${CASE_DIR}/curl-argv.log" | grep -qx 1 \
  && grep -F "https://auth.atlassian.com/oauth/token" "${CASE_DIR}/curl-argv.log" | grep -qF -- "--data @-"; then
  pass "client-mints-once-with-body-on-stdin"
else
  fail "client-mints-once-with-body-on-stdin" "$(cat "${CASE_DIR}/curl-argv.log")"
fi
if grep -F "https://auth.atlassian.com/oauth/token" "${CASE_DIR}/curl-argv.log" | grep -q -- "^-q --proto =https "; then
  pass "client-mint-ignores-curl-config-https-only"
else
  fail "client-mint-ignores-curl-config-https-only" "$(cat "${CASE_DIR}/curl-argv.log")"
fi
if jq -e --arg id "${CLIENT_ID}" --arg secret "${SECRET}" \
  '.grant_type == "client_credentials" and .client_id == $id and .client_secret == $secret' \
  "${CASE_DIR}/curl-stdin.log" >/dev/null 2>&1; then
  pass "client-token-request-body"
else
  fail "client-token-request-body" "token request body is not the expected JSON"
fi
# Line 1 is the case's own "mode=" line; the mask comes before any other.
if [[ "$(sed -n 2p "${CASE_OUT}")" == "::add-mask::minted-token-1" ]] \
  && [[ "$(grep -c "minted-token" "${CASE_OUT}")" -eq 1 ]]; then
  pass "client-minted-token-masked-first"
else
  fail "client-minted-token-masked-first" "$(cat "${CASE_OUT}")"
fi
if grep -qx 'captured={"ok":true}' "${CASE_OUT}"; then
  pass "client-mask-not-in-captured-output"
else
  fail "client-mask-not-in-captured-output" "$(cat "${CASE_OUT}")"
fi
if [[ "$(grep -c -- "--oauth2-bearer minted-token-1 ${API_URL}/rest/api/3/" "${CASE_DIR}/curl-argv.log")" -eq 2 ]] \
  && ! grep -qF -- "--user" "${CASE_DIR}/curl-argv.log" \
  && ! grep -qF -- "inherited-token" "${CASE_DIR}/curl-argv.log"; then
  pass "client-rest-calls-bearer-to-api-url"
else
  fail "client-rest-calls-bearer-to-api-url" "$(cat "${CASE_DIR}/curl-argv.log")"
fi
if grep -qx "token=unset email=unset id=${CLIENT_ID} secret=ok" "${CASE_DIR}/fullsend-env.log"; then
  pass "client-fullsend-gets-client-vars-only"
else
  fail "client-fullsend-gets-client-vars-only" "$(cat "${CASE_DIR}/fullsend-env.log")"
fi
assert_secret_hidden "client"

# xtrace on: the mint still prints no secret.
run_case client-xtrace '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  set -x
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself" >/dev/null
  set +x
'
if [[ "${CASE_RC}" -eq 0 ]] && [[ -f "${CASE_DIR}/mint-count" ]]; then
  pass "client-xtrace-mints"
else
  fail "client-xtrace-mints" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_secret_hidden "client-xtrace"

# xtrace on through select, mint and the fullsend call: no stderr line,
# including the traced jira_auth_select call line, carries the secret.
run_case client-xtrace-all '
  export JIRA_API_URL="${TEST_API_URL}"
  set -x
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself" >/dev/null
  printf "body" | jira_auth_fullsend fullsend "" "" issues post-comment --result -
  set +x
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -q "secret=ok" "${CASE_DIR}/fullsend-env.log" \
  && ! grep -qF -- "${SECRET}" "${CASE_ERR}" \
  && grep -q "^+* jira_auth_select '' TEST_CLIENT_ID TEST_SECRET$" "${CASE_ERR}" \
  && grep -q "^+* jira_auth_curl " "${CASE_ERR}"; then
  pass "client-xtrace-select-and-fullsend-hide-secret"
else
  fail "client-xtrace-select-and-fullsend-hide-secret" "rc=${CASE_RC}"
fi

# A first mint inside a command substitution keeps the mask line out of
# the captured value.
run_case client-mint-in-substitution '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  captured="$(jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself")"
  printf "%s" "${captured}" > "${LOG_DIR}/captured"
'
# With /proc (Linux), the mask reaches the main shell's stdout pipe;
# without it, stderr.
MASK_FILE="${CASE_ERR}"
[[ -e /proc/self/fd/1 ]] && MASK_FILE="${CASE_OUT}"
if [[ "${CASE_RC}" -eq 0 ]] && [[ "$(cat "${CASE_DIR}/captured")" == '{"ok":true}' ]] \
  && grep -qx "::add-mask::minted-token-1" "${MASK_FILE}"; then
  pass "client-subshell-mint-mask-not-captured"
else
  fail "client-subshell-mint-mask-not-captured" "rc=${CASE_RC}; $(cat "${CASE_DIR}/captured" 2>/dev/null)"
fi

# A caller that redirects stdout to a file around a subshell mint gets no
# token in that file; the mask goes to stderr instead.
run_case client-mint-redirected '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  g() { r="$(jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself")"; echo "r=${r}"; }
  g > "${LOG_DIR}/redirected"
  g > /dev/null
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx 'r={"ok":true}' "${CASE_DIR}/redirected" \
  && ! grep -qF "minted-token" "${CASE_DIR}/redirected" \
  && [[ "$(grep -c "^::add-mask::minted-token-" "${CASE_ERR}")" -eq 2 ]]; then
  pass "client-subshell-mint-redirected-stdout-gets-no-token"
else
  fail "client-subshell-mint-redirected-stdout-gets-no-token" "rc=${CASE_RC}"
fi

# Loading the library leaves no extra file descriptor open for child
# processes to inherit.
CASE_RC=0
fd_out="$(env -u FULLSEND_JIRA_TOKEN -u FULLSEND_JIRA_CLIENT_ID -u FULLSEND_JIRA_CLIENT_SECRET -u JIRA_TOKEN \
  bash -c "before=\"\$(cd /dev/fd && echo *)\"; source '${LIB}'; after=\"\$(cd /dev/fd && echo *)\"; echo \"before=\${before} after=\${after}\"" \
  2>&1)" || CASE_RC=$?
if [[ "${CASE_RC}" -eq 0 && "${fd_out}" =~ ^before=(.*)\ after=(.*)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
  pass "library-load-opens-no-fd"
else
  fail "library-load-opens-no-fd" "${fd_out}"
fi

# Surrounding whitespace in the client ID and secret is trimmed, as fullsend
# does; a tab inside the secret is kept and JSON-escaped.
SAVED_SECRET="${SECRET}"
SECRET=$'sec\tret-inner-DO-NOT-LEAK'
run_case client-whitespace '
  export JIRA_API_URL="${TEST_API_URL}"
  ws_id="  ${TEST_CLIENT_ID} "
  ws_secret=$'"'"'\t '"'"'"${TEST_SECRET}"$'"'"' \t'"'"'
  jira_auth_select "" ws_id ws_secret
  jira_auth_mint
  printf "body" | jira_auth_fullsend fullsend "" "" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] && jq -e --arg id "${CLIENT_ID}" --arg secret "${SECRET}" \
  '.client_id == $id and .client_secret == $secret' "${CASE_DIR}/curl-stdin.log" >/dev/null 2>&1 \
  && grep -qx "token=unset email=unset id=${CLIENT_ID} secret=ok" "${CASE_DIR}/fullsend-env.log"; then
  pass "client-credentials-trimmed"
else
  fail "client-credentials-trimmed" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_secret_hidden "client-whitespace"
SECRET="${SAVED_SECRET}"

# A token that is only whitespace counts as unset.
run_case token-whitespace '
  jira_auth_select " 	 " FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  echo "mode=${JIRA_AUTH_MODE}"
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=none" "${CASE_OUT}"; then
  pass "whitespace-token-selects-none"
else
  fail "whitespace-token-selects-none" "rc=${CASE_RC}"
fi

# A token within 5 minutes of expiry is minted again.
FAKE_EXPIRES_IN=200 run_case client-expiring '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  jira_auth_curl "" "" "${JIRA_API_URL}/a" >/dev/null
  jira_auth_curl "" "" "${JIRA_API_URL}/b" >/dev/null
'
if [[ "${CASE_RC}" -eq 0 ]] && [[ "$(cat "${CASE_DIR}/mint-count")" == "2" ]] \
  && grep -qF -- "--oauth2-bearer minted-token-2 ${API_URL}/b" "${CASE_DIR}/curl-argv.log"; then
  pass "client-remints-near-expiry"
else
  fail "client-remints-near-expiry" "rc=${CASE_RC}; $(cat "${CASE_DIR}/curl-argv.log")"
fi

# A refused token request reports the HTTP status, never the body, and no
# REST call is made.
FAKE_MINT=deny run_case client-denied '
  export JIRA_API_URL="${TEST_API_URL}"
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself"
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "HTTP 401" "${CASE_ERR}" \
  && ! grep -qF "leaky-response-body" "${CASE_OUT}" "${CASE_ERR}" \
  && ! grep -qF "/rest/api/3/myself" "${CASE_DIR}/curl-argv.log"; then
  pass "client-mint-failure-status-only"
else
  fail "client-mint-failure-status-only" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_secret_hidden "client-denied"

# Client credentials need JIRA_API_URL; there is no JIRA_BASE_URL fallback.
run_case client-no-api-url '
  jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
  jira_auth_require_api_url
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "JIRA_API_URL" "${CASE_ERR}"; then
  pass "client-requires-api-url"
else
  fail "client-requires-api-url" "rc=${CASE_RC}"
fi
run_case token-no-api-url '
  jira_auth_select "tok" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_require_api_url
'
if [[ "${CASE_RC}" -eq 0 ]]; then
  pass "token-does-not-require-api-url"
else
  fail "token-does-not-require-api-url" "rc=${CASE_RC}"
fi

# A minted token outside the JWT charset is refused like a failed request:
# no mask line, no token printed, no REST call.
for bad in colons newline encoded control; do
  FAKE_MINT="bad-${bad}" run_case "client-bad-token-${bad}" '
    export JIRA_API_URL="${TEST_API_URL}"
    jira_auth_select "" TEST_CLIENT_ID TEST_SECRET
    jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself"
  '
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "no usable access_token" "${CASE_ERR}" \
    && ! grep -qF "add-mask" "${CASE_OUT}" "${CASE_ERR}" \
    && ! grep -qF "bad-tok" "${CASE_OUT}" "${CASE_ERR}" \
    && ! grep -qF "/rest/api/3/myself" "${CASE_DIR}/curl-argv.log"; then
    pass "client-bad-token-${bad}-refused"
  else
    fail "client-bad-token-${bad}-refused" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}")"
  fi
done

# The client ID and secret are variable names; a value or a name that
# would collide with the function's locals is refused without echoing it.
for badname in "${CLIENT_ID}" '_jas_secret' ''; do
  run_case "bad-name" "
    jira_auth_select '' '${badname}' TEST_SECRET
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "names of the client ID and secret variables" "${CASE_ERR}" \
    && ! grep -qF -- "${CLIENT_ID}" "${CASE_ERR}"; then
    pass "select-refuses-bad-name-'${badname}'"
  else
    fail "select-refuses-bad-name-'${badname}'" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  assert_secret_hidden "bad-name"
done

# --- Case 4: conflicting settings fail, naming variables, not values ---
for conflict in "both|tok-4|${CLIENT_ID}|${SECRET}" "token-and-id|tok-4|${CLIENT_ID}|" \
  "id-only||${CLIENT_ID}|" "secret-only|||${SECRET}"; do
  IFS='|' read -r cname ctoken cid csecret <<< "${conflict}"
  CASE_DIR="${TMPDIR_ROOT}/conflict-${cname}"
  mkdir -p "${CASE_DIR}"
  CASE_OUT="${CASE_DIR}/stdout"
  CASE_ERR="${CASE_DIR}/stderr"
  CASE_RC=0
  # The ID and secret go through the environment, not the bash -c body.
  env PATH="${MOCK_BIN}:${PATH}" LOG_DIR="${CASE_DIR}" TEST_ID_ARG="${cid}" TEST_SECRET_ARG="${csecret}" \
    bash -c "source '${LIB}'; jira_auth_select '${ctoken}' TEST_ID_ARG TEST_SECRET_ARG" \
    > "${CASE_OUT}" 2> "${CASE_ERR}" || CASE_RC=$?
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "FULLSEND_JIRA_CLIENT_" "${CASE_ERR}" \
    && ! grep -qF "tok-4" "${CASE_ERR}" && ! grep -qF "${CLIENT_ID}" "${CASE_ERR}"; then
    pass "conflict-${cname}-fails"
  else
    fail "conflict-${cname}-fails" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  assert_secret_hidden "conflict-${cname}"
done

# --- Case 5: CI OIDC token file, token sent to a self-hosted Jira gateway ---

# Assert neither OIDC token is in any argv of a curl or fullsend call or in
# the case's stdout or stderr. The curl config log is where the token
# belongs, so it is not checked.
assert_oidc_hidden() {
  local name="$1"
  local f
  for f in "${CASE_DIR}/curl-argv.log" "${CASE_DIR}/fullsend-argv.log" "${CASE_OUT}" "${CASE_ERR}"; do
    [[ -f "${f}" ]] || continue
    if grep -qF -e "${OIDC_TOKEN}" -e "${OIDC_TOKEN_2}" "${f}"; then
      fail "${name}-oidc-token-hidden" "OIDC token found in $(basename "${f}")"
      return
    fi
  done
  pass "${name}-oidc-token-hidden"
}

# Body prefix: write the first token to a 0600 file under the case
# directory and point FULLSEND_JIRA_OIDC_TOKEN_FILE at it.
OIDC_SETUP='
  umask 077
  printf "%s\n" "${TEST_OIDC}" > "${LOG_DIR}/oidc-token"
  export FULLSEND_JIRA_OIDC_TOKEN_FILE="${LOG_DIR}/oidc-token"
'

# The file is read on every call: replacing it between two calls (an
# atomic rename, as fullsend run refreshes it) makes the second call send
# the new token, and no shell variable keeps either token afterwards.
run_case oidc "${OIDC_SETUP}"'
  export JIRA_API_URL="${TEST_GATEWAY}/" FULLSEND_JIRA_EMAIL=inherited@example.com
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_require_api_url
  jira_auth_mint
  # Both calls run in this shell, not a command substitution, so a value
  # kept from the first call would still be there for the second.
  jira_auth_curl "" "bot@example.com" "${TEST_GATEWAY}/rest/api/3/myself" > "${LOG_DIR}/captured"
  echo "captured=$(cat "${LOG_DIR}/captured")"
  printf "%s\n" "${TEST_OIDC_2}" > "${LOG_DIR}/oidc-token.new"
  mv -f "${LOG_DIR}/oidc-token.new" "${LOG_DIR}/oidc-token"
  jira_auth_curl "" "" "${TEST_GATEWAY}/rest/api/3/issue/X-1" >/dev/null
  printf "body" | jira_auth_fullsend fullsend "" "" issues post-comment --result -
  : reset-underscore
  if ( set -o posix; set ) | grep -v "^TEST_OIDC" | grep -qF -e "${TEST_OIDC}" -e "${TEST_OIDC_2}"; then
    echo "cached=yes"
  else
    echo "cached=no"
  fi
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=oidc" "${CASE_OUT}" \
  && grep -qx 'captured={"ok":true}' "${CASE_OUT}"; then
  pass "oidc-selects-oidc-mode"
else
  fail "oidc-selects-oidc-mode" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
if [[ "$(wc -l < "${CASE_DIR}/curl-argv.log")" -eq 2 ]] \
  && [[ "$(grep -c -- "^-q --proto =https --config .* ${GATEWAY_URL}/rest/api/3/" "${CASE_DIR}/curl-argv.log")" -eq 2 ]] \
  && ! grep -qE -- "--user|--oauth2-bearer|auth.atlassian.com" "${CASE_DIR}/curl-argv.log" \
  && [[ ! -f "${CASE_DIR}/mint-count" ]]; then
  pass "oidc-sends-bearer-to-gateway-via-config"
else
  fail "oidc-sends-bearer-to-gateway-via-config" "$(cat "${CASE_DIR}/curl-argv.log" 2>/dev/null)"
fi
if [[ "$(sed -n 1p "${CASE_DIR}/curl-config.log")" == "header = \"Authorization: Bearer ${OIDC_TOKEN}\"" ]] \
  && [[ "$(sed -n 2p "${CASE_DIR}/curl-config.log")" == "header = \"Authorization: Bearer ${OIDC_TOKEN_2}\"" ]]; then
  pass "oidc-reads-token-file-on-each-call"
else
  fail "oidc-reads-token-file-on-each-call" "the second call did not send the refreshed token"
fi
if grep -qx "cached=no" "${CASE_OUT}"; then
  pass "oidc-token-not-kept-in-shell-variables"
else
  fail "oidc-token-not-kept-in-shell-variables" "a shell variable still holds an OIDC token"
fi
if grep -qx "token=unset email=unset id=unset secret=unset" "${CASE_DIR}/fullsend-env.log" \
  && grep -qx "oidc-file=${CASE_DIR}/oidc-token oidc-token=" "${CASE_DIR}/fullsend-oidc.log"; then
  pass "oidc-fullsend-gets-token-file-only"
else
  fail "oidc-fullsend-gets-token-file-only" "$(cat "${CASE_DIR}/fullsend-env.log" "${CASE_DIR}/fullsend-oidc.log" 2>/dev/null)"
fi
assert_oidc_hidden "oidc"

# xtrace on through select, curl and the fullsend call: no trace line
# carries the token.
run_case oidc-xtrace "${OIDC_SETUP}"'
  export JIRA_API_URL="${TEST_GATEWAY}"
  set -x
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself" >/dev/null
  printf "body" | jira_auth_fullsend fullsend "" "" issues get
  set +x
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -q "^+* jira_auth_curl " "${CASE_ERR}" \
  && [[ -s "${CASE_DIR}/curl-config.log" && -s "${CASE_DIR}/fullsend-oidc.log" ]]; then
  pass "oidc-xtrace-runs"
else
  fail "oidc-xtrace-runs" "rc=${CASE_RC}"
fi
assert_oidc_hidden "oidc-xtrace"

# A saved copy of the path under another name (as post-code.sh passes it)
# selects OIDC.
run_case oidc-named "${OIDC_SETUP}"'
  saved_file="${FULLSEND_JIRA_OIDC_TOKEN_FILE}"
  unset FULLSEND_JIRA_OIDC_TOKEN_FILE
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET saved_file
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_fullsend fullsend "" "" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=oidc" "${CASE_OUT}" \
  && grep -qx "oidc-file=${CASE_DIR}/oidc-token oidc-token=" "${CASE_DIR}/fullsend-oidc.log"; then
  pass "oidc-named-variable"
else
  fail "oidc-named-variable" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi

# The token file next to a token or client credentials fails, naming the
# variables and never the values, before any call.
for conflict in "token-arg" "token-env" "client-pair" "client-id-only"; do
  case "${conflict}" in
    token-arg) setup='jira_auth_select "tok-5" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET' ;;
    token-env) setup='export FULLSEND_JIRA_TOKEN=tok-5; jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET' ;;
    client-pair) setup='jira_auth_select "" TEST_CLIENT_ID TEST_SECRET' ;;
    client-id-only) setup='jira_auth_select "" TEST_CLIENT_ID UNSET_SECRET' ;;
  esac
  run_case "oidc-conflict-${conflict}" "${OIDC_SETUP}
    export JIRA_API_URL=\"\${TEST_GATEWAY}\"
    ${setup}
    jira_auth_curl '' '' \"\${TEST_GATEWAY}/rest/api/3/myself\"
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "FULLSEND_JIRA_OIDC_TOKEN_FILE" "${CASE_ERR}" \
    && grep -qE "FULLSEND_JIRA_TOKEN|FULLSEND_JIRA_CLIENT_ID" "${CASE_ERR}" \
    && ! grep -qF "tok-5" "${CASE_ERR}" && ! grep -qF "${CLIENT_ID}" "${CASE_ERR}" \
    && [[ ! -f "${CASE_DIR}/curl-argv.log" ]]; then
    pass "oidc-conflict-${conflict}-fails"
  else
    fail "oidc-conflict-${conflict}-fails" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  assert_oidc_hidden "oidc-conflict-${conflict}"
  assert_secret_hidden "oidc-conflict-${conflict}"
done

# A missing, empty or unreadable file, or one that holds no JWT, fails the
# REST call and the CLI call with a clear error and calls neither. A
# directory stands in for an unreadable file, since root can read a 0000
# file; the 0000 case runs only when not root.
file_cases="missing empty directory not-jwt"
[[ "$(id -u)" -ne 0 ]] && file_cases="${file_cases} mode-0000"
for fcase in ${file_cases}; do
  case "${fcase}" in
    missing) fsetup='rm -f "${LOG_DIR}/oidc-token"'; want="file is missing" ;;
    empty) fsetup=': > "${LOG_DIR}/oidc-token"'; want="file is empty" ;;
    directory) fsetup='rm -f "${LOG_DIR}/oidc-token"; mkdir "${LOG_DIR}/oidc-token"'; want="not a readable file" ;;
    not-jwt) fsetup='printf "not-a-jwt-DO-NOT-LEAK\n" > "${LOG_DIR}/oidc-token"'; want="does not hold a JWT" ;;
    mode-0000) fsetup='chmod 000 "${LOG_DIR}/oidc-token"'; want="not a readable file" ;;
  esac
  run_case "oidc-file-${fcase}" "${OIDC_SETUP}
    export JIRA_API_URL=\"\${TEST_GATEWAY}\"
    jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
    ${fsetup}
    if jira_auth_curl '' '' \"\${TEST_GATEWAY}/rest/api/3/myself\"; then echo curl=ok; else echo curl=refused; fi
    if jira_auth_fullsend fullsend '' '' issues get; then echo cli=ok; else echo cli=refused; fi
  "
  cli_want="cli=refused"
  # The CLI reads the token itself; the library checks only that the file
  # is there, readable and non-empty.
  [[ "${fcase}" == "not-jwt" ]] && cli_want="cli=ok"
  if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "curl=refused" "${CASE_OUT}" && grep -qx "${cli_want}" "${CASE_OUT}" \
    && grep -qF "FULLSEND_JIRA_OIDC_TOKEN_FILE file" "${CASE_ERR}" && grep -qF "${want}" "${CASE_ERR}" \
    && [[ ! -f "${CASE_DIR}/curl-argv.log" ]] \
    && ! grep -qF "DO-NOT-LEAK" "${CASE_OUT}" "${CASE_ERR}"; then
    pass "oidc-file-${fcase}-refused"
  else
    fail "oidc-file-${fcase}-refused" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}")"
  fi
done

# The CI token never goes to Atlassian or over plain http, and an unset
# JIRA_API_URL has no fallback: both the up-front check and the call refuse.
for api in "unset" "https://api.atlassian.com/ex/jira/cloud-1" "https://site.atlassian.net" \
  "https://API.Atlassian.COM./ex/jira/cloud-1" "https://gw.example.com@api.atlassian.com/ex/jira/c" \
  "https://jira.atlassian.com:443/x" "http://jira-gw.example.com/ex/jira/cloud-1"; do
  api_setup="export JIRA_API_URL='${api}'"
  [[ "${api}" == "unset" ]] && api_setup="export JIRA_BASE_URL=https://site.atlassian.net"
  run_case "oidc-api-url" "${OIDC_SETUP}
    ${api_setup}
    jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
    if jira_auth_require_api_url; then echo require=ok; else echo require=refused; fi
    jira_auth_curl '' '' \"\${JIRA_API_URL:-\${JIRA_BASE_URL}}/rest/api/3/myself\"
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qx "require=refused" "${CASE_OUT}" \
    && grep -qF "JIRA_API_URL" "${CASE_ERR}" \
    && [[ ! -f "${CASE_DIR}/curl-argv.log" ]]; then
    pass "oidc-refuses-api-url-'${api}'"
  else
    fail "oidc-refuses-api-url-'${api}'" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}")"
  fi
  assert_oidc_hidden "oidc-api-url"
  rm -rf "${CASE_DIR}"
done

# A URL argument outside JIRA_API_URL is refused, even with a good gateway.
run_case oidc-other-url "${OIDC_SETUP}"'
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "" "" "https://site.atlassian.net/rest/api/3/myself"
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "outside JIRA_API_URL" "${CASE_ERR}" \
  && [[ ! -f "${CASE_DIR}/curl-argv.log" ]]; then
  pass "oidc-refuses-url-outside-api-url"
else
  fail "oidc-refuses-url-outside-api-url" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi

# A 401 from the gateway fails with its own message, once: no retry, no
# mint, no other credential.
FAKE_GATEWAY_STATUS=401 run_case oidc-401 "${OIDC_SETUP}"'
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "" "" --fail --silent "${JIRA_API_URL}/rest/api/3/myself"
'
if [[ "${CASE_RC}" -ne 0 ]] \
  && grep -qF "HTTP 401: OIDC token refused or expired. Not retrying with another credential." "${CASE_ERR}" \
  && [[ "$(wc -l < "${CASE_DIR}/curl-argv.log")" -eq 1 ]] \
  && [[ ! -f "${CASE_DIR}/mint-count" ]]; then
  pass "oidc-401-fails-without-retry"
else
  fail "oidc-401-fails-without-retry" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_oidc_hidden "oidc-401"

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
