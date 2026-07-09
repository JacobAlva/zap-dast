#!/usr/bin/env python3
"""
Fetch a fresh Bearer token (JWT) by performing the real browser login, then
reading it out of localStorage. App-specific bits (login URL, selectors, token
key) come from env vars — see target.env. Writes the raw token to an output file
(or stdout with TOKEN_STDOUT=1) so ZAP can inject it as an auth header.

This is the CI "pre-scan" step: ZAP itself cannot extract a localStorage JWT,
so we mint one here and hand it to ZAP.

Env vars:
  ZAP_AUTH_USER   login email      (required)
  ZAP_AUTH_PASS   login password   (required)
  CHROMEDRIVER    path to chromedriver (default: auto-resolved by Selenium Manager)
  TOKEN_OUT       output file path  (default: alongside this script: bearer.txt)

Usage:  python fetch_token.py
Exit:   0 on success (token written), 1 on failure.
"""
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

# App-specific config (see target.env) — defaults are generic placeholders.
LOGIN_URL = os.environ.get("LOGIN_URL", "https://app.example.com/landing")
BTN_XPATH = os.environ.get("BTN_XPATH", "//button[normalize-space()='Log In']")
USER_SEL = os.environ.get("USER_SEL", "#username")
PASS_SEL = os.environ.get("PASS_SEL", "#password")
TOKEN_KEY = os.environ.get("TOKEN_KEY", "id_token")
HERE = Path(__file__).resolve().parent

USER = os.environ.get("ZAP_AUTH_USER")
PASS = os.environ.get("ZAP_AUTH_PASS")
# Optional: explicit chromedriver path. If unset (or missing), Selenium Manager
# auto-resolves a matching driver — which is what a Linux colleague will use.
CHROMEDRIVER = os.environ.get("CHROMEDRIVER")
TOKEN_OUT = Path(os.environ.get("TOKEN_OUT", HERE / "bearer.txt"))

if not USER or not PASS:
    sys.exit("ERROR: set ZAP_AUTH_USER and ZAP_AUTH_PASS env vars")


