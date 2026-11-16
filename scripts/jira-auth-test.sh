#!/usr/bin/env bash
# jira-auth-test.sh — Tests for scripts/lib/jira-auth.lib.sh (agents#1926).
#
# Covers the five credential cases: token + email (Basic), token only
# (Bearer), OAuth 2.0 client credentials (minted Bearer token, fake curl and
# fake fullsend on PATH), CI OIDC tokens from an fd broker sent to a
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
  FULLSEND_JIRA_CLIENT_SECRET FULLSEND_JIRA_OIDC_TOKEN_FD JIRA_TOKEN \
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
# Two JWT-shaped OIDC tokens (two broker answers) and a self-hosted
# gateway for the OIDC cases. The fake broker runs the case with one end of
# a socketpair, as fullsend run does.
OIDC_TOKEN="test-header.test-payload.oidc-sig-one-DO-NOT-LEAK"
OIDC_TOKEN_2="test-header.test-payload.oidc-sig-two-DO-NOT-LEAK"
GATEWAY_URL="https://jira-gw.example.com/ex/jira/cloud-1"
BROKER="${SCRIPT_DIR}/test-fixtures/jira-oidc-broker.py"
TLS_SERVER="${SCRIPT_DIR}/test-fixtures/jira-oidc-tls-server.py"

# Fake curl: logs its argv, logs stdin when the body is read from stdin,
# logs the content of a --config file, writes a status line to a
# --dump-header file (FAKE_GATEWAY_STATUS, default 200; a space-separated
# list gives one status per gateway call, the last repeating), prints a
# body naming a 401, and answers the
# Atlassian token endpoint (body + "\n<status>", as --write-out produces).
# Other calls print a fixed body.
cat > "${MOCK_BIN}/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LOG_DIR}/curl-argv.log"
# Whether this curl still holds the broker fd (it must not).
if [[ -n "${TEST_BROKER_FD:-}" ]]; then
  if { : >&"${TEST_BROKER_FD}"; } 2>/dev/null; then
    echo "broker-fd=open" >> "${LOG_DIR}/curl-fd.log"
  else
    echo "broker-fd=closed" >> "${LOG_DIR}/curl-fd.log"
  fi
