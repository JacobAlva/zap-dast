#!/usr/bin/env bash
# run-docker.sh — authenticated ZAP DAST via the ZAP Docker image. App-specific
# values come from target.env. Runs the full plan (spider + active scan + report)
# with a fresh Bearer token injected via a Replacer rule.
# Output: reports/<context>-zap-report-<ts>.{html,json} + scan-summary + log.
#
# The ONLY host requirement is Docker. The image (Dockerfile.zap-chrome) carries
# Chromium + Selenium, so BOTH the token mint and the scan run inside it. A fresh
# bearer.txt is reused while still valid, otherwise re-minted automatically.
# Works the same on Windows/WSL, Linux, macOS, and CI.
#
# Usage:
#   export ZAP_AUTH_USER="<auth0-login-email>"
#   export ZAP_AUTH_PASS="<password>"
#   ./run-docker.sh
#
# Resource note: the AJAX-spider + active-scan run is heavy. On WSL2 give the VM
# >= 6 GB RAM (~/.wslconfig) or run on a CI runner — a starved VM can hang.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ZAP_AUTH_USER:?set ZAP_AUTH_USER}"
: "${ZAP_AUTH_PASS:?set ZAP_AUTH_PASS}"

# Clean up on exit/interrupt: the scan runs with `docker run -d`, so the container
# is owned by the Docker daemon, not this script — without this, Ctrl-C would kill
# the script but leave the container scanning in the background. This stops it and
# drops the temp plan. CURRENT_CID is set while a scan container is live, cleared
# after a normal finish so the trap doesn't double-stop.
CURRENT_CID=""; SESSION_PATH=""; SESSION_CPATH=""
cleanup() {   # normal exit / error: stop a still-running container, drop the temp plan
  trap - INT TERM EXIT                       # disarm so cleanup runs exactly once
  if [ -n "$CURRENT_CID" ]; then
    echo; echo "==> Cleaning up: stopping scan container ${CURRENT_CID:0:12}..."
    docker stop -t 5 "$CURRENT_CID" >/dev/null 2>&1
    docker rm -f "$CURRENT_CID" >/dev/null 2>&1
  fi
  [ -n "${WORKPLAN:-}" ] && rm -f "$HERE/$WORKPLAN" 2>/dev/null
  return 0
}
# Generate a report from the persisted (possibly partial) ZAP session. The scan runs
# with -newsession into a host-mounted dir, so its data survives even a hard stop; we
# load it and run a report-only plan (verified to work) into reports/.
report_from_session() {
  [ -f "${SESSION_PATH:-x}.session" ] || { echo "   (no saved session to report from)"; return 0; }
  echo "==> Generating a report from the scanned-so-far session..."
  local rop=".report-only-${TS}.yaml"
  cat > "$HERE/$rop" <<YAML
env:
  contexts:
    - name: "partial"
      urls: [ "${APP_URL}" ]
  parameters:
    progressToStdout: true
jobs:
  - type: report
    parameters:
      template: traditional-html
      reportDir: /zap/wrk/reports
      reportFile: ${REPORT_NAME}-${TS}.html
      reportTitle: "${CONTEXT_NAME} DAST — PARTIAL (interrupted)"
  - type: report
    parameters:
      template: traditional-json
      reportDir: /zap/wrk/reports
      reportFile: ${REPORT_NAME}-${TS}.json
YAML
  docker run --rm -v "$HERE":/zap/wrk:rw "$IMAGE" \
    zap.sh -cmd -session "$SESSION_CPATH" -autorun "/zap/wrk/$rop" >>"${LOG:-/dev/null}" 2>&1
  rm -f "$HERE/$rop"
  if [ -f "$HERE/reports/${REPORT_NAME}-${TS}.html" ]; then
    echo "   Partial report: reports/${REPORT_NAME}-${TS}.html (+ .json)"
  else
    echo "   Report generation failed; the raw session is kept at ${SESSION_PATH}.session"
  fi
}
# Ctrl-C / TERM: stop the scan (its session is already on disk) and let the user pick
# what to keep. Non-interactive (no tty) defaults to generating the partial report.
on_interrupt() {
  trap - INT TERM EXIT
  set +e                                     # never let cleanup abort the handler
  echo; echo "==> Interrupted — stopping the scan (its session is saved)."
  [ -n "$CURRENT_CID" ] && docker stop -t 10 "$CURRENT_CID" >/dev/null 2>&1
  local ans="r"
  if [ -f "${SESSION_PATH:-x}.session" ] && [ -r /dev/tty ]; then
    echo "   [r] partial report from what's been scanned so far  (default)"
    echo "   [s] keep the raw session only (open in ZAP Desktop / report later)"
    echo "   [q] quit and discard"
    printf "   choose [r/s/q]: "
    read -r ans </dev/tty 2>/dev/null || ans="r"; ans="${ans:-r}"
  fi
  case "$ans" in
    s|S) echo "   Session kept: ${SESSION_PATH}.session (open in ZAP Desktop, or re-run to report)." ;;
    q|Q) echo "   Discarding session."; rm -f "${SESSION_PATH:-x}".session* 2>/dev/null ;;
    *)   report_from_session ;;
  esac
  [ -n "$CURRENT_CID" ] && docker rm -f "$CURRENT_CID" >/dev/null 2>&1; CURRENT_CID=""
  [ -n "${WORKPLAN:-}" ] && rm -f "$HERE/$WORKPLAN" 2>/dev/null
  exit 130
}
trap cleanup EXIT
trap on_interrupt INT TERM
# IMAGE/PLAN (and the other ZAP_* knobs) are resolved AFTER target.env is sourced
# below, so they can be set in target.env too — while a runtime override still wins.

