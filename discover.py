#!/usr/bin/env python3
"""discover.py — record-mode helper that bootstraps target.env for this ZAP DAST tool.

Opens a REAL (visible) browser and asks you to log in by hand. While you do, it
records what it needs so you don't have to dig through DevTools:

  - the login selectors you interact with  -> BTN_XPATH / USER_SEL / PASS_SEL
  - the auth token in localStorage         -> TOKEN_KEY
  - the API origin + auth header from real requests -> API_URL / AUTH_HEADER / AUTH_PREFIX
  - a candidate authenticated endpoint + a stable field in its body -> VERIFY_URL / LOGGEDIN_REGEX

It then PRINTS a draft target.env to the console (it never touches your real target.env).
Everything is a best guess — skim it, fix the TODO lines, and paste what you want into target.env.
The draft goes to stdout and all messages to stderr, so `> target.env.discovered` gives a clean file.

Run on your HOST (needs a desktop + Chrome) — NOT headless / in Docker:

    pip install selenium
    python discover.py https://your-app.example.com/landing

argv[1] is the page with the "Log In" button (your LOGIN_URL).
"""
import json
import re
import sys
from urllib.parse import urlparse

try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
except ImportError:
    sys.exit("ERROR: Selenium is required on the host — run: pip install selenium")

JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")

# Injected into every document (incl. the IdP page) via CDP, so it survives the
# cross-origin hops of an Auth0-style login. It logs each meaningful interaction
# as a console line we pick up from the browser log.
RECORDER_JS = r"""
(function(){
  if (window.__discAttached) return; window.__discAttached = true;
  function css(el){
    if(!el||el.nodeType!==1) return '';
    if(el.id) return '#'+CSS.escape(el.id);
    var n=el.getAttribute&&el.getAttribute('name');
    if(n) return el.tagName.toLowerCase()+'[name="'+n+'"]';
    var t=el.getAttribute&&el.getAttribute('type');
    if(t) return el.tagName.toLowerCase()+'[type="'+t+'"]';
    return el.tagName.toLowerCase();
  }
  function xp(el){
    var txt=(el.textContent||'').replace(/\s+/g,' ').trim();
    if(txt && txt.length<=40) return "//"+el.tagName.toLowerCase()+"[normalize-space()='"+txt.replace(/'/g,'')+"']";
    if(el.id) return "//*[@id='"+el.id+"']";
    return '';
  }
  function emit(kind,el,extra){
    try{ console.log("__DISC__|"+kind+"|"+location.origin+"|"+css(el)+"|"+(extra||"")); }catch(e){}
  }
  document.addEventListener('input', function(e){
    var el=e.target; if(!el||el.tagName!=='INPUT') return;
    var t=(el.getAttribute('type')||'text').toLowerCase();
    if(t==='password') emit('pass',el,'');
    else if(t==='email'||t==='text'||t==='tel') emit('user',el,'');
  }, true);
  document.addEventListener('click', function(e){
    var b=e.target && e.target.closest ? e.target.closest("button,[type=submit],[role=button],a") : null;
    if(b) emit('btn', b, xp(b));
  }, true);
})();
"""


def make_driver():
    opts = Options()
    opts.add_argument("--window-size=1280,900")
    # Capture network (performance) + console (browser) logs.
    opts.set_capability("goog:loggingPrefs", {"performance": "ALL", "browser": "ALL"})
    driver = webdriver.Chrome(options=opts)  # Selenium Manager resolves the driver
    driver.execute_cdp_cmd("Network.enable", {})  # so getResponseBody works later
    driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {"source": RECORDER_JS})
    return driver