fi
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
  n=0
  [[ -f "${LOG_DIR}/gateway-count" ]] && n="$(cat "${LOG_DIR}/gateway-count")"
  printf '%s' "$((n + 1))" > "${LOG_DIR}/gateway-count"
  read -r -a statuses <<< "${FAKE_GATEWAY_STATUS:-200}"
  (( n < ${#statuses[@]} )) || n=$((${#statuses[@]} - 1))
  status="${statuses[${n}]}"
  printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "${status}" > "${dump}"
  if [[ "${status}" == "401" ]]; then
    printf '{"denied":true}'
    exit 0
  fi
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
# With a broker fd, ask it for one token as the real CLI would, and log
# only the answer's first word.
broker="unset"
if [[ -n "${FULLSEND_JIRA_OIDC_TOKEN_FD:-}" ]]; then
  broker="closed"
  if { printf 'token\n' >&"${FULLSEND_JIRA_OIDC_TOKEN_FD}"; } 2>/dev/null \
    && IFS= read -r -t 5 reply <&"${FULLSEND_JIRA_OIDC_TOKEN_FD}"; then
    broker="answered-${reply%% *}"
  fi
fi
printf 'oidc-fd=%s broker=%s oidc-token=%s\n' "${FULLSEND_JIRA_OIDC_TOKEN_FD-unset}" \
  "${broker}" "${FULLSEND_JIRA_OIDC_TOKEN:+set}" \
  >> "${LOG_DIR}/fullsend-oidc.log"
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
# runner. With CASE_BROKER set (broker answers, one per line), the fake
# broker runs it with FULLSEND_JIRA_OIDC_TOKEN_FD set and logs to
# CASE_DIR/broker.log. Sets CASE_DIR, CASE_RC, CASE_OUT and
# CASE_ERR (paths to the captured stdout and stderr).
run_case() {
  local name="$1"
  local body="$2"
  CASE_DIR="${TMPDIR_ROOT}/${name}"
  mkdir -p "${CASE_DIR}"
  CASE_OUT="${CASE_DIR}/stdout"
  CASE_ERR="${CASE_DIR}/stderr"
  CASE_RC=0
  local prefix=()
  if [[ -n "${CASE_BROKER:-}" ]]; then
    printf '%s\n' "${CASE_BROKER}" > "${CASE_DIR}/broker-answers"
    prefix=(python3 -I "${BROKER}" "${CASE_DIR}/broker.log" "${CASE_DIR}/broker-answers" --)
  fi
  env -u FULLSEND_JIRA_TOKEN -u FULLSEND_JIRA_EMAIL -u FULLSEND_JIRA_CLIENT_ID \
    -u FULLSEND_JIRA_CLIENT_SECRET -u JIRA_TOKEN -u JIRA_USER_EMAIL -u JIRA_API_URL \
    -u FULLSEND_JIRA_OIDC_TOKEN_FD -u TEST_BROKER_FD -u CASE_BROKER \
    PATH="${MOCK_BIN}:${PATH}" LOG_DIR="${CASE_DIR}" EXPECTED_SECRET="${SECRET}" \
    TEST_SECRET="${SECRET}" TEST_CLIENT_ID="${CLIENT_ID}" TEST_API_URL="${API_URL}" \
    TEST_OIDC="${OIDC_TOKEN}" TEST_OIDC_2="${OIDC_TOKEN_2}" TEST_GATEWAY="${GATEWAY_URL}" \
    FAKE_MINT="${FAKE_MINT:-ok}" FAKE_EXPIRES_IN="${FAKE_EXPIRES_IN:-3600}" \
    FAKE_GATEWAY_STATUS="${FAKE_GATEWAY_STATUS:-200}" \
    ${prefix[@]+"${prefix[@]}"} bash -c "set -euo pipefail; source '${LIB}'; ${body}" \
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

# --- Case 5: CI OIDC tokens from the fd broker, sent to a self-hosted gateway ---

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

# Number of token requests the broker received.
broker_requests() {
  grep -c '^request ' "${CASE_DIR}/broker.log" 2>/dev/null || true
}

# Each call asks the broker for a token and sends that call's answer: two
# calls send two different tokens. curl does not hold the broker fd, the
# CLI does and can ask on it, and no shell variable keeps a token.
CASE_BROKER="ok ${OIDC_TOKEN}
ok ${OIDC_TOKEN_2}
ok ${OIDC_TOKEN}" run_case oidc '
  export JIRA_API_URL="${TEST_GATEWAY}/" FULLSEND_JIRA_EMAIL=inherited@example.com
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_require_api_url
  jira_auth_mint
  # Both calls run in this shell, not a command substitution, so a value
  # kept from the first call would still be there for the second.
  jira_auth_curl "" "bot@example.com" "${TEST_GATEWAY}/rest/api/3/myself" > "${LOG_DIR}/captured"
  echo "captured=$(cat "${LOG_DIR}/captured")"
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
  && [[ "$(sed -n 2p "${CASE_DIR}/curl-config.log")" == "header = \"Authorization: Bearer ${OIDC_TOKEN_2}\"" ]] \
  && [[ "$(broker_requests)" -eq 3 ]] && ! grep -qvE '^(request token|inode .*)$' "${CASE_DIR}/broker.log"; then
  pass "oidc-asks-broker-on-each-call"
else
  fail "oidc-asks-broker-on-each-call" "$(cat "${CASE_DIR}/broker.log" 2>/dev/null)"
fi
if [[ "$(sort -u "${CASE_DIR}/curl-fd.log")" == "broker-fd=closed" ]]; then
  pass "oidc-curl-does-not-hold-broker-fd"
else
  fail "oidc-curl-does-not-hold-broker-fd" "$(cat "${CASE_DIR}/curl-fd.log" 2>/dev/null)"
fi
if grep -qx "cached=no" "${CASE_OUT}"; then
  pass "oidc-token-not-kept-in-shell-variables"
else
  fail "oidc-token-not-kept-in-shell-variables" "a shell variable still holds an OIDC token"
fi
if grep -qx "token=unset email=unset id=unset secret=unset" "${CASE_DIR}/fullsend-env.log" \
  && grep -qE "^oidc-fd=[0-9]+ broker=answered-ok oidc-token=$" "${CASE_DIR}/fullsend-oidc.log"; then
  pass "oidc-fullsend-inherits-broker-fd-only"
else
  fail "oidc-fullsend-inherits-broker-fd-only" "$(cat "${CASE_DIR}/fullsend-env.log" "${CASE_DIR}/fullsend-oidc.log" 2>/dev/null)"
fi
assert_oidc_hidden "oidc"

# xtrace on through select, curl and the fullsend call: no trace line
# carries the token.
CASE_BROKER="ok ${OIDC_TOKEN}
ok ${OIDC_TOKEN}" run_case oidc-xtrace '
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

# A saved copy of the fd number under another name (as post-code.sh passes
# it) selects OIDC.
CASE_BROKER="ok ${OIDC_TOKEN}" run_case oidc-named '
  saved_fd="${FULLSEND_JIRA_OIDC_TOKEN_FD}"
  unset FULLSEND_JIRA_OIDC_TOKEN_FD
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET saved_fd
  echo "mode=${JIRA_AUTH_MODE}"
  jira_auth_fullsend fullsend "" "" issues get
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "mode=oidc" "${CASE_OUT}" \
  && grep -q "broker=answered-ok" "${CASE_DIR}/fullsend-oidc.log"; then
  pass "oidc-named-variable"
else
  fail "oidc-named-variable" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi

# jira_auth_drop_oidc_fd closes the fd and unsets the variable: a child
# started after it holds neither, and a later Jira call fails clearly.
CASE_BROKER="ok ${OIDC_TOKEN}" run_case oidc-drop '
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  ( jira_auth_drop_oidc_fd; bash -c "{ : >&${TEST_BROKER_FD}; } 2>/dev/null && echo child-fd=open || echo child-fd=closed; echo child-var=\${FULLSEND_JIRA_OIDC_TOKEN_FD-unset}" )
  bash -c "{ : >&${TEST_BROKER_FD}; } 2>/dev/null && echo parent-fd=open || echo parent-fd=closed"
  jira_auth_drop_oidc_fd
  if jira_auth_curl "" "" "${JIRA_API_URL}/rest/api/3/myself"; then echo after=ok; else echo after=refused; fi
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "child-fd=closed" "${CASE_OUT}" && grep -qx "child-var=unset" "${CASE_OUT}" \
  && grep -qx "parent-fd=open" "${CASE_OUT}" && grep -qx "after=refused" "${CASE_OUT}" \
  && grep -qF "token broker is not open" "${CASE_ERR}" && [[ ! -f "${CASE_DIR}/curl-argv.log" ]]; then
  pass "oidc-drop-closes-fd-and-unsets-variable"
else
  fail "oidc-drop-closes-fd-and-unsets-variable" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}")"
fi

# The broker fd next to a token or client credentials fails, naming the
# variables and never the values, before any call.
for conflict in "token-arg" "token-env" "client-pair" "client-id-only"; do
  case "${conflict}" in
    token-arg) setup='jira_auth_select "tok-5" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET' ;;
    token-env) setup='export FULLSEND_JIRA_TOKEN=tok-5; jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET' ;;
    client-pair) setup='jira_auth_select "" TEST_CLIENT_ID TEST_SECRET' ;;
    client-id-only) setup='jira_auth_select "" TEST_CLIENT_ID UNSET_SECRET' ;;
  esac
  CASE_BROKER="ok ${OIDC_TOKEN}" run_case "oidc-conflict-${conflict}" "
    export JIRA_API_URL=\"\${TEST_GATEWAY}\"
    ${setup}
    jira_auth_curl '' '' \"\${TEST_GATEWAY}/rest/api/3/myself\"
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "FULLSEND_JIRA_OIDC_TOKEN_FD" "${CASE_ERR}" \
    && grep -qE "FULLSEND_JIRA_TOKEN|FULLSEND_JIRA_CLIENT_ID" "${CASE_ERR}" \
    && ! grep -qF "tok-5" "${CASE_ERR}" && ! grep -qF "${CLIENT_ID}" "${CASE_ERR}" \
    && [[ ! -f "${CASE_DIR}/curl-argv.log" && "$(broker_requests)" -eq 0 ]]; then
    pass "oidc-conflict-${conflict}-fails"
  else
    fail "oidc-conflict-${conflict}-fails" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  assert_oidc_hidden "oidc-conflict-${conflict}"
  assert_secret_hidden "oidc-conflict-${conflict}"
