#!/usr/bin/env bash
# The browser smoke: the Dot's real browser. The engine, dot-agentd, the relay, the desktop (the
# runtime disk's dot-desktop script: Xvfb on :0 and an XFCE session) and the MCP server are the
# real ones; the browser is the Firefox that `invisible-playwright fetch` cached, started by
# invisible-playwright-mcp as dot. Only the model is a stand-in (fake_openrouter.py), and the
# internet is as the runner has it: the browser needs it once at a launch (the egress address,
# for the timezone), and the pages it opens are served from this container.
# smoke.sh's own browser section runs the same seams against a fake server and no Firefox; what
# only the real server can show is here: a page read, a screenshot that is a real picture and
# crosses the relay whole, a profile that keeps its seed, a profile lock left by kill -9.
#
# prepare-engine.sh has built the engine's environment and, for this suite, the golden image's apt
# packages and the release of the browser before the newest (runtime/dot-browser.sh), which the
# first checks bring to the newest as a Dot's starts do. Exits non-zero when a check failed or was
# skipped, and always prints
#   SMOKE: <passed> passed, <failed> failed, <skipped> skipped
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
set -uo pipefail
source "$HERE/../lib.sh"
RUNTIME=$HERE/../../../runtime
# A real launch downloads nothing but may wait for the network: events are waited for longer here.
WAIT_EVENT_S=240

# --- the Dot's browser brought to the newest release, as install.sh does at a Dot's starts ---
# One start stages the newest release beside the Dot's (dot-browser stage, in the background there), the next one
# switches to it before the units start (dot-browser switch). Everything below runs on what the switch left.
DOT_BROWSER=$RUNTIME/dot-browser.sh
BROWSERS=/home/dot/.local/share/invisible-dots/browser
server_env() { dirname "$(dirname "$(readlink -f /home/dot/.local/bin/invisible-playwright-mcp)")"; }
release_in() { su -s /bin/sh dot -c "$1/bin/python -c 'import importlib.metadata as m; print(m.version(\"invisible-playwright-mcp\"), m.version(\"invisible-playwright\"), m.version(\"invisible-core\"))'"; }
NEWEST=$(bash "$DOT_BROWSER" newest)
BEFORE_ENV=$(server_env)
check "the Dot starts on the release before the newest" "[ \"\$(release_in \"$BEFORE_ENV\")\" != \"$NEWEST\" ]"
check "a stage builds the newest beside it and leaves the Dot's browser as it was until a switch" \
  "bash $DOT_BROWSER stage && [ -L $BROWSERS/next ] && [ \"\$(server_env)\" = \"$BEFORE_ENV\" ] && [ \"\$(release_in \$(readlink -f $BROWSERS/next))\" = \"$NEWEST\" ]"
check "a second stage finds the newest staged already and builds nothing" \
  "bash $DOT_BROWSER stage 2>&1 | grep -q 'staged already' && [ \$(ls -d $BROWSERS/*/ | wc -l) = 3 ]"
check "the switch makes the newest the Dot's browser, removes the release before it and leaves nothing staged" \
  "bash $DOT_BROWSER switch && [ \"\$(release_in \$(server_env))\" = \"$NEWEST\" ] && [ ! -e $BROWSERS/next ] && [ ! -e \"$BEFORE_ENV\" ] && [ \$(ls -d $BROWSERS/*/ | wc -l) = 1 ]"
check "a stage on the newest builds nothing, and a switch with nothing staged changes nothing" \
  "bash $DOT_BROWSER stage 2>&1 | grep -q 'is the newest release' && bash $DOT_BROWSER switch && [ ! -e $BROWSERS/next ] && [ \"\$(release_in \$(server_env))\" = \"$NEWEST\" ]"

lay_out_guest
write_host_token
start_fake_openrouter

