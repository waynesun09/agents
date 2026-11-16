#!/usr/bin/env bash
# pre-triage.sh — Strip triage-related labels before the agent runs.
#
# Runs on the host via the harness pre_script mechanism. Ensures every
# triage invocation starts from a clean label baseline, preventing
# mutual-exclusion violations (Story 2, #125).
#
# Required env vars:
#   ISSUE_URL        — HTML URL of the issue
#   FULLSEND_TRACKER — "github", "gitlab", or "jira" (falls back to FULLSEND_FORGE)
#
# IMPORTANT: Uses the labels API directly (DELETE /issues/{number}/labels/{name})
# instead of gh issue edit. gh issue edit uses PATCH /issues/{number}
# which fires issues.edited, re-triggering the triage dispatch in the shim workflow.

set -euo pipefail

# Triage has no Jira oidc support yet. A token broker fd is closed and its
# variable unset first. Next to a static Jira credential it is a conflict on
# every tracker; on a Jira run it is refused before any label change.
# Without one, oidc mode leaves no Jira credential, and the Jira library
# refuses that (with a message covering oidc mode) before any label change
# too. The config is not parsed here: a plain-text match on "auth: oidc"
# would also hit other blocks, such as inference.gateway.auth.
_jira_triage_oidc=""
if [[ -n "${FULLSEND_JIRA_OIDC_TOKEN_FD:-}" ]]; then
  # Keep the credential checks off the trace.
  _jira_xtrace_was_on=0; [[ $- == *x* ]] && _jira_xtrace_was_on=1; set +x
  _jira_broker_fd="${FULLSEND_JIRA_OIDC_TOKEN_FD//[[:space:]]/}"
  if [[ "${_jira_broker_fd}" =~ ^[0-9]{1,4}$ ]] && (( 10#${_jira_broker_fd} >= 3 )); then
    eval "exec $((10#${_jira_broker_fd}))<&-"
  fi
  unset FULLSEND_JIRA_OIDC_TOKEN_FD
  if [[ -n "${_jira_broker_fd}" ]]; then
    _jira_triage_oidc=1
    _jira_static="${JIRA_TOKEN:-}${FULLSEND_JIRA_TOKEN:-}${FULLSEND_JIRA_CLIENT_ID:-}${FULLSEND_JIRA_CLIENT_SECRET:-}"
    _jira_static="${_jira_static//[[:space:]]/}"
    if [[ -n "${_jira_static}" ]]; then
      echo "ERROR: set either FULLSEND_JIRA_OIDC_TOKEN_FD (tracker.jira.auth: oidc) or FULLSEND_JIRA_TOKEN (JIRA_TOKEN) or FULLSEND_JIRA_CLIENT_ID and FULLSEND_JIRA_CLIENT_SECRET, not more than one" >&2
      exit 1
    fi
  fi
  unset _jira_broker_fd _jira_static
  (( _jira_xtrace_was_on )) && set -x
  unset _jira_xtrace_was_on
fi
if [[ "${FULLSEND_WORK_ITEM_SOURCE:-}" == "jira" || "${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}" == "jira" ]]; then
  if [[ -n "${_jira_triage_oidc}" ]]; then
    echo "ERROR: pre-triage: Jira triage in oidc mode needs fullsend core support that is not available yet; no Jira changes were made" >&2
    exit 1
  fi
fi
unset _jira_triage_oidc

: "${ISSUE_URL:?ISSUE_URL must be set}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
: "${FULLSEND_TRACKER:?FULLSEND_TRACKER must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/triage-ops.lib.sh
source "${SCRIPT_DIR}/lib/triage-ops.lib.sh"

tracker_validate_issue_url
echo "::notice::🔗 Triage target: $(_gha_sanitize "${ISSUE_URL}")"
tracker_parse_issue_url

echo "Resetting triage labels on ${REPO}#${ISSUE_NUMBER}"

TRIAGE_LABELS=(needs-info ready-to-code duplicate feature question not-planned completed pr-open)

tracker_strip_labels "${TRIAGE_LABELS[@]}"
tracker_verify_labels_stripped "${TRIAGE_LABELS[@]}"

echo "Label reset complete."