done

# An fd value that is not a number from 3 up is refused at select.
for badfd in "abc" "1" "-4" "99999"; do
  run_case "oidc-bad-fd" "
    export FULLSEND_JIRA_OIDC_TOKEN_FD='${badfd}'
    jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "file descriptor number from 3 up" "${CASE_ERR}"; then
    pass "oidc-bad-fd-'${badfd}'-refused"
  else
    fail "oidc-bad-fd-'${badfd}'-refused" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  rm -rf "${CASE_DIR}"
done

# Broker failures fail the call before curl, with a clear message, and the
# answer line is never printed: err <code>, no answer in time, a closed
# broker, an unexpected answer, a malformed err, an ok without a JWT, and
# an fd that is not open at all.
for bcase in "err|err fetch_failed|could not supply a token (err fetch_failed)" \
  "timeout|hang|did not answer within 1s" \
  "closed|close|closed without an answer" \
  "unexpected|okay-DO-NOT-LEAK|sent an unexpected answer" \
  "bad-err|err Bad Code DO-NOT-LEAK|sent a malformed error" \
  "not-jwt|ok not-a-jwt-DO-NOT-LEAK|did not send a JWT" \
  "not-open||token broker is not open"; do
  IFS='|' read -r bname banswer bwant <<< "${bcase}"
  fd_setup=''
  [[ "${bname}" == "not-open" ]] && fd_setup='export FULLSEND_JIRA_OIDC_TOKEN_FD=97'
  CASE_BROKER="${banswer}" run_case "oidc-broker-${bname}" "
    ${fd_setup}
    export JIRA_API_URL=\"\${TEST_GATEWAY}\"
    jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
    _JIRA_AUTH_OIDC_TIMEOUT=1
    if jira_auth_curl '' '' \"\${TEST_GATEWAY}/rest/api/3/myself\"; then echo curl=ok; else echo curl=refused; fi
  "
  if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "curl=refused" "${CASE_OUT}" \
    && grep -qF "${bwant}" "${CASE_ERR}" && [[ ! -f "${CASE_DIR}/curl-argv.log" ]] \
    && ! grep -qF "DO-NOT-LEAK" "${CASE_OUT}" "${CASE_ERR}"; then
    pass "oidc-broker-${bname}-fails-clearly"
  else
    fail "oidc-broker-${bname}-fails-clearly" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}")"
  fi