# --- the desktop, as dot-desktop.service runs it ---
# A system service has no login session: lingering gives dot a /run/user/<uid> (install.sh).
DOT_UID=$(id -u dot)
install -d -o dot -g dot -m 0700 "/run/user/$DOT_UID"
install -D -m 0755 "$RUNTIME/dot-desktop.sh" /opt/invisible-dots/bin/dot-desktop
su -s /bin/bash dot -c "HOME=/home/dot DISPLAY=:0 DOT_SCREEN=1920x1080x24 PATH=$DOT_PATH /opt/invisible-dots/bin/dot-desktop" > /tmp/desktop.log 2>&1 &
wait_display() { for _ in $(seq 1 60); do [ -S /tmp/.X11-unix/X0 ] && pgrep -u dot -x xfwm4 >/dev/null && return 0; sleep 1; done; return 1; }
check "the desktop is up: Xvfb on :0 and an XFCE session with its window manager, all dot's" "wait_display && pgrep -u dot -x Xvfb >/dev/null && ! pgrep -u root -x Xvfb >/dev/null"

# --- the pages the browser opens: served from this container, by nobody ---
SITE=/srv/browser-smoke
mkdir -p "$SITE"
cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<title>Browser smoke</title>
<body style="margin:0;background:#ff00ff">
<h1 id="heading">Smoke heading 7f3a9c</h1>
<p>A second line of text on the page.</p>
</body>
HTML
# A page that keeps a value in the profile (localStorage) under the key its URL names and shows what an
# earlier visit left there.
cat > "$SITE/store.html" <<'HTML'
<!doctype html>
<title>Store</title>
<body><p id="out"></p>
<script>
const key = "smoke-" + new URLSearchParams(location.search).get("k");
const before = localStorage.getItem(key);
if (before === null) localStorage.setItem(key, "kept-" + new URLSearchParams(location.search).get("k"));
document.getElementById("out").textContent = "stored before: " + (before === null ? "nothing" : before);
</script>
</body>
HTML
# A page of 1000x600 random pixels: its screenshot is a PNG of about 1.8 MB, base64 of about 2.4 MB.
cat > "$SITE/noise.html" <<'HTML'
<!doctype html>
<title>Noise</title>
<body style="margin:0"><canvas id="c" width="1000" height="600"></canvas>
<script>
const c = document.getElementById("c"), x = c.getContext("2d"), d = x.createImageData(1000, 600);
for (let i = 0; i < d.data.length; i += 4) {
  d.data[i] = Math.random() * 256; d.data[i + 1] = Math.random() * 256; d.data[i + 2] = Math.random() * 256; d.data[i + 3] = 255;
}
x.putImageData(d, 0, 0);
</script>
</body>
HTML
chmod -R a+rX "$SITE"
PAGES=http://127.0.0.1:8088
su -s /bin/bash nobody -c "python3 -m http.server 8088 --bind 127.0.0.1 --directory $SITE" > /tmp/pages.log 2>&1 &
pages_up() { for _ in $(seq 1 20); do curl -fsS "$PAGES/index.html" 2>/dev/null | grep -q 'Smoke heading 7f3a9c' && return 0; sleep 0.5; done; return 1; }
check "the pages are served" "pages_up"

# --- the Dot: dot-agentd, and the engine with no browser program named, so it finds the real one on its PATH ---
unset MCP_COMMAND
start_guest_daemons
init_host_side
check "the engine answers /health through dot-agentd" "wait_health"
check "invisible-playwright-mcp is on dot's PATH, where the golden image links it" "[ \"\$(su -s /bin/bash dot -c 'PATH=$DOT_PATH command -v invisible-playwright-mcp')\" = /home/dot/.local/bin/invisible-playwright-mcp ]"
reset_config
echo '{"computer.exec":"allow","computer.screenshot":"allow","browser.identity.list":"allow","browser.identity.create":"allow","browser.identity.delete":"allow","browser.identity.launch":"allow","browser.identity.close":"allow","browser.navigate":"allow","browser.read":"allow","browser.act":"allow"}' > /tmp/perms.json
write_push_script
check "the host pushes the key and a config where the Dot browses (204 204)" "[ \"\$(push)\" = '204 204' ]"
sleep 3
start_host_stream

