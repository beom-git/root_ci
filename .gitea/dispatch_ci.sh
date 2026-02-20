#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Root CI Dispatcher
# =============================================================================
# Purpose:
#   Dispatch CI execution based on commit-message keywords.
#
# Inputs:
#   - Environment variables: CI_PROVIDER, COMMIT_MESSAGE, GIT_SHA, GIT_REF
#   - Alias maps:
#       .gitea/component_aliases.yaml
#       .gitea/stage_aliases.yaml
#
# Behavior Summary:
#   1) Resolve target component (alias-first, then CI[ID] fallback).
#   2) Resolve stage plan.
#      - If 'all' is matched, run full ordered stages.
#      - If no stage keyword is matched, fail.
#   3) Execute via provider backend:
#      - gitea: run component local scripts
#      - jenkins: trigger Jenkins buildWithParameters API
#
# Stage Order (fixed):
#   lint -> cdc -> vclp -> synth -> formal
#
# Exit Code Contract:
#   2: missing alias map file
#   3: ambiguous component match
#   4: component path missing in map
#   5: stage keyword not matched
#   6: unsupported stage in execution
#   7: unknown CI provider
# =============================================================================

# [Step 1] Resolve runtime paths and default inputs.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMP_MAP="${ROOT_DIR}/.gitea/component_aliases.yaml"
STAGE_MAP="${ROOT_DIR}/.gitea/stage_aliases.yaml"

# CI_PROVIDER is root-owned and should not be overridden by component config.
CI_PROVIDER="${CI_PROVIDER:-gitea}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-$(git log -1 --pretty=%B 2>/dev/null || true)}"
GIT_SHA="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
GIT_REF="${GIT_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"

msg_lc="$(printf '%s' "$COMMIT_MESSAGE" | tr '[:upper:]' '[:lower:]')"

echo "[CI] provider=${CI_PROVIDER}"
echo "[CI] message=${COMMIT_MESSAGE}"

# [Step 2] Validate required alias map files.
if [[ ! -f "$COMP_MAP" || ! -f "$STAGE_MAP" ]]; then
  echo "[CI-ERROR] missing alias file(s): $COMP_MAP or $STAGE_MAP" >&2
  exit 2
fi

# [Step 3] Parse alias map files.
# Schema assumptions:
#   component_aliases.yaml:
#     components:
#       CPU:
#         path: "..."
#         aliases: ["cpu", ...]
#   stage_aliases.yaml:
#     stages:
#       lint: ["lint", ...]
component_ids=()
declare -A comp_path
declare -A comp_aliases
declare -A stage_aliases