def recorded_selectors(driver):
    """Drain the browser console log for the recorder's __DISC__ lines."""
    user_sel = pass_sel = btn_xpath = None
    for entry in driver.get_log("browser"):
        for hit in re.findall(r"__DISC__\|[^\"]*", entry.get("message", "")):
            parts = hit.split("|")
            if len(parts) < 4:
                continue
            kind, origin, css_sel, extra = parts[1], parts[2], parts[3], (parts[4] if len(parts) > 4 else "")
            if kind == "user" and css_sel:
                user_sel = css_sel          # last email/text field wins
            elif kind == "pass" and css_sel:
                pass_sel = css_sel          # last password field wins
            elif kind == "btn" and btn_xpath is None:
                btn_xpath = extra or ""     # FIRST button click = the landing "Log In"
    return user_sel, pass_sel, btn_xpath


def network(driver):
    """Parse the performance log into request/response tables."""
    reqs, resps = {}, {}
    for entry in driver.get_log("performance"):
        try:
            msg = json.loads(entry["message"])["message"]
        except Exception:
            continue
        method, p = msg.get("method"), msg.get("params", {})
        rid = p.get("requestId")
        if method == "Network.requestWillBeSent":
            r = p.get("request", {})
            reqs[rid] = {"url": r.get("url", ""), "method": r.get("method", ""), "headers": r.get("headers", {})}
        elif method == "Network.responseReceived":
            resp = p.get("response", {})
            resps[rid] = {"status": resp.get("status"), "mime": resp.get("mimeType", ""), "url": resp.get("url", "")}
    return reqs, resps


def origin(url):
    u = urlparse(url)
    return f"{u.scheme}://{u.netloc}" if u.scheme and u.netloc else ""


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: python discover.py <LOGIN_URL>   (the page with the Log In button)")
    login_url = sys.argv[1]

    driver = make_driver()
    try:
        driver.get(login_url)
        print("\n=== A browser window opened. Log in normally there. ===", file=sys.stderr)
        print("When you're fully logged in (you can see your app's authenticated page),", file=sys.stderr)
        print("come back here and press Enter to capture the config... ", end="", file=sys.stderr, flush=True)
        input()

        start_url = driver.current_url
        app_origin = origin(start_url) or origin(login_url)
        user_sel, pass_sel, btn_xpath = recorded_selectors(driver)
        reqs, resps = network(driver)

        # localStorage token -> TOKEN_KEY
        ls = driver.execute_script(
            "var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k);}return o;"
        ) or {}
        token_key, token_note = None, ""
        for k, v in ls.items():
            if isinstance(v, str) and JWT_RE.search(v):
                token_key = k
                if not v.strip().startswith("eyJ"):
                    token_note = "  # TODO: token is nested inside this value, not the whole value"
                break

        # Find the auth header + API origin from a request that carries the JWT.
        api_url = auth_header = auth_prefix = None
        for rid, r in reqs.items():
            host = origin(r["url"])
            if not host or host == app_origin:
                continue
            for hk, hv in r["headers"].items():
                if isinstance(hv, str) and JWT_RE.search(hv):
                    auth_header = hk
                    cut = hv.find("eyJ")
                    auth_prefix = hv[:cut]            # e.g. "Bearer " or ""
                    api_url = host
                    break
            if api_url:
                break

        # Candidate verify endpoint: a 200 JSON GET on the API host; prefer identity-ish paths.
        verify_url, logged_in_regex = None, None
        cands = []
        for rid, r in reqs.items():
            resp = resps.get(rid)
            if not resp or r["method"] != "GET" or resp.get("status") != 200:
                continue
            if api_url and origin(r["url"]) != api_url:
                continue
            if "json" in (resp.get("mime") or ""):
                cands.append((rid, r["url"]))
        cands.sort(key=lambda c: 0 if re.search(r"profile|/me\b|user|account|session|whoami", c[1], re.I) else 1)
        if cands:
            rid, verify_url = cands[0]
            try:
                body = driver.execute_cdp_cmd("Network.getResponseBody", {"requestId": rid})
                data = json.loads(body.get("body", ""))
                if isinstance(data, dict):
                    for key, val in data.items():           # a stable, present top-level key
                        if val is not None and not isinstance(val, (list, dict)):
                            logged_in_regex = key
                            break
            except Exception:
                pass

        write_output(login_url, app_origin, start_url, user_sel, pass_sel, btn_xpath,
                     token_key, token_note, api_url, auth_header, auth_prefix,
                     verify_url, logged_in_regex)
    finally:
        driver.quit()