BROWSERS=/home/dot/browsers
MCP_HOMES=/var/lib/invisible-dots/mcp   # the servers' homes, outside /home/dot (architecture 4.2)
FIREFOX='\.cache/invisible-playwright/firefox-'   # what the cached engine's processes are called
firefox_running() { pgrep -u dot -f "$FIREFOX" | wc -l; }
# A process's environment is read by its own user only (the container's root has no CAP_SYS_PTRACE), so what runs
# as dot is read as dot: this lists "pid command line" of the processes whose environment names an identity (the
# MCP server and what it started).
cat > /tmp/session-processes.sh <<'SCRIPT'
#!/bin/bash
for p in /proc/[0-9]*; do
  if { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qx "INVISIBLE_MCP_SESSION_ID=$1"; then echo "${p#/proc/} $(tr '\0' ' ' < "$p/cmdline")"; fi
done
exit 0
SCRIPT
chmod 0644 /tmp/session-processes.sh
session_processes() { su -s /bin/bash dot -c "bash /tmp/session-processes.sh '$1'"; } # id
session_pids() { session_processes "$1" | cut -d' ' -f1; } # id
# The MCP server's own process: the python that runs invisible-playwright-mcp.
mcp_pid_of() { session_processes "$1" | grep -E '^[0-9]+ [^ ]*/bin/python[0-9.]* .*invisible-playwright-mcp' | head -1 | cut -d' ' -f1; } # id
launched_times() { # id, n: the identity has been launched n times by now
  for _ in $(seq 1 "$WAIT_EVENT_S"); do
    [ "$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -s "[.[] | select(.type==\"browser.identity.launched\" and .data.identity_id==\"$1\")] | length")" = "$2" ] && return 0
    sleep 1
  done
  return 1
}
tool_ok() { wait_event $STREAM ".type==\"tool.called\" and .data.tool==\"$1\" and .data.ok==true and (.data.target|startswith(\"$2\"))"; } # tool, target prefix
tool_ok_times() { # tool, n: the tool has been called ok at least n times by now
  for _ in $(seq 1 "$WAIT_EVENT_S"); do
    [ "$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -s "[.[] | select(.type==\"tool.called\" and .data.tool==\"$1\" and .data.ok==true)] | length")" -ge "$2" ] && return 0
    sleep 1
  done
  return 1
}
# A tool result the stand-in model was sent (whole, from its log): some request carried a tool message holding it.
sent_to_model() { jq -s -e --arg t "$1" 'any(.[]; [.messages[]? | select(.role == "tool") | (.content | if type == "string" then . else tostring end)] | any(contains($t)))' "$FULL" >/dev/null; }
# The newest image the model was sent, decoded.
last_image() { # output file
  jq -s -r '[.[] | .messages[]? | .content? | arrays | .[] | select(.type == "image_url") | .image_url.url] | last // empty' "$FULL" | sed 's/^data:image\/png;base64,//' | base64 -d > "$1"
}
magenta_pixels() { convert "$1" -depth 8 txt:- | grep -c '#FF00FF'; } # the page's own color, in a picture
png_is() { [ "$(identify -format '%m' "$1[0]" 2>/dev/null)" = PNG ]; }
seed_of() { sha256sum "$BROWSERS/$1/profile/.stealth-identity.json" | cut -d' ' -f1; }

# --- an identity, launched by the model: the real server starts the real Firefox on the desktop ---
CODE1=$(api -o /tmp/bid-1.json -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"name":"research"}' "$A/browser-identities")
ID=$(jq -r .id /tmp/bid-1.json)
check "POST /browser-identities answers 201 with a closed identity under /home/dot/browsers" "[ '$CODE1' = 201 ] && jq -e --arg id '$ID' '.status == \"available\" and .profilePath == (\"/home/dot/browsers/\" + \$id + \"/profile\")' /tmp/bid-1.json >/dev/null"
check "no browser runs for a closed identity" "[ \"\$(firefox_running)\" = 0 ]"
check "the model launches the identity: the real server answers that its browser is open" "tool_turn 1 browser_identity_launch '{\"identity_id\":\"$ID\"}' && launched_times $ID 1"
check "tool.called browser_identity_launch: ok" "tool_ok_times browser_identity_launch 1"
echo "processes of dot after the launch:"; ps -o pid,ppid,user,etimes,args -u dot | cut -c1-200
check "Firefox runs as dot, from the engine the image cached, and nothing of the browser runs as dotengine" "[ \"\$(firefox_running)\" -ge 1 ] && ! pgrep -u dotengine -f \"$FIREFOX\" >/dev/null && ! pgrep -u dotengine -f 'bin/python.*invisible-playwright-mcp' >/dev/null"
MCP_PID=$(mcp_pid_of "$ID")
mcp_env_ok() {
  local env; env=$(su -s /bin/bash dot -c "tr '\\0' '\\n' < /proc/$MCP_PID/environ")
  [ "$(stat -c %U "/proc/$MCP_PID")" = dot ] \
    && grep -qx "STEALTHFOX_PROFILE_DIR=$BROWSERS/$ID/profile" <<< "$env" \
    && grep -qx "INVISIBLE_MCP_HOME=$MCP_HOMES/$ID" <<< "$env" \
    && grep -qx 'STEALTHFOX_HEADLESS=0' <<< "$env" && grep -qx 'DISPLAY=:0' <<< "$env" && grep -qx 'HOME=/home/dot' <<< "$env" \
    && grep -qx 'INVISIBLE_CORE_AUTOFIX=off' <<< "$env" \
    && ! grep -q '^STEALTHFOX_PROXY=' <<< "$env" \
    && ! grep -q '^INVISIBLE_DOTS_\|^TIKTOKEN_CACHE_DIR=\|^OPENROUTER_API_KEY=' <<< "$env" \
    && ! grep -qF "$KEY" <<< "$env"
}
check "the server's process is dot's, with the profile, its home, a real window on :0, no proxy of its own (an identity with none, the default, inherits the VM's egress) and none of the engine's variables nor the key" "[ -n '$MCP_PID' ] && mcp_env_ok"
check "the profile has its seed file after the first open" "[ -s $BROWSERS/$ID/profile/.stealth-identity.json ]"
SEED1=$(seed_of "$ID" 2>/dev/null)
echo "seed file: $SEED1"
check "/health counts one identity, one open" "health_is 1 1"

# --- a page: navigate, read, snapshot ---
check "the model opens a page of the container" "tool_turn 2 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/index.html\"}' && tool_ok browser_navigate '$ID: $PAGES/index.html'"
check "the pages' server saw the browser's request" "grep -q 'GET /index.html' /tmp/pages.log"
check "the model reads the page's text: the heading reached the model" "tool_turn 3 browser_read_text '{\"identity_id\":\"$ID\"}' && tool_ok_times browser_read_text 1 && sent_to_model 'Smoke heading 7f3a9c'"
check "the model asks for the page's elements: the title reached the model" "tool_turn 4 browser_snapshot '{\"identity_id\":\"$ID\"}' && sent_to_model 'Browser smoke'"

# --- a screenshot: a real picture, accepted by the engine, in the next request as an image part ---
check "the model takes a screenshot of the page" "tool_turn 5 browser_take_screenshot '{\"identity_id\":\"$ID\"}' && tool_ok browser_take_screenshot '$ID'"
last_image /tmp/shot-page.png
echo "screenshot of the page: $(identify /tmp/shot-page.png 2>&1 | cut -c1-120)"
check "the screenshot the model was sent is a PNG of a page" "png_is /tmp/shot-page.png && [ \"\$(identify -format '%w' /tmp/shot-page.png)\" -ge 200 ] && [ \"\$(identify -format '%h' /tmp/shot-page.png)\" -ge 200 ]"
check "it shows the page: most of it is the page's own color, and it is no blank picture" "[ \"\$(magenta_pixels /tmp/shot-page.png)\" -gt 50000 ] && [ \"\$(convert /tmp/shot-page.png -format %k info:)\" -gt 2 ]"
check "the stored transcript keeps no picture: the engine's database holds no PNG, only the placeholder" "! grep -a -q iVBORw0KGgo /home/dotengine/state/engine.sqlite* && grep -a -q 'not stored' /home/dotengine/state/engine.sqlite*"

# --- the relay carries a message of megabytes: the screenshot of random noise ---
check "the model opens a page of random pixels and takes a screenshot of it" "tool_turn 6 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/noise.html\"}' && tool_turn 7 browser_take_screenshot '{\"identity_id\":\"$ID\"}'"
last_image /tmp/shot-noise.png
echo "screenshot of the noise: $(ls -l /tmp/shot-noise.png | awk '{print $5}') bytes"
check "that picture crossed the relay whole: a valid PNG of more than 500 kB" "png_is /tmp/shot-noise.png && [ \"\$(stat -c %s /tmp/shot-noise.png)\" -gt 500000 ] && identify /tmp/shot-noise.png >/dev/null 2>&1"
check "the server still answers after it: the model reads the page again" "tool_turn 8 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/index.html\"}' && tool_turn 9 browser_read_text '{\"identity_id\":\"$ID\"}' && tool_ok_times browser_read_text 2"

# --- the computer's screenshot shows the browser's window (dot-agentd's GET /v1/screenshot) ---
api -o /tmp/shot-screen.png -w '%{http_code}' http://127.0.0.1:1024/v1/screenshot > /tmp/shot-screen.code
echo "desktop screenshot: $(identify /tmp/shot-screen.png 2>&1 | cut -c1-120)"
check "GET /v1/screenshot answers a PNG of the whole desktop" "[ \"\$(cat /tmp/shot-screen.code)\" = 200 ] && png_is /tmp/shot-screen.png && [ \"\$(identify -format '%w x %h' /tmp/shot-screen.png)\" = '1920 x 1080' ]"
check "it is not blank: the page the browser shows is in it" "[ \"\$(magenta_pixels /tmp/shot-screen.png)\" -gt 50000 ]"

# --- the host's frame of the identity's window (the server's browser_watch) ---
api -o /tmp/frame.jpg -w '%{http_code}' "$A/browser-identities/$ID/frame" > /tmp/frame.code
echo "frame of the identity: $(identify /tmp/frame.jpg 2>&1 | cut -c1-120)"
check "GET /browser-identities/:id/frame answers a JPEG of the identity's window, not a blank one" "[ \"\$(cat /tmp/frame.code)\" = 200 ] && [ \"\$(identify -format '%m' /tmp/frame.jpg[0] 2>/dev/null)\" = JPEG ] && [ \"\$(identify -format '%w' /tmp/frame.jpg[0])\" -ge 200 ] && [ \"\$(convert /tmp/frame.jpg -format %k info:)\" -gt 2 ]"

# --- close and relaunch: the profile keeps its seed and what a page stored ---
check "the model has a page store a value in the profile (localStorage, key close)" "tool_turn 20 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/store.html?k=close\"}' && tool_turn 21 browser_read_text '{\"identity_id\":\"$ID\"}' && sent_to_model 'stored before: nothing'"
check "the model closes the identity: Firefox and its server end" "tool_turn 10 browser_identity_close '{\"identity_id\":\"$ID\"}' && closed $ID && gone_within 20 \"$FIREFOX\" && [ -z \"\$(session_pids $ID)\" ]"
check "/health counts one identity, none open" "health_is 1 0"
check "the frame of the closed identity is 409 not_open, and the host's close of it is a 204 that changes nothing" "[ \"\$(api -o /dev/null -w '%{http_code}' $A/browser-identities/$ID/frame)\" = 409 ] && [ \"\$(api -o /dev/null -w '%{http_code}' -X POST $A/browser-identities/$ID/close)\" = 204 ] && health_is 1 0"
echo "profile after the model's close:"; ls -la "$BROWSERS/$ID/profile" | grep -i 'lock' || echo "  (no lock file)"
check "the profile still has its seed file, unchanged by the close" "[ \"\$(seed_of $ID)\" = '$SEED1' ]"
check "the model launches it again" "tool_turn 11 browser_identity_launch '{\"identity_id\":\"$ID\"}' && launched_times $ID 2"
check "the seed file is identical after the relaunch: the identity is the same one" "[ \"\$(seed_of $ID)\" = '$SEED1' ]"
check "the relaunched browser works: the model reads the page" "tool_turn 12 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/index.html\"}' && tool_turn 13 browser_read_text '{\"identity_id\":\"$ID\"}' && tool_ok_times browser_read_text 4"
check "what the page stored before the close is in the profile after it (the model's close let Firefox flush)" "tool_turn 22 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/store.html?k=close\"}' && tool_turn 23 browser_read_text '{\"identity_id\":\"$ID\"}' && sent_to_model 'stored before: kept-close'"

# --- kill -9 in the middle of a session: the profile lock is stale, and the next launch must live with it ---
pkill -9 -u dotengine
check "kill -9 of the engine ended the server and Firefox (dot-agentd ended their process group)" "gone_within 20 \"$FIREFOX\" && [ -z \"\$(session_pids $ID)\" ]"
echo "profile after kill -9:"; ls -la "$BROWSERS/$ID/profile" | grep -i 'lock' || echo "  (no lock file)"
check "the killed Firefox left its profile locked (a lock file or symlink is there)" "[ -e $BROWSERS/$ID/profile/.parentlock ] || [ -L $BROWSERS/$ID/profile/lock ]"
start_engine
check "the restarted engine answers /health, and the identity is available, not open" "wait_health && wait_key && [ \"\$(api $A/browser-identities/$ID | jq -r .status)\" = available ]"
check "the model launches the identity whose profile is locked by a process that is gone" "tool_turn 14 browser_identity_launch '{\"identity_id\":\"$ID\"}' && launched_times $ID 3"
check "the seed file is still the same after the kill and the launch" "[ \"\$(seed_of $ID)\" = '$SEED1' ]"
check "the launched browser works: the model reads the page again" "tool_turn 15 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/index.html\"}' && tool_turn 16 browser_read_text '{\"identity_id\":\"$ID\"}' && tool_ok_times browser_read_text 6"

# --- SIGTERM: the browser is asked to close, so Firefox can flush its profile ---
check "the model has a page store a value in the profile (localStorage, key term)" "tool_turn 24 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/store.html?k=term\"}' && tool_turn 25 browser_read_text '{\"identity_id\":\"$ID\"}'"
EPID=$(pgrep -o -u dotengine -f 'python.*-m nanobot')
kill -TERM "$EPID"
for _ in $(seq 1 300); do kill -0 "$EPID" 2>/dev/null || break; sleep 0.1; done
check "SIGTERM stopped the engine, and Firefox and its server ended with it" "! kill -0 $EPID 2>/dev/null && gone_within 30 \"$FIREFOX\" && [ -z \"\$(session_pids $ID)\" ]"
echo "profile after SIGTERM:"; ls -la "$BROWSERS/$ID/profile" | grep -i 'lock' || echo "  (no lock file)"
start_engine
check "the restarted engine answers /health" "wait_health && wait_key"
check "the model launches the identity again after SIGTERM" "tool_turn 26 browser_identity_launch '{\"identity_id\":\"$ID\"}' && launched_times $ID 4"
check "what the page stored before SIGTERM is in the profile after it (SIGTERM made the browser close, so Firefox flushed)" "tool_turn 27 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/store.html?k=term\"}' && tool_turn 28 browser_read_text '{\"identity_id\":\"$ID\"}' && sent_to_model 'stored before: kept-term'"

# --- Firefox dies under a live server: the model is told, and nothing is reopened or repeated behind its back ---
closed_times() { # id, n: the identity has been closed n times by now
  for _ in $(seq 1 "$WAIT_EVENT_S"); do
    [ "$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -s "[.[] | select(.type==\"browser.identity.closed\" and .data.identity_id==\"$1\")] | length")" = "$2" ] && return 0
    sleep 1
  done
  return 1
}
no_server_within() { for _ in $(seq 1 "$(($1*5))"); do [ -z "$(session_pids "$2")" ] && return 0; sleep 0.2; done; return 1; } # seconds, id
tool_ok_count() { grep '^data: ' $STREAM | sed 's/^data: //' | jq -s "[.[] | select(.type==\"tool.called\" and .data.tool==\"$1\" and .data.ok==true)] | length"; } # tool
check "the model has the identity on a page" "tool_turn 30 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/index.html\"}'"
pkill -9 -u dot -f "$FIREFOX"
check "Firefox was killed under the identity, and the server's process lives on (the browser is gone, the server is not)" "gone_within 20 \"$FIREFOX\" && [ -n \"\$(session_pids $ID)\" ]"
check "the model's next page action is answered with the library's meaning in the Dot's words: the browser is gone, launch the identity again" "tool_turn 31 browser_read_text '{\"identity_id\":\"$ID\"}' && sent_to_model 'is gone: it closed or crashed' && sent_to_model 'call browser_identity_launch to open it again'"
check "that call is a failed tool.called, and nothing was reopened for it (no Firefox)" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_read_text\" and .data.ok==false' && [ \"\$(firefox_running)\" = 0 ]"
check "the identity is closed: browser.identity.closed again, its server ended, /health counts none open" "closed_times $ID 3 && no_server_within 30 $ID && health_is 1 0 && [ \"\$(api $A/browser-identities/$ID | jq -r .status)\" = available ]"
check "the model launches it again: the same person (the seed file is unchanged) and its browser works" "tool_turn 32 browser_identity_launch '{\"identity_id\":\"$ID\"}' && launched_times $ID 5 && [ \"\$(seed_of $ID)\" = '$SEED1' ] && tool_turn 33 browser_navigate '{\"identity_id\":\"$ID\",\"url\":\"$PAGES/index.html\"}' && tool_turn 34 browser_read_text '{\"identity_id\":\"$ID\"}' && tool_ok_times browser_read_text $(($(tool_ok_count browser_read_text) + 1))"

# --- an identity with a proxy: the library reads it, and where does the password of one that works end up? ---
PROXY_USER=smoke-user
PROXY_PASSWORD=Pw7c1dSmokeReal
install -m 0644 "$HERE/proxy.py" /tmp/proxy.py
PROXY_USER=$PROXY_USER PROXY_PASSWORD=$PROXY_PASSWORD su -p -s /bin/bash nobody -c "python3 /tmp/proxy.py 8099" > /tmp/proxy.log 2>&1 &
proxy_up() { for _ in $(seq 1 20); do (exec 3<>/dev/tcp/127.0.0.1/8099) 2>/dev/null && return 0; sleep 0.5; done; return 1; }
check "the authenticating proxy of the smoke is up" "proxy_up"
check "a proxy is not judged at create: one the library cannot use (no port) is kept as written, and the answer says only that the identity has one" "[ \"\$(api -o /tmp/bid-noport.json -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{\"name\":\"noport\",\"proxy\":\"http://$PROXY_USER:$PROXY_PASSWORD@127.0.0.1\"}' $A/browser-identities)\" = 201 ] && jq -e '.hasProxy == true and (has(\"proxy\") | not)' /tmp/bid-noport.json >/dev/null && ! grep -qF $PROXY_PASSWORD /tmp/bid-noport.json"
NOPORT=$(jq -r .id /tmp/bid-noport.json)
check "the model's launch of it fails with the library's own refusal, which names the missing port" "tool_turn 39 browser_identity_launch '{\"identity_id\":\"$NOPORT\"}' && sent_to_model 'has no port' && [ -z \"\$(session_pids $NOPORT)\" ]"
check "the host deletes it: nothing of it is left but its events" "[ \"\$(api -o /dev/null -w '%{http_code}' -X DELETE $A/browser-identities/$NOPORT)\" = 204 ] && [ ! -e $BROWSERS/$NOPORT ] && [ ! -e $MCP_HOMES/$NOPORT ] && [ \"\$(api $A/browser-identities | jq '.identities | length')\" = 1 ]"
CODE2=$(api -o /tmp/bid-2.json -w '%{http_code}' -X POST -H 'content-type: application/json' -d "{\"name\":\"proxied\",\"proxy\":\"http://$PROXY_USER:$PROXY_PASSWORD@127.0.0.1:8099\"}" "$A/browser-identities")
ID2=$(jq -r .id /tmp/bid-2.json)
check "POST /browser-identities with a proxy answers 201 and says only that the identity has one: no proxy, no user, no host" "[ '$CODE2' = 201 ] && jq -e '.hasProxy == true and (has(\"proxy\") | not)' /tmp/bid-2.json >/dev/null && ! grep -qE '$PROXY_USER|127.0.0.1' /tmp/bid-2.json"
check "the model launches it: the real server opens a browser behind the proxy" "tool_turn 40 browser_identity_launch '{\"identity_id\":\"$ID2\"}' && launched_times $ID2 1"
check "the launch's egress lookup (the browser's timezone) went through the proxy, with its credentials" "grep -qE '^CONNECT (api.ipify.org|icanhazip.com|checkip.amazonaws.com):443' /tmp/proxy.log"
check "the browser behind the proxy works: the model opens a page of the container" "tool_turn 41 browser_navigate '{\"identity_id\":\"$ID2\",\"url\":\"$PAGES/index.html\"}' && tool_ok browser_navigate '$ID2: $PAGES/index.html'"
MCP_PID2=$(mcp_pid_of "$ID2")
environ_of() { su -s /bin/bash dot -c "tr '\\0' '\\n' < /proc/$1/environ"; } # pid
check "the server's process is dot's, with the proxy in its environment (by design: the engine passes it there, readable while the browser is open) and the same knobs as the first identity's" "[ -n '$MCP_PID2' ] && environ_of $MCP_PID2 | grep -qx 'STEALTHFOX_PROXY=http://$PROXY_USER:$PROXY_PASSWORD@127.0.0.1:8099' && environ_of $MCP_PID2 | grep -qx 'INVISIBLE_CORE_AUTOFIX=off'"
check "the password is on no process's command line, which every user can read" "! cmdline_holds $PROXY_PASSWORD"
SESSION_FILE=$MCP_HOMES/$ID2/sessions/$ID2.json
check "the real server saved the proxy with its password in its session file, dot's, in its home outside /home/dot" "[ \"\$(stat -c %U $SESSION_FILE)\" = dot ] && grep -qF $PROXY_PASSWORD $SESSION_FILE && [ ! -e $BROWSERS/$ID2/mcp ]"
check "no file under /home/dot holds the proxy password: the profile, the caches and the logs are clean too" "[ -z \"\$(grep -rlaF $PROXY_PASSWORD /home/dot 2>/dev/null)\" ]"
session_file_refused() { # the TCP port, which the host's file routes are the client of, refuses every way to it
  su -s /bin/bash dot -c "ln -s $MCP_HOMES /home/dot/mcp-link"
  refuses_outside_home "$SESSION_FILE" "$MCP_HOMES/$ID2/sessions" "mcp-link/$ID2/sessions/$ID2.json" "../../var/lib/invisible-dots/mcp/$ID2/sessions/$ID2.json"
}
check "the TCP port refuses that file, its directory and a link to it (403 outside_home): no file route of the host answers with the proxy" "session_file_refused"
check "the identity's directory, which the host can list, has its profile and no MCP home" "files_list browsers/$ID2 | head -n 1 | jq -e '([.entries[].name] | index(\"profile\") != null) and ([.entries[].name] | index(\"mcp\") == null)' >/dev/null"
check "the model closes the proxied identity: its Firefox and server end" "tool_turn 42 browser_identity_close '{\"identity_id\":\"$ID2\"}' && closed_times $ID2 1 && no_server_within 30 $ID2"
check "the host deletes it: its directory and its server's home, with the session file, are gone" "[ \"\$(api -o /dev/null -w '%{http_code}' -X DELETE $A/browser-identities/$ID2)\" = 204 ] && [ ! -e $BROWSERS/$ID2 ] && [ ! -e $MCP_HOMES/$ID2 ]"

# --- what the real browser must not have leaked ---
sleep 3
stop_host_stream
ALL=/tmp/stream-all.txt
timeout 5 curl "${H[@]}" -N "$A/events/stream?after=0" > "$ALL" 2>/dev/null
check "seqs of the full stream are 1..N without a gap" "[ \"\$(seqs $ALL | tr '\n' ' ')\" = \"\$(seq 1 \$(seqs $ALL | wc -l) | tr '\n' ' ')\" ]"
check "the identity's events are all there: created three times, launched six times, closed four times (the model's close, SIGTERM, the browser that was lost and the proxied identity's close; kill -9 reports nothing), deleted twice" "grep '^data: ' $ALL | sed 's/^data: //' | jq -s -e '([.[] | select(.type==\"browser.identity.created\")] | length) == 3 and ([.[] | select(.type==\"browser.identity.launched\")] | length) == 6 and ([.[] | select(.type==\"browser.identity.closed\")] | length) == 4 and ([.[] | select(.type==\"browser.identity.deleted\")] | length) == 2' >/dev/null"
check "the key is in no file of the engine, the config or the Dot (the browser's profile and cache included)" "! grep -rIl \"$KEY\" /home/dotengine /etc/invisible-dots /home/dot /run/invisible-dots /run/invisible-dots-agent 2>/dev/null | grep -q ."
check "the key is not in the environment of any process, Firefox's included" "! environ_holds \"$KEY\""
check "the key is in no engine log and no dot-agentd log" "! grep -q \"$KEY\" /tmp/engine.log /tmp/agentd.log"

echo "== engine log tail"; tail -25 /tmp/engine.log
echo "== agentd log tail"; tail -8 /tmp/agentd.log
echo "== desktop log tail"; tail -8 /tmp/desktop.log
echo "SMOKE: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ] && [ "$SKIP" = 0 ]