done

# The CI token never goes to Atlassian or over plain http, and an unset
# JIRA_API_URL has no fallback. The host must be a plain lowercase DNS name:
# no user info, percent-encoding or backslash. Both the up-front check and
# the call refuse, before asking the broker.
for api in "unset" "https://api.atlassian.com/ex/jira/cloud-1" "https://site.atlassian.net" \
  "https://API.Atlassian.COM./ex/jira/cloud-1" "https://gw.example.com@api.atlassian.com/ex/jira/c" \
  "https://jira.atlassian.com:443/x" "http://jira-gw.example.com/ex/jira/cloud-1" \
  "https://api.atlassian%2Ecom/ex/jira/cloud-1" "https://atlass%69an.net/" \
  "https://jira-gw.example.com\\@api.atlassian.com/x" "https://jira-gw.example.com:/x" \
  "https://jira-gw.example.com:44a/x" "https://-gw.example.com/x"; do
  api_setup="export JIRA_API_URL='${api}'"
  [[ "${api}" == "unset" ]] && api_setup="export JIRA_BASE_URL=https://site.atlassian.net"
  CASE_BROKER="ok ${OIDC_TOKEN}" run_case "oidc-api-url" "
    ${api_setup}
    jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
    if jira_auth_require_api_url; then echo require=ok; else echo require=refused; fi
    jira_auth_curl '' '' \"\${JIRA_API_URL:-\${JIRA_BASE_URL}}/rest/api/3/myself\"
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qx "require=refused" "${CASE_OUT}" \
    && grep -qF "JIRA_API_URL" "${CASE_ERR}" \
    && [[ ! -f "${CASE_DIR}/curl-argv.log" && "$(broker_requests)" -eq 0 ]]; then
    pass "oidc-refuses-api-url-'${api}'"
  else
    fail "oidc-refuses-api-url-'${api}'" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}")"
  fi
  assert_oidc_hidden "oidc-api-url"
  rm -rf "${CASE_DIR}"