# Low-memory mode is decided after the Docker daemon check below (once we can read
# the engine's RAM). It caps ZAP's heap (zap.sh honors a -Xmx passed as an argument,
# line ~120 of zap.sh) and single-threads the active scan, so a full scan fits on a
# constrained host instead of being OOM-killed (exit 137). It AUTO-enables when Docker
# has < LOWMEM_THRESHOLD_MIB; force it with ZAP_LOWMEM=1/0. Heap via ZAP_XMX (MB).
LOWMEM_THRESHOLD_MIB="${LOWMEM_THRESHOLD_MIB:-7000}"
LOWMEM_ARGS=()

# Runtime env beats target.env: capture any knob set inline / in the parent env
# BEFORE sourcing the file, then re-apply after it — so a runtime override wins over
# a value in target.env, which in turn beats the built-in default.
#   precedence:  runtime env  >  target.env  >  default
ZAP_KNOBS="ZAP_PLAN ZAP_IMAGE ZAP_DETAILED ZAP_LOWMEM ZAP_XMX ZAP_ASCAN_MINS ZAP_RULE_MINS ZAP_MAX_HOURS ZAP_SKIP_MEM_CHECK OPENAPI_URL"
for v in $ZAP_KNOBS; do printf -v "_RT_$v" '%s' "${!v:-}"; done

# App-specific config (target.env). Auto-exported so both the plan (AF ${VAR}
# substitution) and fetch_token.py pick the values up. Per-target values are
# required (below); only common-pattern selectors have generic fallbacks.
CFG="${TARGET_ENV:-$HERE/target.env}"
[ -f "$CFG" ] && { set -a; . "$CFG"; set +a; } || { echo "  MISSING $CFG — run: cp target.env.example target.env  (then fill it in)"; exit 1; }
# Re-apply runtime overrides captured above (they win over target.env).
for v in $ZAP_KNOBS; do rt="_RT_$v"; [ -n "${!rt}" ] && printf -v "$v" '%s' "${!rt}"; done
IMAGE="${ZAP_IMAGE:-zap-dast:chrome}"
PLAN="${ZAP_PLAN:-zap-dast.yaml}"          # override for a quick/custom plan
# Required per-target values (no sensible default) — target.env must set these.
for r in CONTEXT_NAME APP_URL API_URL LOGIN_URL START_URL VERIFY_URL LOGGEDIN_REGEX; do
  [ -n "${!r:-}" ] || { echo "  target.env is missing '$r'"; exit 1; }