def field(name, value, todo):
    """Emit KEY="value" or a commented TODO placeholder when we couldn't find it."""
    return f'{name}="{value}"' if value else f'# {name}=  # TODO: {todo}'


def write_output(login_url, app_origin, start_url, user_sel, pass_sel, btn_xpath,
                 token_key, token_note, api_url, auth_header, auth_prefix,
                 verify_url, logged_in_regex):
    # Template VERIFY_URL against ${API_URL} when it's on the API host.
    verify_line = None
    if verify_url and api_url and verify_url.startswith(api_url):
        verify_line = 'VERIFY_URL="${API_URL}' + verify_url[len(api_url):] + '"'
    elif verify_url:
        verify_line = f'VERIFY_URL="{verify_url}"'

    ctx = urlparse(app_origin).netloc.split(".")[0].capitalize() if app_origin else "MyApp"
    lines = [
        "# target.env.discovered — generated by discover.py. Best guesses; review the",
        "# TODO lines, then:  cp target.env.discovered target.env",
        f"# (login page recorded: {login_url})",
        "",
        "# --- URLs ---",
        field("APP_URL", app_origin, "your app's base origin"),
        field("API_URL", api_url, "no API request with the token was seen — check DevTools > Network"),
        f'LOGIN_URL="{login_url}"',
        field("START_URL", start_url, "an authenticated page to start crawling from"),
        "",
        "# --- Login form (verify these against the actual elements) ---",
        (f'BTN_XPATH="{btn_xpath}"' if btn_xpath else "# BTN_XPATH=  # TODO: XPath of the Log In button"),
        field("USER_SEL", user_sel, "CSS selector of the email/username input"),
        field("PASS_SEL", pass_sel, "CSS selector of the password input"),
        "",
        "# --- Token ---",
        (f'TOKEN_KEY="{token_key}"{token_note}' if token_key
         else "# TOKEN_KEY=  # TODO: localStorage key holding the JWT (value starts eyJ)"),
        "",
        "# --- How the token is sent ---",
        field("AUTH_HEADER", auth_header, "request header carrying the token (usually Authorization)"),
        (f'AUTH_PREFIX="{auth_prefix}"' if auth_prefix is not None
         else '# AUTH_PREFIX="Bearer "  # TODO: text before the token, incl. trailing space'),
        "",
        "# --- Logged-in check ---",
        (verify_line if verify_line else "# VERIFY_URL=  # TODO: a small authenticated API endpoint (200 with token)"),
        (f'LOGGEDIN_REGEX="{logged_in_regex}"' if logged_in_regex
         else "# LOGGEDIN_REGEX=  # TODO: a stable string in the 200 body, absent on 401/403"),
        "",
        "# --- Naming ---",
        f'CONTEXT_NAME="{ctx}"',
        "",
    ]
    found = sum(x is not None and x != "" for x in
                [app_origin, api_url, start_url, btn_xpath, user_sel, pass_sel,
                 token_key, auth_header, auth_prefix, verify_url, logged_in_regex])
    # Draft -> stdout (so `> target.env.discovered` is clean); summary -> stderr.
    print(f"\n==> Draft target.env ({found}/11 values auto-detected) — review the TODO lines:\n",
          file=sys.stderr)
    print("\n".join(lines))
    print(f"\n==> {found}/11 auto-detected. Paste what you want into target.env "
          "(or re-run with '> target.env.discovered' to save).", file=sys.stderr)


if __name__ == "__main__":
    main()