done

# The CLI call checks the gateway too, so a bad JIRA_API_URL never starts
# the CLI with the broker fd.
CASE_BROKER="ok ${OIDC_TOKEN}" run_case oidc-cli-api-url '
  export JIRA_API_URL="https://api.atlassian.com/ex/jira/cloud-1"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_fullsend fullsend "" "" issues get
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "Atlassian host" "${CASE_ERR}" \
  && [[ ! -f "${CASE_DIR}/fullsend-argv.log" ]]; then
  pass "oidc-cli-checks-gateway-first"
else
  fail "oidc-cli-checks-gateway-first" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi

# A URL argument outside JIRA_API_URL, and curl options that would print
# or redirect the headers, read another config, follow redirects or change
# the default scheme, are refused before the broker is asked.
for bad in "https://site.atlassian.net/rest/api/3/myself" -v --verbose --trace --trace-ascii \
  --trace-config --stderr -K --config -D --dump-header -L --location --location-trusted \
  --proto-default -sv -sSL @-; do
  CASE_BROKER="ok ${OIDC_TOKEN}" run_case "oidc-bad-arg" "
    export JIRA_API_URL=\"\${TEST_GATEWAY}\"
    jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
    jira_auth_curl '' '' --silent '${bad}' \"\${TEST_GATEWAY}/rest/api/3/myself\"
  "
  if [[ "${CASE_RC}" -ne 0 ]] && grep -qE "outside JIRA_API_URL|is not allowed with the OIDC token" "${CASE_ERR}" \
    && [[ ! -f "${CASE_DIR}/curl-argv.log" && "$(broker_requests)" -eq 0 ]]; then
    pass "oidc-refuses-curl-arg-'${bad}'"
  else
    fail "oidc-refuses-curl-arg-'${bad}'" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
  fi
  rm -rf "${CASE_DIR}"
done

# A 401 makes the call ask the broker to refresh and try once more with
# the new token. When that succeeds, the caller sees only the second
# response; the refused attempt's body never reaches it.
CASE_BROKER="ok ${OIDC_TOKEN}
ok ${OIDC_TOKEN_2}" FAKE_GATEWAY_STATUS="401 200" run_case oidc-401-refresh-ok '
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "" "" --silent --write-out "\n%{http_code}" "${JIRA_API_URL}/rest/api/3/myself" > "${LOG_DIR}/body"
  echo "rc=$?"