done
# Common-pattern defaults — override in target.env only if your app differs.
: "${TOKEN_KEY:=id_token}"
: "${AUTH_HEADER:=Authorization}"
: "${AUTH_PREFIX:=Bearer }"
: "${USER_SEL:=#username}"
: "${PASS_SEL:=#password}"
: "${BTN_XPATH:=//button[normalize-space()='Log In']}"
# Report base name derived from the context (e.g. "My App" -> my-app-zap-report).
REPORT_NAME="${REPORT_NAME:-$(printf '%s' "$CONTEXT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')-zap-report}"
export APP_URL API_URL LOGIN_URL START_URL VERIFY_URL LOGGEDIN_REGEX TOKEN_KEY \
       AUTH_HEADER AUTH_PREFIX BTN_XPATH USER_SEL PASS_SEL CONTEXT_NAME REPORT_NAME
# vars forwarded into the containers (fetch_token.py env + AF ${VAR} substitution)
ENVARGS=(); for v in APP_URL API_URL LOGIN_URL START_URL VERIFY_URL LOGGEDIN_REGEX \
  TOKEN_KEY BTN_XPATH USER_SEL PASS_SEL CONTEXT_NAME REPORT_NAME; do ENVARGS+=(-e "$v"); done

# --- preflight: the ONLY host requirement is Docker (Python/Selenium/Chrome all
# --- live inside the image) ---
echo "==> Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "  MISSING: docker — install Docker / Docker Desktop"; exit 1; }
# Ensure the Docker DAEMON is up. `docker info` hangs when it's down, so bound it
# with a timeout; if down, try to start it, then wait for it to come up.
if ! timeout 15 docker info >/dev/null 2>&1; then
  echo "  Docker daemon not running — attempting to start it..."
  if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    DD="/mnt/c/Program Files/Docker/Docker/Docker Desktop.exe"
    if [ -f "$DD" ]; then ( "$DD" >/dev/null 2>&1 & ) ; else powershell.exe -NoProfile -Command "Start-Process 'Docker Desktop'" >/dev/null 2>&1 || true; fi
  elif command -v systemctl >/dev/null 2>&1; then
    sudo -n systemctl start docker >/dev/null 2>&1 || true   # needs passwordless sudo
  fi
  echo "  waiting for the Docker daemon (up to 120s)..."
  for _ in $(seq 1 40); do timeout 5 docker info >/dev/null 2>&1 && break; sleep 3; done
  timeout 10 docker info >/dev/null 2>&1 || { echo "  Docker daemon still not reachable — start Docker Desktop manually, then re-run."; exit 1; }
  echo "  Docker daemon is up."
fi
echo "  OK (Docker only)"

# Pre-flight memory: read the RAM the Docker engine can actually use (on a VM /
# Docker Desktop this is the VM allocation, not the host's RAM), then auto-pick
# low-memory mode so a full scan fits instead of getting OOM-killed (exit 137).
mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
mem_mib=$(( mem_bytes / 1024 / 1024 ))
lowmem=0; lowmem_auto=0
case "${ZAP_LOWMEM:-auto}" in
  0|off|false|no) lowmem=0 ;;                                  # forced off
  auto|"") { [ "$mem_bytes" -gt 0 ] && [ "$mem_mib" -lt "$LOWMEM_THRESHOLD_MIB" ]; } \
             && { lowmem=1; lowmem_auto=1; } ;;                # auto-detect
  *) lowmem=1 ;;                                               # forced on
esac
if [ "$lowmem" = 1 ]; then
  : "${ZAP_XMX:=1024}"
  LOWMEM_ARGS=(-Xmx"${ZAP_XMX}"m -config "scanner.threadPerHost=1")
  if [ "$lowmem_auto" = 1 ]; then
    echo "  Low memory detected (~${mem_mib} MiB available to Docker) — switching to"
    echo "  low-memory mode (heap ${ZAP_XMX}m, single-threaded active scan). The scan will"
    echo "  still run; it may just take a little longer. (ZAP_LOWMEM=0 to force it off.)"
  else
    echo "  ZAP_LOWMEM: heap capped at ${ZAP_XMX}m, active scan single-threaded."
  fi