current_comp=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  if [[ "$line" =~ ^[[:space:]]{2}([A-Z0-9_]+):[[:space:]]*$ ]]; then
    current_comp="${BASH_REMATCH[1]}"
    component_ids+=("$current_comp")
    continue
  fi

  if [[ -n "$current_comp" && "$line" =~ ^[[:space:]]{4}path:[[:space:]]*\"([^\"]+)\"[[:space:]]*$ ]]; then
    comp_path["$current_comp"]="${BASH_REMATCH[1]}"
    continue
  fi

  if [[ -n "$current_comp" && "$line" =~ ^[[:space:]]{4}aliases:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
    raw="${BASH_REMATCH[1]}"
    raw="${raw//\"/}"
    raw="${raw// /}"
    comp_aliases["$current_comp"]="$raw"
    continue
  fi
done < "$COMP_MAP"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  if [[ "$line" =~ ^[[:space:]]{2}([a-z0-9_]+):[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
    stg="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[2]}"
    raw="${raw//\"/}"
    raw="${raw// /}"
    stage_aliases["$stg"]="$raw"
  fi
done < "$STAGE_MAP"

# [Step 4] Resolve component target.
# Priority:
#   1) Alias token match in commit message
#   2) Fallback pattern CI[ID]
matches=()
for cid in "${component_ids[@]}"; do
  csv="${comp_aliases[$cid]:-}"
  IFS=',' read -r -a aliases <<< "$csv"
  for a in "${aliases[@]}"; do
    [[ -z "$a" ]] && continue
    if [[ "$msg_lc" =~ (^|[^a-z0-9_])${a}([^a-z0-9_]|$) ]]; then
      matches+=("$cid")
      break
    fi
  done
done

if [[ ${#matches[@]} -eq 0 ]]; then
  if [[ "$COMMIT_MESSAGE" =~ CI\[([A-Za-z0-9_]+)\] ]]; then
    id="${BASH_REMATCH[1]}"
    id_uc="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
    for cid in "${component_ids[@]}"; do
      if [[ "$cid" == "$id_uc" ]]; then
        matches+=("$cid")
        break
      fi
    done
  fi
fi

if [[ ${#matches[@]} -eq 0 ]]; then
  echo "[CI] no component matched; skip"
  exit 0
fi

if [[ ${#matches[@]} -gt 1 ]]; then
  echo "[CI-ERROR] ambiguous component match: ${matches[*]}" >&2
  exit 3
fi

COMP_ID="${matches[0]}"
COMP_PATH="${comp_path[$COMP_ID]}"
if [[ -z "${COMP_PATH:-}" ]]; then
  echo "[CI-ERROR] no path for component $COMP_ID" >&2
  exit 4
fi

# [Step 5] Resolve stage plan.
# Rules:
#   - If 'all' keyword exists, always run full ordered list.
#   - If no stage keyword exists, fail.
#   - If multiple stage keywords exist, execute matched stages in fixed order.
stage_priority=(lint cdc vclp synth formal)
stage_hits=()
all_hit=0

for stg in all "${stage_priority[@]}"; do
  csv="${stage_aliases[$stg]:-}"
  IFS=',' read -r -a aliases <<< "$csv"
  for a in "${aliases[@]}"; do
    [[ -z "$a" ]] && continue
    if [[ "$msg_lc" =~ (^|[^a-z0-9_])${a}([^a-z0-9_]|$) ]]; then
      if [[ "$stg" == "all" ]]; then
        all_hit=1
      else
        stage_hits+=("$stg")
      fi
      break
    fi
  done
done

stage_plan=()
if [[ $all_hit -eq 1 ]]; then
  stage_plan=("${stage_priority[@]}")
elif [[ ${#stage_hits[@]} -eq 0 ]]; then
  echo "[CI-ERROR] no stage keyword matched" >&2
  exit 5
else
  # Dedupe and preserve fixed priority.
  for stg in "${stage_priority[@]}"; do
    for hit in "${stage_hits[@]}"; do
      if [[ "$stg" == "$hit" ]]; then
        stage_plan+=("$stg")
        break
      fi
    done
  done
fi

echo "[CI] component=$COMP_ID path=$COMP_PATH stages=${stage_plan[*]}"

# [Step 6] Provider-specific execution backends.
run_local() {
  local script="$1"
  [[ -x "$script" ]] || chmod +x "$script" || true
  "$script"
}

run_stage_gitea() {
  local stg="$1"
  case "$stg" in
    lint)   run_local "$ROOT_DIR/$COMP_PATH/.sgenv/workflow/scripts/run_lint.sh" ;;
    cdc)    run_local "$ROOT_DIR/$COMP_PATH/.sgenv/workflow/scripts/run_cdc.sh" ;;
    vclp)   run_local "$ROOT_DIR/$COMP_PATH/.sgenv/workflow/scripts/run_vclp.sh" ;;
    synth)  run_local "$ROOT_DIR/$COMP_PATH/.sgenv/workflow/scripts/run_synth.sh" ;;
    formal) run_local "$ROOT_DIR/$COMP_PATH/.sgenv/workflow/scripts/run_formal.sh" ;;
    *)
      echo "[CI-ERROR] unsupported stage: $stg" >&2
      exit 6
      ;;
  esac
}

trigger_jenkins_stage() {
  local stg="$1"
  : "${JENKINS_URL:?missing JENKINS_URL}"
  : "${JENKINS_JOB:?missing JENKINS_JOB}"
  : "${JENKINS_USER:?missing JENKINS_USER}"
  : "${JENKINS_TOKEN:?missing JENKINS_TOKEN}"

  local crumb_header=""
  if crumb_json="$(curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null)"; then
    field="$(printf '%s' "$crumb_json" | sed -n 's/.*"crumbRequestField"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    crumb="$(printf '%s' "$crumb_json" | sed -n 's/.*"crumb"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [[ -n "$field" && -n "$crumb" ]] && crumb_header="$field: $crumb"
  fi

  api="$JENKINS_URL/job/$JENKINS_JOB/buildWithParameters"
  echo "[CI] trigger jenkins stage=$stg api=$api"

  curl_args=(
    -fsS
    -u "$JENKINS_USER:$JENKINS_TOKEN"
    -X POST
    "$api"
    --data-urlencode "component_id=$COMP_ID"
    --data-urlencode "component_path=$COMP_PATH"
    --data-urlencode "action=$stg"
    --data-urlencode "git_sha=$GIT_SHA"
    --data-urlencode "git_ref=$GIT_REF"
    --data-urlencode "commit_message=$COMMIT_MESSAGE"
  )
  [[ -n "$crumb_header" ]] && curl_args=(-H "$crumb_header" "${curl_args[@]}")

  curl "${curl_args[@]}"
}

if [[ "$CI_PROVIDER" == "gitea" ]]; then
  for stg in "${stage_plan[@]}"; do
    run_stage_gitea "$stg"
  done
elif [[ "$CI_PROVIDER" == "jenkins" ]]; then
  for stg in "${stage_plan[@]}"; do
    trigger_jenkins_stage "$stg"
  done
else
  echo "[CI-ERROR] unknown CI_PROVIDER: $CI_PROVIDER" >&2
  exit 7
fi