def jwt_exp(token: str) -> str:
    """Decode the JWT exp claim (no verification) for a sanity log line."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(data["exp"]))
    except Exception:
        return "unknown"


# Phrases IdP login pages show for bad credentials / unknown accounts. Used to turn
# a raw Selenium timeout into a clear "wrong username/password" message.
AUTH_ERR_RE = re.compile(
    r"wrong email or password|wrong username or password|incorrect (email|username|password)"
    r"|invalid (email|username|password|credentials|login)|your (username|password) is incorrect"
    r"|couldn'?t find (your|an) account|no account (found|matching|with)|user( ?name)? (not found|does ?n'?t exist)"
    r"|that .{0,20}doesn'?t match|check your (credentials|password|(email|username) and password)"
    r"|access denied|login failed",
    re.I,
)


def page_error(driver):
    """Return the login page's error line if it's showing a credential error, else None."""
    try:
        txt = driver.execute_script("return document.body ? document.body.innerText : '';") or ""
    except Exception:
        return None
    if not AUTH_ERR_RE.search(txt):
        return None
    for line in txt.splitlines():
        line = line.strip()
        if line and AUTH_ERR_RE.search(line):
            return line[:160]
    return "the login page reported an authentication error"


def main() -> int:
    opts = Options()
    # On Linux/containers the browser is often chromium at a non-default path.
    chrome_bin = os.environ.get("CHROME_BIN")
    if chrome_bin:
        opts.binary_location = chrome_bin
    opts.add_argument("--headless=new")
    opts.add_argument("--window-size=1280,900")
    opts.add_argument("--no-sandbox")
    # Memory-lean + stability flags so session creation survives on small VMs /
    # CI runners (Chrome otherwise gets OOM-killed on ~2 GB boxes and Selenium
    # reports a generic "Chrome instance exited"). Belt-and-suspenders: --disable-
    # dev-shm-usage is also in the container's chrome wrapper.
    for flag in (
        "--disable-dev-shm-usage",        # write shm to /tmp, not the tiny /dev/shm
        "--disable-gpu",
        "--disable-software-rasterizer",
        "--disable-extensions",
        "--disable-background-networking",
        "--disable-features=Translate,BackForwardCache",
    ):
        opts.add_argument(flag)
    # A normal UA helps avoid headless bot-detection on the IdP.
    opts.add_argument(
        "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
    )
    if CHROMEDRIVER and os.path.exists(CHROMEDRIVER):
        driver = webdriver.Chrome(service=Service(CHROMEDRIVER), options=opts)
    else:
        # Selenium Manager downloads/locates a matching driver automatically.
        driver = webdriver.Chrome(options=opts)
    wait = WebDriverWait(driver, 30)
    try:
        driver.get(LOGIN_URL)
        # 1. Landing page -> click "Log In" (redirects to Auth0 with a fresh state)
        wait.until(
            EC.element_to_be_clickable((By.XPATH, BTN_XPATH))
        ).click()

        # 2. Identifier screen: email -> submit
        wait.until(EC.visibility_of_element_located((By.CSS_SELECTOR, USER_SEL))).send_keys(USER)
        driver.find_element(By.CSS_SELECTOR, "button[type=submit]").click()

        # 3. Password screen: password -> submit
        wait.until(EC.visibility_of_element_located((By.CSS_SELECTOR, PASS_SEL))).send_keys(PASS)
        driver.find_element(By.CSS_SELECTOR, "button[type=submit]").click()

        # 4. Wait until the SPA has stored the token in localStorage
        token = None
        for _ in range(60):  # up to ~30s
            token = driver.execute_script(f"return localStorage.getItem('{TOKEN_KEY}');")
            if token:
                break
            time.sleep(0.5)
        if not token:
            err = page_error(driver)   # wrong password lands here (field appeared, login rejected)
            if err:
                print("==> Login failed: the app rejected the credentials — "
                      "check ZAP_AUTH_USER / ZAP_AUTH_PASS.", file=sys.stderr)
                print(f'    (login page said: "{err}")', file=sys.stderr)
                return 2
            print("ERROR: id_token never appeared in localStorage", file=sys.stderr)
            print("final url:", driver.current_url, file=sys.stderr)
            return 1

        # TOKEN_STDOUT=1 -> print ONLY the token to stdout (summary to stderr) so a
        # caller can capture it (e.g. `docker run ... > bearer.txt`) without the
        # container needing write access to a mounted volume.
        if os.environ.get("TOKEN_STDOUT"):
            print(f"OK: {len(token)}-char id_token, expires {jwt_exp(token)}", file=sys.stderr)
            sys.stdout.write(token)
            sys.stdout.flush()
        else:
            TOKEN_OUT.write_text(token, encoding="utf-8")
            print(f"OK: wrote {len(token)}-char id_token to {TOKEN_OUT}")
            print(f"    token expires: {jwt_exp(token)}")
        return 0
    except Exception as e:
        # Login step failed (usually a timeout waiting for a field). If the page is
        # showing a credential error (wrong username lands here — the password field
        # never appears), say so plainly. Otherwise dump what the browser is showing
        # so we can see the screen it stalled on (CAPTCHA / verify / MFA / changed
        # selector). Creds are never printed.
        err = page_error(driver)
        if err:
            print("==> Login failed: the app rejected the credentials — "
                  "check ZAP_AUTH_USER / ZAP_AUTH_PASS.", file=sys.stderr)
            print(f'    (login page said: "{err}")', file=sys.stderr)
            return 2
        first = (str(e).splitlines() or [""])[0]
        print(f"ERROR during login: {type(e).__name__}: {first}", file=sys.stderr)
        try:
            print(f"  final URL : {driver.current_url}", file=sys.stderr)
            print(f"  page title: {driver.title}", file=sys.stderr)
            inputs = driver.execute_script(
                "return JSON.stringify(Array.from(document.querySelectorAll('input'))"
                ".map(function(i){return {type:i.type,id:i.id,name:i.name};}));")
            print(f"  inputs on page: {inputs}", file=sys.stderr)
            txt = driver.execute_script(
                "return document.body ? document.body.innerText.slice(0,600) : '';")
            print("  visible text (first 600 chars):", file=sys.stderr)
            print(txt, file=sys.stderr)
        except Exception:
            pass
        return 1
    finally:
        driver.quit()


if __name__ == "__main__":
    raise SystemExit(main())
