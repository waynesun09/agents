#!/usr/bin/env bash
# shellcheck shell=bash
# jira-auth.lib.sh — Jira credential-mode selection for host-side scripts.
#
# Shared by the Jira triage and scribe ops libraries and post-code.sh, and
# bundled into each script that sources it. Four credential modes
# (fullsend#9007, agents#1926):
#
#   token + email      — bot user: Basic auth with email:token
#   token only         — service account: Bearer auth with the token
#   client credentials — service account OAuth 2.0 client credentials
#                        (FULLSEND_JIRA_CLIENT_ID and
#                        FULLSEND_JIRA_CLIENT_SECRET): REST calls use a
#                        Bearer access token minted on the runner, and the
#                        fullsend CLI gets the client credentials and mints
#                        for itself
#   oidc               — tracker.jira.auth: oidc. fullsend run passes
#                        the script one end of a socket, a token broker,
#                        and its number in FULLSEND_JIRA_OIDC_TOKEN_FD.
#                        Each REST call asks it for a token ("token\n",
#                        answered "ok <jwt>\n" or "err <code>\n"), sends
#                        the token as Bearer to JIRA_API_URL, a
#                        self-hosted Jira gateway, never to an Atlassian
#                        host, and forgets it. The fullsend CLI inherits
#                        the fd and asks for itself. After a 401 a call
#                        asks once more with "refresh\n" and retries one
#                        time; a second refusal fails the call, and no
#                        other credential is ever tried.
#                        Requests are sequential: never ask on the same
#                        fd from two processes at once. Children that run
#                        agent or third-party code must not hold the fd:
#                        see jira_auth_drop_oidc_fd.
#
# An email that is empty or only whitespace counts as absent. A harness
# that maps an unset FULLSEND_JIRA_EMAIL to JIRA_USER_EMAIL yields an empty
# string, and that must select Bearer, never an empty-user Basic header.
#
# Every helper takes the token and email as arguments, so callers that
# withhold the credentials from their environment can pass saved copies.
# jira_auth_select chooses the mode once; until it is called, the helpers
# use the token and email they are given (the token modes).
#
# The client secret is kept in shell variables only. It never reaches a
# command line, a file, the output, or an xtrace line: jira_auth_select
# takes the names of the client ID and secret variables and reads them
# with xtrace off, jq builds the token request body from its environment
# and sends it to curl on stdin, and a failed request reports its HTTP
# status, never the response body.

[[ -n "${JIRA_AUTH_SH_LOADED:-}" ]] && return 0
JIRA_AUTH_SH_LOADED=1

# Selected mode: "token", "client", "oidc", or "none". Empty until
# jira_auth_select.
JIRA_AUTH_MODE=""
_JIRA_AUTH_CLIENT_ID=""
_JIRA_AUTH_CLIENT_SECRET=""
_JIRA_AUTH_ACCESS_TOKEN=""
_JIRA_AUTH_EXPIRES_AT=0
# The token broker's fd number in OIDC mode. A number, not the token.
_JIRA_AUTH_OIDC_FD=""
# Seconds to wait for the broker's answer to one request.
_JIRA_AUTH_OIDC_TIMEOUT=20

# Print the argument with surrounding whitespace removed.
_jira_auth_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# Print the email with surrounding whitespace removed. Empty output means
# no email, which selects Bearer auth.
#
# Usage: jira_auth_email <email>
jira_auth_email() {
  local email="$1"
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  printf '%s' "${email}"
}

# Select the credential mode and set JIRA_AUTH_MODE:
#   token  — a token is set (the email decides Basic or Bearer per call)
#   client — the client ID and secret are both set and no token is
#   oidc   — the token broker fd is set, and no token or client variable
#            is
#   none   — nothing is set
# The client ID and secret, and the broker fd number, are passed as
# variable names, never values, so a traced call line shows only the
# names; they are read with xtrace off. The fd variable defaults to
# FULLSEND_JIRA_OIDC_TOKEN_FD. Fails, naming the variables but never their
# values, when more than one mode is set (the broker fd also counts
# FULLSEND_JIRA_TOKEN from the environment), only one client variable is,
# the fd is not a number from 3 up, or a name is not a shell identifier.
# Values are trimmed, so one that is only whitespace counts as unset.
# Whether the fd is open is checked on each call.
#
# Usage: jira_auth_select <token> <client-id-var> <client-secret-var>
#          [<oidc-token-fd-var>]
jira_auth_select() {
  local _jas_xtrace=0 _jas_rc=0
  if [[ $- == *x* ]]; then
    _jas_xtrace=1
    set +x
  fi
  _jira_auth_select_now "$@" || _jas_rc=$?
  if [[ "${_jas_xtrace}" -eq 1 ]]; then
    set -x
  fi
  return "${_jas_rc}"
}