'
if [[ "${CASE_RC}" -eq 0 ]] && grep -qx "rc=0" "${CASE_OUT}" \
  && [[ "$(cat "${CASE_DIR}/body")" == '{"ok":true}' ]] \
  && [[ "$(wc -l < "${CASE_DIR}/curl-argv.log")" -eq 2 ]] \
  && [[ "$(grep '^request ' "${CASE_DIR}/broker.log" | tr '\n' ' ')" == "request token request refresh " ]] \
  && [[ "$(sed -n 2p "${CASE_DIR}/curl-config.log")" == "header = \"Authorization: Bearer ${OIDC_TOKEN_2}\"" ]] \
  && grep -qF "retrying once" "${CASE_ERR}" && [[ ! -f "${CASE_DIR}/mint-count" ]]; then
  pass "oidc-401-refresh-then-success"
else
  fail "oidc-401-refresh-then-success" "rc=${CASE_RC}; $(cat "${CASE_OUT}" "${CASE_ERR}" "${CASE_DIR}/body" 2>/dev/null)"
fi
assert_oidc_hidden "oidc-401-refresh-ok"

# A second 401 after the refresh fails with its own message after exactly
# two attempts: no third try, no mint, no other credential.
CASE_BROKER="ok ${OIDC_TOKEN}
ok ${OIDC_TOKEN_2}
ok ${OIDC_TOKEN}" FAKE_GATEWAY_STATUS="401 401" run_case oidc-401-twice '
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "" "" --fail --silent "${JIRA_API_URL}/rest/api/3/myself"
'
if [[ "${CASE_RC}" -ne 0 ]] \
  && grep -qF "OIDC token refused or expired. Not retrying with another credential." "${CASE_ERR}" \
  && [[ "$(wc -l < "${CASE_DIR}/curl-argv.log")" -eq 2 && "$(broker_requests)" -eq 2 ]] \
  && [[ "$(grep '^request ' "${CASE_DIR}/broker.log" | tr '\n' ' ')" == "request token request refresh " ]] \
  && [[ ! -f "${CASE_DIR}/mint-count" ]]; then
  pass "oidc-401-refresh-then-401-fails-after-two-attempts"
else
  fail "oidc-401-refresh-then-401-fails-after-two-attempts" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi
assert_oidc_hidden "oidc-401-twice"

# A broker error on the refresh fails the call without a second attempt.
CASE_BROKER="ok ${OIDC_TOKEN}
err fetch_failed" FAKE_GATEWAY_STATUS="401 200" run_case oidc-401-refresh-err '
  export JIRA_API_URL="${TEST_GATEWAY}"
  jira_auth_select "" FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
  jira_auth_curl "" "" --silent "${JIRA_API_URL}/rest/api/3/myself"
'
if [[ "${CASE_RC}" -ne 0 ]] && grep -qF "(err fetch_failed)" "${CASE_ERR}" \
  && [[ "$(wc -l < "${CASE_DIR}/curl-argv.log")" -eq 1 ]]; then
  pass "oidc-401-refresh-error-fails"
else
  fail "oidc-401-refresh-error-fails" "rc=${CASE_RC}; $(cat "${CASE_ERR}")"
fi

# Real curl against a local HTTPS listener with a self-signed certificate
# (--cacert): the Bearer header arrives, a 401 fails with its message, and
# a 404 under --fail keeps curl's exit code 22. Skipped when openssl or the
# listener is unavailable.
REAL_DIR="${TMPDIR_ROOT}/real-curl"
mkdir -p "${REAL_DIR}"
real_skip=""
if ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  real_skip="openssl or curl not installed"
elif ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" -keyout "${REAL_DIR}/key.pem" \
  -out "${REAL_DIR}/cert.pem" >/dev/null 2>&1; then
  real_skip="could not create a self-signed certificate"
else
  python3 -I "${TLS_SERVER}" "${REAL_DIR}/cert.pem" "${REAL_DIR}/key.pem" \
    "${REAL_DIR}/port" "${REAL_DIR}/server.log" 2>"${REAL_DIR}/server.err" &
  REAL_PID=$!
  for _ in $(seq 1 50); do
    [[ -s "${REAL_DIR}/port" ]] && break
    kill -0 "${REAL_PID}" 2>/dev/null || break
    sleep 0.1
  done
  [[ -s "${REAL_DIR}/port" ]] || real_skip="the TLS listener did not start"
