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
# Derived ZAP image with Chromium (the base image ships Firefox only, whose
# spider can't crawl the authenticated SPA). Built from Dockerfile.zap-chrome.
IMAGE="${ZAP_IMAGE:-zap-dast:chrome}"
PLAN="${ZAP_PLAN:-zap-dast.yaml}"          # override for a quick/custom plan

# App-specific config (target.env). Auto-exported so both the plan (AF ${VAR}
# substitution) and fetch_token.py pick the values up. Per-target values are
# required (below); only common-pattern selectors have generic fallbacks.
CFG="${TARGET_ENV:-$HERE/target.env}"
[ -f "$CFG" ] && { set -a; . "$CFG"; set +a; } || { echo "  MISSING $CFG — run: cp target.env.example target.env  (then fill it in)"; exit 1; }
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

# Pre-flight: warn if the Docker engine has too little RAM. Headless Chrome (token
# mint + AJAX spider) and ZAP's JVM otherwise get OOM-killed mid-run and surface as
# a cryptic "Chrome instance exited" or Java OutOfMemoryError. Warn only, don't block.
if [ -z "${ZAP_SKIP_MEM_CHECK:-}" ]; then
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  mem_mib=$(( mem_bytes / 1024 / 1024 ))
  if [ "$mem_bytes" -gt 0 ] && [ "$mem_mib" -lt 3600 ]; then
    echo "  WARNING: Docker has only ~${mem_mib} MiB RAM available to containers."
    echo "           This tool needs >= 4 GiB (>= 8 GiB recommended); on less, headless"
    echo "           Chrome and ZAP's JVM will likely be OOM-killed ('Chrome instance"
    echo "           exited' / Java OutOfMemoryError). Increase your VM/Docker memory."
    echo "           (Set ZAP_SKIP_MEM_CHECK=1 to silence this check.)"
  fi
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

# 4. Run the scan. The container runs DETACHED (ZAP -cmd can hang on shutdown, so
#    we stop it ourselves once the plan is done). Robustness: retry once if the
#    spider crawls 0 URLs (flaky browser-auth login), then FAIL LOUDLY if still empty.
LOG="$HERE/reports/scan-$TS.log"
run_scan() {   # one attempt; tees ZAP output to $LOG; sets global rc
  local cid logpid
  cid=$(docker run -d --shm-size=2g -v "$HERE":/zap/wrk:rw \
    -e ZAP_AUTH_USER -e ZAP_AUTH_PASS "${ENVARGS[@]}" \
    "$IMAGE" zap.sh -cmd -autorun "/zap/wrk/${WORKPLAN}" \
    -config "selenium.chromeDriver=/usr/bin/chromedriver" \
    -config "replacer.full_list(0).description=dast-bearer" \
    -config "replacer.full_list(0).enabled=true" \
    -config "replacer.full_list(0).matchtype=REQ_HEADER" \
    -config "replacer.full_list(0).matchstr=${AUTH_HEADER}" \
    -config "replacer.full_list(0).regex=false" \
    -config "replacer.full_list(0).replacement=${AUTH_PREFIX}${TOK}" \
    -config "replacer.full_list(0).initiators=")
  docker logs -f "$cid" 2>&1 | tee "$LOG" &
  logpid=$!
  rc=1
  while :; do
    if grep -qE "Automation plan (succeeded|failed)" "$LOG" 2>/dev/null; then
      grep -q "Automation plan succeeded" "$LOG" && rc=0 || rc=2
      sleep 3; docker stop -t 15 "$cid" >/dev/null 2>&1; break   # sidestep the shutdown hang
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]; then
      rc=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 1); break
    fi
    sleep 5
  done
  kill "$logpid" 2>/dev/null
  docker rm -f "$cid" >/dev/null 2>&1
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
rm -f "$HERE/$WORKPLAN"

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
exp_epoch=$(jwt_exp "$HERE/bearer.txt" 2>/dev/null)
tok_exp=$( { [ -n "$exp_epoch" ] && { date -u -d "@$exp_epoch" +"%Y-%m-%d %H:%M UTC" 2>/dev/null || date -u -r "$exp_epoch" +"%Y-%m-%d %H:%M UTC" 2>/dev/null; }; } || echo "unknown" )
risk() { [ -f "$JSON" ] || { echo 0; return; }; { grep -oE "\"riskcode\"[[:space:]]*:[[:space:]]*\"$1\"" "$JSON" || true; } | wc -l | tr -d ' '; }
{
  echo "$CONTEXT_NAME DAST — $TS"
  echo "  Target          : $APP_URL + $API_URL"
  echo "  URLs discovered : ${urls:-?}"
  echo "  Spider time     : ${spider_t:-?}"
  echo "  Active scan time: ${ascan_t:-?}"
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