fi
# Below ~4 GiB, even low-memory mode may not save the headless-Chrome step.
if [ -z "${ZAP_SKIP_MEM_CHECK:-}" ] && [ "$mem_bytes" -gt 0 ] && [ "$mem_mib" -lt 3600 ]; then
  echo "  WARNING: only ~${mem_mib} MiB for Docker — below ~4 GiB the browser step itself"
  echo "           can be OOM-killed. Consider raising Docker/VM memory. (ZAP_SKIP_MEM_CHECK=1 to silence.)"
fi

# 0. Build the Chrome-enabled image if it isn't present yet (one-time, cached).
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Building $IMAGE (Chromium + Selenium on the ZAP base; one-time)..."
  docker build -f "$HERE/Dockerfile.zap-chrome" -t "$IMAGE" "$HERE"
fi

# 1. Reuse bearer.txt only if its JWT exp is >45 min out (must outlast the scan;
#    a stale token would be injected and every API request would silently 403).
#    Portable exp decode via base64/date — no host Python needed.
jwt_exp() {  # echo the JWT exp epoch from file $1, else nothing
  local seg; seg=$(tr -d '\r\n' < "$1" | cut -d. -f2 | tr '_-' '/+')
  case $(( ${#seg} % 4 )) in 2) seg="${seg}==";; 3) seg="${seg}=";; esac
  { printf '%s' "$seg" | base64 -d 2>/dev/null || printf '%s' "$seg" | base64 -D 2>/dev/null; } \
    | grep -oE '"exp"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1
}
NEED_FETCH=1
if [ -s "$HERE/bearer.txt" ]; then
  exp=$(jwt_exp "$HERE/bearer.txt" || true)
  if [ -n "${exp:-}" ] && [ "$(( exp - $(date +%s) ))" -gt 2700 ]; then
    echo "==> Reusing bearer.txt (still valid)."
    NEED_FETCH=0
  else
    echo "==> bearer.txt missing/expired — minting a fresh one."
  fi
fi

# 2. Mint the token INSIDE the image (same Chromium the spider uses). The
#    container prints the token to stdout; the host writes bearer.txt, so the
#    container needs no write access to the mounted volume.
if [ "$NEED_FETCH" = 1 ]; then
  echo "==> Minting token in-container (headless Chrome login)..."
  tmp="$(mktemp)"
  if docker run --rm --shm-size=1g -v "$HERE":/zap/wrk:ro \
       -e ZAP_AUTH_USER -e ZAP_AUTH_PASS -e TOKEN_STDOUT=1 "${ENVARGS[@]}" \
       "$IMAGE" python3 /zap/wrk/fetch_token.py > "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$HERE/bearer.txt"
  else
    rm -f "$tmp"; echo "  token mint failed — check creds / connectivity"; exit 1
  fi
fi
TOK="$(tr -d '\r\n' < "$HERE/bearer.txt")"

# 2b. If an OpenAPI spec is configured, validate it NOW (before the long scan) so a
#     bad URL / unreachable / non-JSON spec is caught up front, not discovered at the
#     end. The scan still proceeds either way; we just warn loudly about the impact.
if [ -n "${OPENAPI_URL:-}" ]; then
  echo "==> Validating OpenAPI spec: $OPENAPI_URL"
  set +e
  oa_chk=$(docker run --rm -e OA_URL="$OPENAPI_URL" -e OA_HK="$AUTH_HEADER" -e OA_HV="${AUTH_PREFIX}${TOK}" \
    "$IMAGE" python3 -c '
import os, urllib.request, json, sys
req = urllib.request.Request(os.environ["OA_URL"])
req.add_header(os.environ["OA_HK"], os.environ["OA_HV"])
try:
    body = urllib.request.urlopen(req, timeout=20).read()
    j = json.loads(body)
    print("OK", len(j.get("paths", {})))
except Exception as e:
    print("ERR", repr(e)[:150]); sys.exit(1)
' 2>&1)
  set -e
  if printf '%s' "$oa_chk" | grep -q "^OK"; then
    echo "    OK — $(printf '%s' "$oa_chk" | awk '{print $2}') API paths found; the active scan will attack the full API."
  else
    echo "    !! WARNING: could NOT fetch/parse the OpenAPI spec:"
    echo "       $oa_chk"
    echo "       The scan will STILL run, but the active scan will only cover the API"
    echo "       calls the UI happens to trigger — NOT the full API. Fix OPENAPI_URL"
    echo "       (or unset it) for correct coverage. Continuing in 5s..."
    sleep 5
  fi
fi

# 3. Build the effective plan; append the heavy detail report only if ZAP_DETAILED=1.
TS="$(date +%Y%m%d-%H%M%S)"          # one timestamp shared by every artifact
mkdir -p "$HERE/reports"
WORKPLAN=".plan-$TS.yaml"
cp "$HERE/$PLAN" "$HERE/$WORKPLAN"
if [ -n "${ZAP_DETAILED:-}" ]; then
  cat >> "$HERE/$WORKPLAN" <<'EOF'

  - type: report
    parameters:
      template: "traditional-html-plus"
      reportDir: "/zap/wrk/reports"
      reportFile: "${REPORT_NAME}-plus.html"
      reportTitle: "${CONTEXT_NAME} DAST — detailed"
EOF
fi
# Render app-specific ${VAR} into the plan ourselves (ZAP AF env-substitution is
# unreliable here). Creds stay as ${ZAP_AUTH_USER}/${ZAP_AUTH_PASS} for ZAP to
# fill in at runtime, so they never get written to disk.
for v in APP_URL API_URL LOGIN_URL START_URL VERIFY_URL LOGGEDIN_REGEX \
         BTN_XPATH USER_SEL PASS_SEL CONTEXT_NAME REPORT_NAME; do
  val="${!v}"; val="${val//&/\\&}"; val="${val//|/\\|}"   # escape sed specials
  sed -i "s|\${$v}|$val|g" "$HERE/$WORKPLAN"
done

# Optional: import an OpenAPI/Swagger spec (OPENAPI_URL in target.env) so the active
# scan attacks the FULL API surface, not just the calls the SPA happened to make.
# Injected as the first job; targetUrl is API_URL (specs often omit a servers block).
if [ -n "${OPENAPI_URL:-}" ]; then
  OPENAPI_JOB="  - type: openapi
    parameters:
      apiUrl: \"${OPENAPI_URL}\"
      targetUrl: \"${API_URL}\"
      context: \"${CONTEXT_NAME}\""
  awk -v job="$OPENAPI_JOB" '
    /^[[:space:]]*-[[:space:]]*type:[[:space:]]*spiderAjax/ && !ins { print job; ins=1 }
    { print }
  ' "$HERE/$WORKPLAN" > "$HERE/$WORKPLAN.tmp" && mv "$HERE/$WORKPLAN.tmp" "$HERE/$WORKPLAN"
  echo "==> OpenAPI import enabled ($OPENAPI_URL) — active scan will cover the full API."
fi

# Optional: override the active-scan TIME budget. ZAP_ASCAN_MINS=0 removes the cap
# entirely (runs to completion); e.g. ZAP_ASCAN_MINS=180 for 3 hours. Unset = the
# plan's default (30 full / 1 quick). The per-rule cap (maxRuleDurationInMins) stays,
# so a single stuck rule can't hang the whole scan even when the total is unlimited.
if [ -n "${ZAP_ASCAN_MINS:-}" ]; then
  sed -i "s|maxScanDurationInMins: [0-9]*|maxScanDurationInMins: ${ZAP_ASCAN_MINS}|" "$HERE/$WORKPLAN"
  if [ "$ZAP_ASCAN_MINS" = 0 ]; then
    echo "==> Active-scan time cap REMOVED (runs to completion; may take hours on a large API)."
  else
    echo "==> Active-scan time cap set to ${ZAP_ASCAN_MINS} min."
  fi
fi
# Optional: override the PER-RULE time cap (safety net against a single stuck rule).
# ZAP_RULE_MINS=0 removes it too — only do that if you also accept an unbounded total.
if [ -n "${ZAP_RULE_MINS:-}" ]; then
  sed -i "s|maxRuleDurationInMins: [0-9]*|maxRuleDurationInMins: ${ZAP_RULE_MINS}|" "$HERE/$WORKPLAN"
  echo "==> Per-rule time cap set to ${ZAP_RULE_MINS} min$([ "$ZAP_RULE_MINS" = 0 ] && echo ' (UNLIMITED — a stuck rule can run forever)')."
fi

# 4. Run the scan. The container runs DETACHED (ZAP -cmd can hang on shutdown, so
#    we stop it ourselves once the plan is done). Robustness: retry once if the
#    spider crawls 0 URLs (flaky browser-auth login), then FAIL LOUDLY if still empty.
LOG="$HERE/reports/scan-$TS.log"
# Persist ZAP's session to a host-mounted dir so an interrupted/auto-stopped scan
# keeps its data (for a partial report or ZAP Desktop) instead of dying with the container.
SESSION_PATH="$HERE/.zap-session/$TS"; SESSION_CPATH="/zap/wrk/.zap-session/$TS"
mkdir -p "$HERE/.zap-session"
run_scan() {   # one attempt; tees ZAP output to $LOG; sets global rc
  local logpid ascan_start=0 next_beat=0 now el deadline _exp _dm
  CURRENT_CID=$(docker run -d --shm-size=2g -v "$HERE":/zap/wrk:rw \
    -e ZAP_AUTH_USER -e ZAP_AUTH_PASS "${ENVARGS[@]}" \
    "$IMAGE" zap.sh -cmd -newsession "$SESSION_CPATH" -autorun "/zap/wrk/${WORKPLAN}" \
    "${LOWMEM_ARGS[@]}" \
    -config "selenium.chromeDriver=/usr/bin/chromedriver" \
    -config "replacer.full_list(0).description=dast-bearer" \
    -config "replacer.full_list(0).enabled=true" \
    -config "replacer.full_list(0).matchtype=REQ_HEADER" \
    -config "replacer.full_list(0).matchstr=${AUTH_HEADER}" \
    -config "replacer.full_list(0).regex=false" \
    -config "replacer.full_list(0).replacement=${AUTH_PREFIX}${TOK}" \
    -config "replacer.full_list(0).initiators=")
  docker logs -f "$CURRENT_CID" 2>&1 | tee "$LOG" &
  logpid=$!
  rc=1; oom_killed=""
  # Auto-stop deadline: 5 min before the token expires (everything after is 401s), or
  # ZAP_MAX_HOURS if sooner. Bounds runaway/unbounded scans automatically.
  deadline=""
  _exp=$(jwt_exp "$HERE/bearer.txt" 2>/dev/null); [ -n "$_exp" ] && deadline=$((_exp - 300))
  if [ -n "${ZAP_MAX_HOURS:-}" ]; then
    _dm=$(( $(date +%s) + ZAP_MAX_HOURS * 3600 ))
    { [ -z "$deadline" ] || [ "$_dm" -lt "$deadline" ]; } && deadline="$_dm"
  fi
  while :; do
    if grep -qE "Automation plan (succeeded|failed)" "$LOG" 2>/dev/null; then
      grep -q "Automation plan succeeded" "$LOG" && rc=0 || rc=2
      sleep 3; docker stop -t 15 "$CURRENT_CID" >/dev/null 2>&1; break   # sidestep the shutdown hang
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CURRENT_CID" 2>/dev/null)" != "true" ]; then
      rc=$(docker inspect -f '{{.State.ExitCode}}' "$CURRENT_CID" 2>/dev/null || echo 1)
      # Did Docker's cgroup OOM-kill it? Definitive, unlike guessing from dmesg.
      oom_killed=$(docker inspect -f '{{.State.OOMKilled}}' "$CURRENT_CID" 2>/dev/null || echo "")
      break
    fi
    if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; then
      echo; echo "==> Reached the scan deadline (token nearing expiry / ZAP_MAX_HOURS) — stopping now;"
      echo "    anything past the token's lifetime just gets 401s. Reporting partial results."
      docker stop -t 15 "$CURRENT_CID" >/dev/null 2>&1
      rc=4; break
    fi
    # Heartbeat during the (otherwise silent) active-scan phase — ZAP emits no live
    # progress to stdout, so show elapsed time so the run doesn't look hung.
    if grep -q "Job activeScan started" "$LOG" 2>/dev/null \
       && ! grep -q "Job activeScan finished" "$LOG" 2>/dev/null; then
      now=$(date +%s)
      if [ "$ascan_start" = 0 ]; then
        ascan_start=$now; next_beat=$((now + 60))
        echo "   active scan running — ZAP attacks each URL; no per-step output. Heartbeat every 60s:"
      elif [ "$now" -ge "$next_beat" ]; then
        el=$(( now - ascan_start ))
        printf "   ...still scanning — %dm%02ds into the active scan\n" "$((el/60))" "$((el%60))"
        next_beat=$(( now + 60 ))
      fi
    fi
    sleep 5
  done
  kill "$logpid" 2>/dev/null
  docker rm -f "$CURRENT_CID" >/dev/null 2>&1
  CURRENT_CID=""   # normal finish — disarm the cleanup trap's container stop
}
spider_urls() { grep -oE "found [0-9]+ URLs" "$LOG" 2>/dev/null | grep -oE "[0-9]+" | tail -1; }

set +e
echo "==> Running ZAP scan in $IMAGE (this takes a while)..."
run_scan
urls="$(spider_urls)"; urls="${urls:-0}"
if [ "$rc" = 0 ] && [ "$urls" = 0 ]; then
  echo "==> Spider found 0 URLs (login likely didn't take) — retrying once..."
  run_scan
  urls="$(spider_urls)"; urls="${urls:-0}"
fi
# Fail loudly: a 'successful' plan that crawled nothing means auth didn't work.
[ "$rc" = 0 ] && [ "$urls" = 0 ] && rc=3
# Auto-stopped at the deadline: the plan never reached its report jobs, so build the
# report from the saved session (writes the same timestamped names the summary reads).
[ "$rc" = 4 ] && report_from_session
rm -f "$HERE/$WORKPLAN"
# On a clean run the plan already wrote the reports, so the session is redundant —
# delete it to avoid disk bloat. Keep it on any non-clean rc (for diagnosis/partial report).
[ "$rc" = 0 ] && rm -f "${SESSION_PATH}".session* 2>/dev/null

# 5. Timestamp the artifacts (the plan writes fixed names) so runs never overwrite.
for f in "$REPORT_NAME.html" "$REPORT_NAME.json" "$REPORT_NAME-plus.html"; do
  [ -f "$HERE/reports/$f" ] && mv -f "$HERE/reports/$f" "$HERE/reports/${f%.*}-$TS.${f##*.}"
done

# 6. Crawl stats live only in the console log, not the reports — surface the key
#    numbers in a concise summary next to the reports (pure grep/date, no Python).
SUMMARY="$HERE/reports/scan-summary-$TS.txt"
JSON="$HERE/reports/$REPORT_NAME-$TS.json"
urls=$(grep -oE "found [0-9]+ URLs" "$LOG" | grep -oE "[0-9]+" | tail -1)
spider_t=$(grep "spiderAjax finished" "$LOG" | grep -oE "[0-9:]{8}" | tail -1)
ascan_t=$(grep "activeScan finished" "$LOG" | grep -oE "[0-9:]{8}" | tail -1)
result=$(grep -oE "Automation plan (succeeded|failed)" "$LOG" | tail -1)
# --- scan-reach visibility: profile, caps, API import, cap-hit ---------------
case "$PLAN" in *quick*) profile="quick (smoke test)";; *) profile="full";; esac
ascan_cap=$(grep -oE "maxScanDurationInMins = [0-9]+" "$LOG" | grep -oE "[0-9]+" | tail -1)
spider_cap=$(grep -oE "spiderAjax set maxDuration = [0-9]+" "$LOG" | grep -oE "[0-9]+" | tail -1)
ascan_note=""
if [ -n "$ascan_t" ] && [ -n "$ascan_cap" ] && [ "$ascan_cap" != 0 ]; then
  amin=$(printf '%s' "$ascan_t" | awk -F: '{print ($1*60)+$2}')   # HH:MM:SS -> minutes
  [ "${amin:-0}" -ge "$ascan_cap" ] && ascan_note="  [hit the ${ascan_cap}m cap — surface likely exceeds the time budget; raise ZAP_ASCAN_MINS]"
fi
cap_disp=$([ "${ascan_cap:-}" = 0 ] && echo "unlimited" || echo "${ascan_cap:-?}m")
if [ -n "${OPENAPI_URL:-}" ]; then
  if grep -qi "Job openapi" "$LOG" 2>/dev/null; then
    api_ops=$(grep -oiE "imported [0-9]+ (url|endpoint|operation|path|message)" "$LOG" | grep -oE "[0-9]+" | tail -1)
    api_line="yes — ${OPENAPI_URL}${api_ops:+  (~${api_ops} ops imported)}"
  else
    api_line="CONFIGURED but the openapi job did not run — check the log (spec fetch/parse failed?)"
  fi
else
  api_line="no  (set OPENAPI_URL in target.env to attack the full API surface)"
fi
exp_epoch=$(jwt_exp "$HERE/bearer.txt" 2>/dev/null)
tok_exp=$( { [ -n "$exp_epoch" ] && { date -u -d "@$exp_epoch" +"%Y-%m-%d %H:%M UTC" 2>/dev/null || date -u -r "$exp_epoch" +"%Y-%m-%d %H:%M UTC" 2>/dev/null; }; } || echo "unknown" )
risk() { [ -f "$JSON" ] || { echo 0; return; }; { grep -oE "\"riskcode\"[[:space:]]*:[[:space:]]*\"$1\"" "$JSON" || true; } | wc -l | tr -d ' '; }
{
  echo "$CONTEXT_NAME DAST — $TS"
  echo "  Scan profile    : ${profile}${ascan_cap:+  (spider ${spider_cap:-?}m / active-scan cap ${cap_disp})}"
  echo "  Target          : $APP_URL + $API_URL"
  echo "  API spec import : ${api_line}"
  echo "  URLs discovered : ${urls:-?}  (AJAX spider)"
  echo "  Spider time     : ${spider_t:-?}"
  echo "  Active scan time: ${ascan_t:-?}${ascan_note}"
  echo "  Result          : ${result:-unknown}"
  echo "  Alerts          : High=$(risk 3)  Medium=$(risk 2)  Low=$(risk 1)  Info=$(risk 0)"
  echo "  Token expires   : ${tok_exp}"
  echo "  Reports         : $REPORT_NAME-$TS.html / .json"
} > "$SUMMARY"
set -e

echo
case "$rc" in
  0) echo "==> Scan completed successfully." ;;
  3) echo "==> FAILED: the spider crawled 0 URLs even after a retry — the authenticated"
     echo "    login didn't take. Check ZAP_AUTH_USER/PASS, the selectors/URLs in"
     echo "    target.env, and that the target is reachable." ;;
  4) echo "==> Scan auto-stopped at the deadline (token expiry / ZAP_MAX_HOURS)."
     echo "    The report above is PARTIAL — only what was scanned before the stop." ;;
  137) echo "==> FAILED (137 = SIGKILL). OOMKilled=${oom_killed:-unknown}."
     echo "    ZAP ran out of memory (usually mid active-scan). Docker here can use only"
     echo "    $(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.1f", $1/1073741824}') GiB — on a VM/Docker Desktop that's the VM's allocation, NOT the host's"
     echo "    RAM. Give Docker more memory (WSL -> ~/.wslconfig 'memory='; Docker Desktop"
     echo "    -> Settings > Resources; a plain VM -> raise its RAM), OR fit the scan into"
     echo "    what you have by re-running with ZAP_LOWMEM=1. See README Troubleshooting." ;;
  *) echo "==> Scan ended abnormally (code $rc) — see the console log." ;;
esac
echo "-----------------------------------------"
cat "$SUMMARY"
echo "-----------------------------------------"
echo "  HTML report : $HERE/reports/$REPORT_NAME-$TS.html"
echo "  JSON report : $HERE/reports/$REPORT_NAME-$TS.json"
[ -n "${ZAP_DETAILED:-}" ] && echo "  Detailed    : $HERE/reports/$REPORT_NAME-plus-$TS.html"
echo "  Console log : $LOG"
echo "  Summary     : $SUMMARY"
[ "$rc" = 0 ] || exit "$rc"   # non-zero exit on failure (incl. empty crawl) for CI