# Locals use a _jas_ prefix, and such names are refused, so the indirect
# reads see the caller's variables, not these.
_jira_auth_select_now() {
  local _jas_oidc_var="${4:-FULLSEND_JIRA_OIDC_TOKEN_FD}"
  local _jas_name
  for _jas_name in "$2" "$3"; do
    if [[ ! "${_jas_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || "${_jas_name}" == _jas_* ]]; then
      echo "ERROR: jira_auth_select needs the names of the client ID and secret variables" >&2
      return 1
    fi
  done
  if [[ ! "${_jas_oidc_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || "${_jas_oidc_var}" == _jas_* ]]; then
    echo "ERROR: jira_auth_select needs the name of the OIDC token fd variable" >&2
    return 1
  fi
  local _jas_token _jas_id _jas_secret _jas_oidc_fd
  _jas_token="$(_jira_auth_trim "$1")"
  _jas_id="$(_jira_auth_trim "${!2:-}")"
  _jas_secret="$(_jira_auth_trim "${!3:-}")"
  _jas_oidc_fd="$(_jira_auth_trim "${!_jas_oidc_var:-}")"
  if [[ -n "${_jas_oidc_fd}" ]]; then
    if [[ -n "${_jas_token}" || -n "$(_jira_auth_trim "${FULLSEND_JIRA_TOKEN:-}")" ]]; then
      echo "ERROR: set either FULLSEND_JIRA_OIDC_TOKEN_FD (tracker.jira.auth: oidc) or FULLSEND_JIRA_TOKEN (JIRA_TOKEN), not both" >&2
      return 1
    fi
    if [[ -n "${_jas_id}" || -n "${_jas_secret}" ]]; then
      echo "ERROR: set either FULLSEND_JIRA_OIDC_TOKEN_FD (tracker.jira.auth: oidc) or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, not both" >&2
      return 1
    fi
    if [[ ! "${_jas_oidc_fd}" =~ ^[0-9]{1,4}$ ]] || (( 10#${_jas_oidc_fd} < 3 )); then
      echo "ERROR: FULLSEND_JIRA_OIDC_TOKEN_FD must be a file descriptor number from 3 up" >&2
      return 1
    fi
  fi
  if [[ -n "${_jas_token}" && ( -n "${_jas_id}" || -n "${_jas_secret}" ) ]]; then
    echo "ERROR: set either FULLSEND_JIRA_TOKEN (JIRA_TOKEN) or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, not both" >&2
    return 1
  fi
  if [[ -n "${_jas_id}" && -z "${_jas_secret}" ]] || [[ -z "${_jas_id}" && -n "${_jas_secret}" ]]; then
    echo "ERROR: FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET must be set together" >&2
    return 1
  fi
  _JIRA_AUTH_ACCESS_TOKEN=""
  _JIRA_AUTH_EXPIRES_AT=0
  _JIRA_AUTH_OIDC_FD=""
  if [[ -n "${_jas_oidc_fd}" ]]; then
    JIRA_AUTH_MODE="oidc"
    _JIRA_AUTH_OIDC_FD="$((10#${_jas_oidc_fd}))"
  elif [[ -n "${_jas_token}" ]]; then
    JIRA_AUTH_MODE="token"
  elif [[ -n "${_jas_id}" ]]; then
    JIRA_AUTH_MODE="client"
    _JIRA_AUTH_CLIENT_ID="${_jas_id}"
    _JIRA_AUTH_CLIENT_SECRET="${_jas_secret}"
  else
    JIRA_AUTH_MODE="none"
  fi
}

# In client-credentials mode, fail unless JIRA_API_URL is set. A minted
# access token works only through the Atlassian API gateway
# (https://api.atlassian.com/ex/jira/<cloudId>); the site URL in
# JIRA_BASE_URL rejects it, so there is no fallback.
#
#
# In OIDC mode, fail unless JIRA_API_URL is an https URL whose host is not
# Atlassian's (see _jira_auth_check_gateway).
#
# Usage: jira_auth_require_api_url
jira_auth_require_api_url() {
  if [[ "${JIRA_AUTH_MODE}" == "oidc" ]]; then
    _jira_auth_check_gateway
    return
  fi
  if [[ "${JIRA_AUTH_MODE}" == "client" && -z "${JIRA_API_URL:-}" ]]; then
    echo "ERROR: JIRA_API_URL (the Atlassian API gateway URL) must be set when FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET are used; JIRA_BASE_URL does not accept their access tokens" >&2
    return 1
  fi
}

# The OIDC token is meant for the self-hosted Jira gateway only (its aud),
# and the CI token must never reach Atlassian. Fail unless JIRA_API_URL is
# set and is https, its authority has no user info, percent-encoding or
# backslash, its port (if any) is digits, its host matches fullsend's rule
# for a lowercase DNS name, and that host is not atlassian.com,
# atlassian.net or a subdomain of either. Prints no URL.
_jira_auth_check_gateway() {
  local url="${JIRA_API_URL:-}"
  if [[ -z "${url}" ]]; then
    echo "ERROR: JIRA_API_URL (the Jira gateway URL from tracker.jira.api_url) must be set when FULLSEND_JIRA_OIDC_TOKEN_FD is used" >&2
    return 1
  fi
  if [[ "${url}" != https://* ]]; then
    echo "ERROR: JIRA_API_URL must start with https:// when FULLSEND_JIRA_OIDC_TOKEN_FD is used" >&2
    return 1
  fi
  local authority="${url#https://}"
  authority="${authority%%[/?#]*}"
  case "${authority}" in
    *[@%\\]*)
      echo "ERROR: JIRA_API_URL must not carry user info, percent-encoding or a backslash in its host" >&2
      return 1
      ;;
  esac
  local host="${authority}"
  if [[ "${host}" == *:* ]]; then
    if [[ ! "${host##*:}" =~ ^[0-9]{1,5}$ ]]; then
      echo "ERROR: JIRA_API_URL has an invalid port" >&2
      return 1
    fi
    host="${host%:*}"
  fi
  if [[ ! "${host}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
    echo "ERROR: JIRA_API_URL host must be a lowercase DNS name" >&2
    return 1
  fi
  case "${host}" in
    atlassian.com | *.atlassian.com | atlassian.net | *.atlassian.net)
      echo "ERROR: JIRA_API_URL points at an Atlassian host; the OIDC token is sent only to a self-hosted Jira gateway" >&2
      return 1
      ;;
  esac
}

# Fail unless the token broker fd is open in this process.
_jira_auth_oidc_fd_open() {
  if [[ -z "${_JIRA_AUTH_OIDC_FD}" ]] || ! { : >&"${_JIRA_AUTH_OIDC_FD}"; } 2>/dev/null; then
    echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker is not open in this process" >&2
    return 1
  fi
}

# Close the token broker fd and unset FULLSEND_JIRA_OIDC_TOKEN_FD in the
# current shell. Children that run agent-controlled or third-party code
# (git and its hooks, pre-commit and its installs, gitleaks, gh) must not
# hold the fd, so call this before starting them; to keep the fd for later
# Jira calls, call it in a subshell: ( jira_auth_drop_oidc_fd; gh ... ).
# The close goes through eval because bash before 4.1 has no {var}<&- form
# for a fd number held in a variable. A no-op when no fd is set.
jira_auth_drop_oidc_fd() {
  local fd
  for fd in "${_JIRA_AUTH_OIDC_FD:-}" "${FULLSEND_JIRA_OIDC_TOKEN_FD:-}"; do
    if [[ "${fd}" =~ ^[0-9]{1,4}$ ]] && (( 10#${fd} >= 3 )); then
      eval "exec $((10#${fd}))<&-"
    fi
  done
  unset FULLSEND_JIRA_OIDC_TOKEN_FD
  _JIRA_AUTH_OIDC_FD=""
}

# Ask the broker for one token and store it in the caller's local "tok".
# Called with xtrace off, by _jira_auth_oidc_curl only. Sends the request
# ("token", or "refresh" to force a refetch, which the broker may answer
# with the current token),
# reads one line within _JIRA_AUTH_OIDC_TIMEOUT seconds, and requires
# "ok <jwt>". The answer line is never printed.
_jira_auth_oidc_fetch() {
  _jira_auth_oidc_fd_open || return 1
  local fd="${_JIRA_AUTH_OIDC_FD}" line="" rc=0 code
  if ! { printf '%s\n' "$1" >&"${fd}"; } 2>/dev/null; then
    echo "ERROR: could not send a request to the FULLSEND_JIRA_OIDC_TOKEN_FD token broker" >&2
    return 1
  fi
  IFS= read -r -t "${_JIRA_AUTH_OIDC_TIMEOUT}" line <&"${fd}" || rc=$?
  if (( rc > 128 )); then
    line=""
    echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker did not answer within ${_JIRA_AUTH_OIDC_TIMEOUT}s" >&2
    return 1
  fi
  if (( rc != 0 )); then
    line=""
    echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker closed without an answer" >&2
    return 1
  fi
  case "${line}" in
    "ok "*)
      tok="${line#ok }"
      line=""
      ;;
    "err "*)
      code="${line#err }"
      line=""
      if [[ -z "${code}" || "${code}" == *[!a-z_]* || ${#code} -gt 32 ]]; then
        echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker sent a malformed error" >&2
      else
        echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker could not supply a token (err ${code})" >&2
      fi
      return 1
      ;;
    *)
      line=""
      echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker sent an unexpected answer" >&2
      return 1
      ;;
  esac
  # A JWT is three non-empty base64url parts. Checking the shape also keeps
  # the value safe inside the curl config line that carries it. Pattern
  # expansion, not =~, so BASH_REMATCH never holds the token.
  if [[ -z "${tok}" || -n "${tok//[A-Za-z0-9_.-]/}" || "${tok//[^.]/}" != ".." \
    || "${tok}" == .* || "${tok}" == *. || "${tok}" == *..* ]]; then
    tok=""
    echo "ERROR: the FULLSEND_JIRA_OIDC_TOKEN_FD token broker did not send a JWT" >&2
    return 1
  fi
}

# Run curl against the gateway with a broker token as Bearer. Called by
# jira_auth_curl with xtrace off. Refuses, before asking the broker, a URL
# argument outside JIRA_API_URL and curl options that would print the
# request headers, read another config, write the headers elsewhere,
# follow redirects or change the default scheme. The token is fetched for
# this call only, into a local cleared after curl. curl runs without the
# broker fd. The Authorization header goes in a curl config read from a
# process substitution (printf is a builtin), so the token is in no argv;
# curl -q ignores curl config files and --proto =https pins the scheme.
# On a 401 the call asks the broker to refresh and is sent once more with
# the answer; a second 401 fails with its own message. Each attempt's
# output goes to a private file and only the last attempt's reaches the
# caller, so a caller that parses curl's output sees one response. A body
# read from stdin is refused, since a retry could not send it again.
_jira_auth_oidc_curl() {
  _jira_auth_check_gateway || return 1
  local api="${JIRA_API_URL}"
  while [[ "${api}" == */ ]]; do
    api="${api%/}"
  done
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -v | --verbose | --trace | --trace-* | --stderr | -K | --config | -D | --dump-header \
        | -L | --location | --location-* | --proto-default)
        echo "ERROR: curl option ${arg} is not allowed with the OIDC token" >&2
        return 1
        ;;
    esac
    if [[ "${arg}" =~ ^-[A-Za-z]+$ && "${arg}" == *[vKDL]* ]]; then
      echo "ERROR: curl option ${arg} is not allowed with the OIDC token" >&2
      return 1
    fi
    if [[ "${arg}" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// && "${arg}" != "${api}/"* ]]; then
      echo "ERROR: refusing to send the OIDC token to a URL outside JIRA_API_URL" >&2
      return 1
    fi
    if [[ "${arg}" == "@-" ]]; then
      echo "ERROR: a request body from stdin is not allowed with the OIDC token" >&2
      return 1
    fi
  done
  local tok="" request="token" attempt rc hdr out code
  for attempt in 1 2; do
    _jira_auth_oidc_fetch "${request}" || {
      tok=""
      return 1
    }
    rc=0
    hdr=""
    if ! hdr="$(mktemp)" || ! out="$(mktemp)"; then
      tok=""
      rm -f "${hdr}"
      return 1
    fi
    (
      eval "exec ${_JIRA_AUTH_OIDC_FD}<&-"
      exec curl -q --proto =https \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "${tok}") \
        --dump-header "${hdr}" "$@"
    ) > "${out}" || rc=$?
    tok=""
    code="$(sed -n 's|^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*|\1|p' "${hdr}" | tail -n 1)"
    rm -f "${hdr}"
    if [[ "${code}" == "401" && "${attempt}" -eq 1 ]]; then
      rm -f "${out}"
      echo "WARNING: the Jira gateway answered HTTP 401; asking the token broker to refresh and retrying once" >&2
      request="refresh"
      continue
    fi
    cat "${out}"
    rm -f "${out}"
    if [[ "${code}" == "401" ]]; then
      echo "ERROR: the Jira gateway answered HTTP 401 again after a refresh: OIDC token refused or expired. Not retrying with another credential." >&2
      return 1
    fi
    return "${rc}"
  done
}

# In client-credentials mode, make sure a usable access token is held:
# mint one when there is none or it expires within 5 minutes. A no-op in
# the other modes. The token is kept in a shell variable only and masked
# before anything else is printed. Mint once in the script's own shell,
# with stdout not redirected, so the mask line reaches the log and later
# calls, including those in command substitutions, reuse the token.
#
# Usage: jira_auth_mint
jira_auth_mint() {
  [[ "${JIRA_AUTH_MODE}" == "client" ]] || return 0
  local now
  now="$(date +%s)"
  if [[ -n "${_JIRA_AUTH_ACCESS_TOKEN}" ]] && (( now < _JIRA_AUTH_EXPIRES_AT - 300 )); then
    return 0
  fi
  local xtrace=0 rc=0
  if [[ $- == *x* ]]; then
    xtrace=1
    set +x
  fi
  _jira_auth_mint_now "${now}" || rc=$?
  if [[ "${xtrace}" -eq 1 ]]; then
    set -x
  fi
  return "${rc}"
}

# Request an access token the way fullsend does
# (internal/forge/jira/oauth.go). Called by jira_auth_mint with xtrace off.
# jq builds the body from the trimmed ID and secret in its environment and
# curl reads it on stdin; curl -q ignores curl config files.
_jira_auth_mint_now() {
  local now="$1"
  local raw rc=0
  raw="$(_JIRA_AUTH_ID="${_JIRA_AUTH_CLIENT_ID}" \
    _JIRA_AUTH_SECRET="${_JIRA_AUTH_CLIENT_SECRET}" \
    jq -cn '{grant_type: "client_credentials", client_id: env._JIRA_AUTH_ID, client_secret: env._JIRA_AUTH_SECRET}' \
    | curl -q --proto =https --silent --connect-timeout 10 --max-time 30 \
      --header "Content-Type: application/json" \
      --data @- \
      --write-out '\n%{http_code}' \
      "https://auth.atlassian.com/oauth/token" 2>/dev/null)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: Jira OAuth token request failed (curl exit ${rc})" >&2
    return 1
  fi
  local http_code="${raw##*$'\n'}"
  local body="${raw%$'\n'*}"
  [[ "${http_code}" =~ ^[0-9]{3}$ ]] || http_code="unknown"
  if [[ "${http_code}" != 2?? ]]; then
    echo "ERROR: Jira OAuth token request failed (HTTP ${http_code})" >&2
    return 1
  fi
  local token expires_in
  token="$(printf '%s' "${body}" | jq -r '.access_token // empty' 2>/dev/null)" || token=""
  expires_in="$(printf '%s' "${body}" | jq -r '.expires_in // empty' 2>/dev/null)" || expires_in=""
  # Atlassian access tokens are JWTs. Anything outside this charset could
  # break or inject into the ::add-mask:: line, so it is refused unprinted.
  if [[ ! "${token}" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "ERROR: Jira OAuth token response has no usable access_token" >&2
    return 1
  fi
  # In the script's own shell the mask goes to stdout. In a subshell, such
  # as a command substitution, stdout may be captured, so it goes to the
  # main shell's current stdout through /proc when that is a pipe or a
  # terminal (the runner log), else to stderr. A file or /dev/null there
  # means the caller redirected stdout around the call.
  local main_out="/proc/$$/fd/1"
  if (( BASH_SUBSHELL == 0 )); then
    printf '::add-mask::%s\n' "${token}"
  elif [[ -w "${main_out}" ]] && [[ -p "${main_out}" || -c "${main_out}" ]] \
    && ! [[ "${main_out}" -ef /dev/null ]]; then
    printf '::add-mask::%s\n' "${token}" >> "${main_out}"
  else
    printf '::add-mask::%s\n' "${token}" >&2
  fi
  [[ "${expires_in}" =~ ^[0-9]+$ ]] || expires_in=3600
  _JIRA_AUTH_ACCESS_TOKEN="${token}"
  _JIRA_AUTH_EXPIRES_AT=$((now + expires_in))
}

# Run curl with the Authorization for the selected mode, followed by the
# caller's arguments. In client-credentials mode the token and email
# arguments are ignored and the minted access token is sent as Bearer. In
# OIDC mode they are ignored too, and a token from the broker goes to the
# gateway (see _jira_auth_oidc_curl). Otherwise fails without calling curl
# when the token is empty.
#
# Usage: jira_auth_curl <token> <email> [curl args...]
jira_auth_curl() {
  local token="$1"
  local email
  email="$(jira_auth_email "$2")"
  shift 2
  if [[ "${JIRA_AUTH_MODE}" == "oidc" ]]; then
    local xtrace=0 rc=0
    if [[ $- == *x* ]]; then
      xtrace=1
      set +x
    fi
    _jira_auth_oidc_curl "$@" || rc=$?
    if [[ "${xtrace}" -eq 1 ]]; then
      set -x
    fi
    return "${rc}"
  fi
  if [[ "${JIRA_AUTH_MODE}" == "client" ]]; then
    jira_auth_mint || return 1
    curl --oauth2-bearer "${_JIRA_AUTH_ACCESS_TOKEN}" "$@"
    return
  fi
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    curl --user "${email}:${token}" "$@"
  else
    curl --oauth2-bearer "${token}" "$@"
  fi
}

# Run the fullsend CLI with the Jira credentials it reads from its
# environment: FULLSEND_JIRA_TOKEN always, FULLSEND_JIRA_EMAIL only for a
# bot user. In Bearer mode an inherited FULLSEND_JIRA_EMAIL is removed, so
# the CLI cannot pick Basic auth. In client-credentials mode the CLI gets
# FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, with
# FULLSEND_JIRA_TOKEN and FULLSEND_JIRA_EMAIL removed, and mints for
# itself, with xtrace off. In OIDC mode the CLI inherits the broker fd and
# gets its number in FULLSEND_JIRA_OIDC_TOKEN_FD, with the token, email
# and client variables removed, once the fd is open and JIRA_API_URL passes
# the same gateway check as REST calls; it asks the broker itself and
# reads the gateway from tracker.jira.api_url. The values go through the
# environment, never the command line.
#
# Usage: jira_auth_fullsend <fullsend-bin> <token> <email> [cli args...]
jira_auth_fullsend() {
  local bin="$1"
  local token="$2"
  local email
  email="$(jira_auth_email "$3")"
  shift 3
  if [[ "${JIRA_AUTH_MODE}" == "oidc" ]]; then
    local xtrace=0 rc=0
    if [[ $- == *x* ]]; then
      xtrace=1
      set +x
    fi
    if _jira_auth_check_gateway && _jira_auth_oidc_fd_open; then
      (
        unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL FULLSEND_JIRA_CLIENT_ID FULLSEND_JIRA_CLIENT_SECRET
        FULLSEND_JIRA_OIDC_TOKEN_FD="${_JIRA_AUTH_OIDC_FD}" "${bin}" "$@"
      ) || rc=$?
    else
      rc=1
    fi
    if [[ "${xtrace}" -eq 1 ]]; then
      set -x
    fi
    return "${rc}"
  fi
  if [[ "${JIRA_AUTH_MODE}" == "client" ]]; then
    local xtrace=0 rc=0
    if [[ $- == *x* ]]; then
      xtrace=1
      set +x
    fi
    (
      unset FULLSEND_JIRA_TOKEN FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_CLIENT_ID="${_JIRA_AUTH_CLIENT_ID}" \
        FULLSEND_JIRA_CLIENT_SECRET="${_JIRA_AUTH_CLIENT_SECRET}" "${bin}" "$@"
    ) || rc=$?
    if [[ "${xtrace}" -eq 1 ]]; then
      set -x
    fi
    return "${rc}"
  fi
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    FULLSEND_JIRA_TOKEN="${token}" FULLSEND_JIRA_EMAIL="${email}" "${bin}" "$@"
  else
    (
      unset FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_TOKEN="${token}" "${bin}" "$@"
    )
  fi
}