fi
if [[ -n "${real_skip}" ]]; then
  echo "SKIP: oidc-real-curl (${real_skip})"
else
  REAL_GW="https://localhost:$(cat "${REAL_DIR}/port")/ex/jira/cloud-1"
  # myself; denied, then its refresh; missing.
  printf 'ok %s\nok %s\nok %s\nok %s\n' "${OIDC_TOKEN}" "${OIDC_TOKEN}" "${OIDC_TOKEN_2}" "${OIDC_TOKEN}" \
    > "${REAL_DIR}/answers"
  REAL_RC=0
  env -u FULLSEND_JIRA_TOKEN -u FULLSEND_JIRA_CLIENT_ID -u FULLSEND_JIRA_CLIENT_SECRET -u JIRA_TOKEN \
    JIRA_API_URL="${REAL_GW}" CACERT="${REAL_DIR}/cert.pem" \
    python3 -I "${BROKER}" "${REAL_DIR}/broker.log" "${REAL_DIR}/answers" -- \
    bash -c "set -uo pipefail; source '${LIB}'
      jira_auth_select '' FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET || exit 1
      body=\"\$(jira_auth_curl '' '' --fail --silent --show-error --cacert \"\${CACERT}\" \"\${JIRA_API_URL}/rest/api/3/myself\")\"; echo \"ok-rc=\$? body=\${body}\"
      jira_auth_curl '' '' --fail --silent --show-error --cacert \"\${CACERT}\" \"\${JIRA_API_URL}/rest/api/3/denied\" >/dev/null; echo \"denied-rc=\$?\"
      jira_auth_curl '' '' --fail --silent --show-error --cacert \"\${CACERT}\" \"\${JIRA_API_URL}/rest/api/3/missing\" >/dev/null; echo \"missing-rc=\$?\"
    " > "${REAL_DIR}/out" 2> "${REAL_DIR}/err" || REAL_RC=$?
  kill "${REAL_PID}" 2>/dev/null || true
  wait "${REAL_PID}" 2>/dev/null || true
  if [[ "${REAL_RC}" -eq 0 ]] && grep -qx 'ok-rc=0 body={"ok":true}' "${REAL_DIR}/out" \
    && grep -qxF "/ex/jira/cloud-1/rest/api/3/myself Bearer ${OIDC_TOKEN}" "${REAL_DIR}/server.log"; then
    pass "oidc-real-curl-sends-bearer"
  else
    fail "oidc-real-curl-sends-bearer" "rc=${REAL_RC}; $(cat "${REAL_DIR}/out" "${REAL_DIR}/err" "${REAL_DIR}/server.log" 2>/dev/null)"
  fi
  if grep -qx "denied-rc=1" "${REAL_DIR}/out" \
    && grep -qF "OIDC token refused or expired" "${REAL_DIR}/err" \
    && [[ "$(grep '/denied ' "${REAL_DIR}/server.log" | tr '\n' ' ')" \
      == "/ex/jira/cloud-1/rest/api/3/denied Bearer ${OIDC_TOKEN} /ex/jira/cloud-1/rest/api/3/denied Bearer ${OIDC_TOKEN_2} " ]]; then
    pass "oidc-real-curl-401-refreshes-once-then-fails"
  else
    fail "oidc-real-curl-401-refreshes-once-then-fails" "$(cat "${REAL_DIR}/out" "${REAL_DIR}/err" 2>/dev/null)"
  fi
  if grep -qx "missing-rc=22" "${REAL_DIR}/out"; then
    pass "oidc-real-curl-keeps-fail-exit-code"
  else
    fail "oidc-real-curl-keeps-fail-exit-code" "$(cat "${REAL_DIR}/out" 2>/dev/null)"
  fi
  if ! grep -qF "${OIDC_TOKEN}" "${REAL_DIR}/out" "${REAL_DIR}/err"; then
    pass "oidc-real-curl-token-hidden"
  else
    fail "oidc-real-curl-token-hidden" "OIDC token in output"
  fi
fi

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
