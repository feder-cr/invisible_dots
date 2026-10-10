#!/usr/bin/env bash
# The engine smoke: the guest's two users and two daemons in one Linux container,
# laid out the way the runtime disk's install.sh lays out a Dot's VM, with a
# fake host talking to dot-agentd's TCP port and a stand-in for OpenRouter.
# prepare-engine.sh has built the golden venv (build-engine-env.sh) and the
# runtime disk's engine source, and run.sh built dot-agentd; this script runs
# the Dot, as root, in the container run.sh makes.
#   $AGENTD_BIN     dot-agentd for linux/amd64 (copied to /opt/invisible-dots/bin)
#   /opt/invisible-dots-engine/bin/python   the engine's venv; its source is /opt/invisible-dots/engine
#   fake_openrouter.py, host-stream.sh      next to this script
# Exits non-zero when a check failed or was skipped, and always prints
#   SMOKE: <passed> passed, <failed> failed, <skipped> skipped
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
set -uo pipefail
# The guest, the daemons and the helpers every smoke shares (see lib.sh).
source "$HERE/lib.sh"

# The checks that pin a removal from the model's text: each runs only when its
# name is in PIN_REMOVALS, otherwise it is reported as skipped. The engine has
# nothing of them from the start, so both run at every gate:
#   prompt-text   the system prompt and the exec tool's description name no
#                 approval or elevation mechanism (/approve, approval-pending,
#                 Guardian, elevated)
#   exec-schema   the exec tool's parameter schema has no "elevated" property
PIN_REMOVALS="${PIN_REMOVALS-prompt-text exec-schema}"
pinned() { case " $PIN_REMOVALS " in *" $1 "*) return 0;; esac; return 1; }
check_pinned() { # name, label, command
  if pinned "$1"; then check "$2" "$3"; else echo "SKIP: $2 (pin '$1' is not in PIN_REMOVALS yet)"; SKIP=$((SKIP+1)); fi
}

# >>> request checks
# The stand-in for OpenRouter appends every request it receives, whole, to FULL (lib.sh's).
# sys: a request's system prompt, the text of its system and developer
# messages, whether the content is a string or a list of parts.
# exec_tool: the exec tool as offered ({name, description, parameters}), or null.
REQ_DEFS='def sys: [.messages[]? | select(.role == "system" or .role == "developer") | .content
    | if type == "string" then . elif type == "array" then (map(.text? // "") | join("")) else "" end] | join("\n");
  def exec_tool: [.tools[]? | (.function // .) | select(.name == "exec")][0];
  def banned: "/approve|approval-pending|Guardian|elevated";
  def model_text: sys + "\n" + (exec_tool.description // "");
  def exec_requests: [.[] | select(exec_tool != null)];'
req_jq() { jq -s -e "$REQ_DEFS $1" "$FULL" >/dev/null 2>&1; }
# (a) A request carried a system prompt and the exec tool with its command parameter.
req_prompt_and_exec() { req_jq 'any(.[]; (sys | length) > 0 and exec_tool.parameters.properties.command != null)'; }
# (b) No request's system prompt or exec description names a banned string.
#     At least one request must offer exec, so an empty log cannot pass.
req_no_approval_text() { req_jq '(exec_requests | length) > 0 and all(.[]; model_text | test(banned; "i") | not)'; }
# (c) No exec schema has an "elevated" key, at any depth.
req_exec_schema_clean() { req_jq '(exec_requests | length) > 0 and all(exec_requests[]; [exec_tool.parameters | .. | objects | has("elevated")] | any | not)'; }
# What the banned strings are next to, for the log (shown whether or not the check runs).
req_banned_seen() {
  jq -s -r "$REQ_DEFS"' [.[] | model_text | match("[^\n]{0,50}(" + banned + ")[^\n]{0,50}"; "gi") | .string] | unique | .[:12][]' "$FULL" 2>/dev/null
}
# <<< request checks

# --- the runtime disk (the golden image's users, dot, dotagentd and dotengine, are prepare-engine.sh's) ---
lay_out_guest
# The engine needs no privilege: no sudoers rule, no config directory.
check "the engine has no sudo rule (no /etc/sudoers.d/invisible-dots-engine, no sudo for dotengine)" "[ ! -e /etc/sudoers.d/invisible-dots-engine ] && ! su -s /bin/bash dotengine -c 'sudo -n true' >/dev/null 2>&1"
check "no sudoers file names dotengine (the old engine's rule is gone with the config installer)" "! grep -rqs dotengine /etc/sudoers /etc/sudoers.d"
# --- the VM proxy's firewall, as install.sh writes it, is a ruleset nft takes ---
# A rule nft refused stopped install.sh (set -e) before the tunnel started: the Dot went out directly with its proxy
# set. install.sh's own generator runs here on a config that has a proxy, read from a copy of its path.
vmproxy_rules_ok() {
  local out
  out=$(mktemp -d)
  printf '{"dotId":"dot_smoke","token":"t","proxy":"socks5://user:p%%40ss@10.0.2.2:1080"}' > /tmp/vmproxy-config.json
  sed -n "/<<'PY'\$/,/^PY\$/p" "$TREE/guest/image-builder/runtime/install.sh" | sed '1d;$d' \
    | sed 's#/etc/invisible-dots/config.json#/tmp/vmproxy-config.json#' > /tmp/vmproxy-gen.py
  python3 /tmp/vmproxy-gen.py "$out" && [ -s "$out/allow.nft" ] && [ -s "$out/hev.yml" ] && nft -c -f "$out/allow.nft"
}
check "the VM proxy's firewall that install.sh writes for a proxy is a ruleset nft accepts" "vmproxy_rules_ok"
check "dotengine is in no group but its own and dot" "[ \"\$(id -nG dotengine | tr ' ' '\n' | sort | tr '\n' ' ')\" = 'dot dotengine ' ]"
write_host_token
check "the token file is dot-agentd's own (dotagentd, 0600): neither the engine nor dot, the user of the model's commands, can read it" "[ \"\$(stat -c '%U:%G %a' /etc/invisible-dots/config.json)\" = 'dotagentd:dotagentd 600' ] && ! su -s /bin/bash dotengine -c 'cat /etc/invisible-dots/config.json' >/dev/null 2>&1 && ! su -s /bin/bash dot -c 'cat /etc/invisible-dots/config.json' >/dev/null 2>&1"
check "dotagentd is in no group but its own, and dot is in neither of the two groups that reach a socket" "[ \"\$(id -nG dotagentd)\" = dotagentd ] && ! id -nG dot | tr ' ' '\n' | grep -qx -e dotagentd -e dotengine"

# --- the stand-in for OpenRouter (the key is lib.sh's) ---
start_fake_openrouter
# --- the stand-in for invisible-playwright-mcp ---
# The engine's own test fake (the one owner of what a stand-in answers) and the tool list it serves, as
# captured from the pinned server, copied out of the tree under test where dot may reach them. It runs on
# the engine's python, which has the `mcp` package, as dot: the engine starts it through dot-agentd's relay.
ENGINE_TESTS=$(cd "$HERE/../../../../invisible_engine_dots/tests" && pwd)
FAKE_MCP_DIR=/usr/local/lib/smoke-fake/mcp
install -D -m 0644 "$ENGINE_TESTS/fakes/fake_mcp_server.py" "$FAKE_MCP_DIR/fakes/fake_mcp_server.py"
for tools in "$ENGINE_TESTS"/fixtures/mcp-tools-*.json; do install -D -m 0644 "$tools" "$FAKE_MCP_DIR/fixtures/$(basename "$tools")"; done
FAKE_MCP=/usr/local/lib/smoke-fake/invisible-playwright-mcp
printf '#!/bin/sh\nexec /opt/invisible-dots-engine/bin/python -I -B %s/fakes/fake_mcp_server.py "$@"\n' "$FAKE_MCP_DIR" > "$FAKE_MCP"
chmod 0755 "$FAKE_MCP"
# --- dot-agentd as dotagentd, the engine as dotengine with the stand-in as its browser program ---
MCP_COMMAND=$FAKE_MCP
start_guest_daemons
init_host_side
check "the engine answers /health through dot-agentd" "wait_health"
echo "health: $(api http://127.0.0.1:1024/v1/health)"
check "the engine runs as dotengine" "pgrep -u dotengine -f 'python.*-m nanobot' >/dev/null && ! pgrep -u root -f 'python.*-m nanobot' >/dev/null"
ENGINE_UID=$(id -u dotengine)
tcp_listeners_of_engine() { awk -v u="$ENGINE_UID" 'FNR>1 && $4=="0A" && $8==u' /proc/net/tcp /proc/net/tcp6; }
check "the engine listens on no TCP port" "[ -z \"\$(tcp_listeners_of_engine)\" ]"
check "agent.sock is in the engine's directory, group dotagentd, 0660" "[ \"\$(stat -c '%U:%G %a' /run/invisible-dots-agent/agent.sock)\" = 'dotengine:dotagentd 660' ]"
check "agentd.sock is dotagentd's, group dotengine, 0660" "[ \"\$(stat -c '%U:%G %a' /run/invisible-dots/agentd.sock)\" = 'dotagentd:dotengine 660' ]"
check "dot cannot write the engine's socket directory" "! su -s /bin/bash dot -c 'touch /run/invisible-dots-agent/x' 2>/dev/null"

# The decision for every permission, as the host's toRuntimeConfig sends it (lib.sh's reset_config and
# push); the files are changed below.
reset_config
write_push_script
check "the host pushes the key and the config (204 204)" "[ \"\$(push)\" = '204 204' ]"
sleep 3
check "the state directory is dotengine's, 0700" "[ \"\$(stat -c '%U:%G %a' /home/dotengine/state)\" = 'dotengine:dotengine 700' ]"
check "dot cannot read the engine's state" "! su -s /bin/bash dot -c 'ls /home/dotengine/state' >/dev/null 2>&1"

# --- the model cannot reach what is not its (architecture 4.1) ---
# Every command of the model runs as dot, and dot-agentd, the engine's socket and the Dot's token are other
# users'. Each attempt is made the way the model makes it: a command through POST /v1/exec, which runs as dot.
# The answer is judged by the exact exit code of the command, so a command that never ran proves nothing.
as_model() { api -X POST -H 'content-type: application/json' -d "$(jq -nc --arg c "$1" '{command: $c, timeout_ms: 120000}')" http://127.0.0.1:1024/v1/exec; }
model_out() { as_model "$1" | jq -r .stdout; }
model_code() { as_model "$1" | jq -r .exit_code; }
AGENTD_PID=$(pgrep -o -u dotagentd -f 'bin/dot-agentd')
AGENT_SOCK=/run/invisible-dots-agent/agent.sock
ZERO=0000000000000000
check "dot-agentd runs as dotagentd, and no process of it is root's or dot's" "[ -n \"$AGENTD_PID\" ] && ! pgrep -u root -f 'bin/dot-agentd' >/dev/null && ! pgrep -u dot -f 'bin/dot-agentd' >/dev/null"
# CAP_KILL (5), CAP_SETGID (6) and CAP_SETUID (7) are 0xe0. Its ambient set is empty in every thread: it
# emptied it at start, so that nothing it starts inherits them.
daemon_caps_are_the_units() {
  [ "$(awk '/^CapEff:/ {print $2}' /proc/$AGENTD_PID/status)" = 00000000000000e0 ] || return 1
  local f
  for f in /proc/$AGENTD_PID/task/*/status; do [ "$(awk '/^CapAmb:/ {print $2}' "$f")" = $ZERO ] || return 1; done
}
check "dot-agentd holds CAP_SETUID, CAP_SETGID and CAP_KILL and nothing else, and no thread of it keeps them in its ambient set" "daemon_caps_are_the_units"
model_identity() {
  [ "$(model_out 'echo $(id -un) $HOME $USER $LOGNAME $SHELL')" = 'dot /home/dot dot dot /bin/bash' ] && [ "$(model_out 'id -G')" = "$(id -G dot)" ]
}
check "a command of the model runs as dot, with dot's home, user, shell and groups, not the daemon's" "model_identity"
MODEL_CAPS="grep -E '^Cap(Prm|Eff|Amb):' /proc/self/status | cut -f2 | sort -u"
check "a command of the model holds no capability: nothing dot-agentd starts inherits the three it has" "[ \"\$(model_out \"\$MODEL_CAPS\")\" = $ZERO ]"
# What the engine's relay starts through the process route, on pipes and on a terminal.
printf '%s\n' 'id -un' "$MODEL_CAPS" 'stat -c %U "$(readlink /proc/self/fd/0)" 2>/dev/null' > /usr/local/lib/smoke-fake/who.sh
relay_who() { su -s /bin/bash dotengine -c "/opt/invisible-dots/bin/dot-agentd relay --socket /run/invisible-dots/agentd.sock $1 -- /bin/bash /usr/local/lib/smoke-fake/who.sh" </dev/null | tr -d '\r' | tr '\n' ' '; }
check "the process route starts a program as dot with no capability, and the terminal it gives one is dot's" "[ \"\$(relay_who '')\" = 'dot $ZERO ' ] && [ \"\$(relay_who --tty)\" = 'dot $ZERO dot ' ]"
check "the model cannot signal dot-agentd, and dot has no sudo rule" "[ \"\$(model_code 'kill -9 $AGENTD_PID')\" = 1 ] && [ \"\$(model_code 'sudo -n true')\" = 1 ] && kill -0 $AGENTD_PID"
# The poweroff runs as dot-agentd's own user and may become root, so what it starts must not be found in a
# directory the model writes. The model opens its home (it owns it) and plants a program named like the one
# the daemon runs in ~/.local/bin, which is where the commands of the model look first; the host then stops
# the VM (POST /v1/system/poweroff). The planted program must never run, as dotagentd or as anyone.
poweroff_runs_nothing_of_the_models() {
  local modes mode path ran=false
  rm -f /tmp/hijacked
  su -s /bin/bash dot -c 'mkdir -p /home/dot/.local/bin' || return 1
  modes=$(stat -c '%a %n' /home/dot /home/dot/.local /home/dot/.local/bin)
  su -s /bin/bash dot -c 'printf "#!/bin/sh\nid -un > /tmp/hijacked\n" > /home/dot/.local/bin/sudo && chmod 0755 /home/dot/.local/bin/sudo && chmod o+x /home/dot /home/dot/.local /home/dot/.local/bin' || return 1
  api -o /dev/null -X POST http://127.0.0.1:1024/v1/system/poweroff
  sleep 3
  [ -e /tmp/hijacked ] && ran=true
  rm -f /home/dot/.local/bin/sudo /tmp/hijacked
  while read -r mode path; do chmod "$mode" "$path"; done <<< "$modes"
  ! $ran
}
check "the poweroff the host asks for runs nothing the model planted in dot's .local/bin, though the model opened its home" "poweroff_runs_nothing_of_the_models"
# The engine's API: PUT /config would allow everything and remove the 'ask' of every permission, POST /events
# would approve the model's own parked calls.
check "the model cannot enter the engine's socket directory or dot-agentd's, so a PUT /config or a POST /events on agent.sock never connects" "[ \"\$(model_code 'ls /run/invisible-dots-agent')\" = 2 ] && [ \"\$(model_code 'ls /run/invisible-dots')\" = 2 ] && [ \"\$(model_code \"curl -sS --unix-socket $AGENT_SOCK -X PUT http://x/config -d '{}'\")\" = 7 ] && [ \"\$(model_code \"curl -sS --unix-socket $AGENT_SOCK -X POST http://x/events -d '{}'\")\" = 7 ] && [ \"\$(model_code 'curl -sS --unix-socket /run/invisible-dots/agentd.sock http://x/v1/health')\" = 7 ]"
# The engine's own check, with the directory and the socket opened to everyone as a mistake would: it reads
# the user of each connection from the kernel and refuses dot's.
peers_refused() {
  chmod o+rx /run/invisible-dots-agent && chmod o+rw "$AGENT_SOCK" || return 1
  local answers=() body
  for body in "-X PUT -d '{\"name\":\"x\"}' http://x/config" \
    "-X POST -d '{\"id\":\"e1\",\"type\":\"approval.received\",\"ts\":\"2026-10-04T10:00:00Z\",\"data\":{\"approval_id\":\"a\",\"decision\":\"approved\"}}' http://x/events" \
    "-X POST -d '{\"openrouter_api_key\":\"sk-or-v1-model\"}' http://x/secrets" \
    "http://x/health"; do
    answers+=("$(model_out "curl -sS -w ' %{http_code}' --unix-socket $AGENT_SOCK -H 'content-type: application/json' $body")")
  done
  chmod o-rx /run/invisible-dots-agent; chmod o-rw "$AGENT_SOCK"
  local answer
  for answer in "${answers[@]}"; do
    [[ $answer == *'"error":"forbidden_peer"'*' 403' ]] || { echo "not refused: $answer"; return 1; }
  done
  [ "$(grep -c 'a request was refused for its peer' /tmp/engine.log)" -ge 4 ]
}
check "the engine's socket refuses a process of dot even when its directory and socket are open to everyone: PUT /config, POST /events, POST /secrets and GET /health are 403 forbidden_peer" "peers_refused"
check "the engine kept the config the host pushed and its key: nothing of the model's attempts was applied" "api $A/health | jq -e '.openrouter_configured == true' >/dev/null && [ \"\$(api -o /dev/null -w '%{http_code}' $A/tools)\" = 200 ]"
# The Dot's token.
token_nowhere_the_model_reads() {
  [ "$(model_code 'cat /etc/invisible-dots/config.json')" = 1 ] || return 1
  [ "$(model_code "cat /proc/$AGENTD_PID/environ")" = 1 ] || return 1
  [ "$(model_code "cat /proc/$AGENTD_PID/maps")" = 1 ] || return 1
  ! grep -qF "$TOKEN" /proc/$AGENTD_PID/cmdline || return 1
  # A sweep of the files dot can read, which finds a file that holds the token (one planted for the purpose) and
  # no other.
  su -s /bin/bash dot -c "printf %s '$TOKEN' > /home/dot/token-canary.txt"
  local found
  found=$(model_out "grep -rIlF -e '$TOKEN' /etc /run /var /opt/invisible-dots /home /usr/local /srv 2>/dev/null")
  rm -f /home/dot/token-canary.txt
  [ "$found" = /home/dot/token-canary.txt ]
}
check "the model reads the token nowhere: not its file, not dot-agentd's environment, memory map or command line, and no file of the guest it can read holds it" "token_nowhere_the_model_reads"
refused_with_401() {
  local code arg
  for arg in "http://127.0.0.1:1024/v1/health" "-X PUT -d {} http://127.0.0.1:1024/v1/agent/config" "-X POST -d {} http://127.0.0.1:1024/v1/agent/events" \
    "-H 'Authorization: Bearer nope' http://127.0.0.1:1024/v1/agent/health"; do
    code=$(model_out "curl -s -o /dev/null -w '%{http_code}' $arg")
    [ "$code" = 401 ] || { echo "$arg answered $code"; return 1; }
  done
}
check "from inside the guest the dot-agentd port answers 401 to the model without the token and with a wrong one, for its own routes and the engine's behind it" "refused_with_401"

# The event stream, read the way the host reads it (lib.sh's start_host_stream).
start_host_stream
check "user.message accepted (202)" "[ \"\$(ev msg-1 user.message '{\"text\":\"hello\"}')\" = 202 ]"
check "the same user.message again is accepted and ignored (202)" "[ \"\$(ev msg-1 user.message '{\"text\":\"hello\"}')\" = 202 ]"
check "message.assistant answers it, in_reply_to msg-1" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-1\" and .data.text==\"hello from the stand-in\"'"
# (The attribution headers go only to a verified openrouter.ai route, so a stand-in never sees them.)
check "the model request carried the key the host pushed" "grep -q '\"auth\": \"present\"' /tmp/fake-requests.jsonl"

check "a task whose model calls exec is accepted" "[ \"\$(ev task-ev-1 task.created '{\"task_id\":\"t1\",\"description\":\"RUN-EXEC id -un > /home/dot/workspace/whoami.txt; ps -o user= -p \$\$ >> /home/dot/workspace/whoami.txt; echo ran-as-\$(id -un)\",\"priority\":0}')\" = 202 ]"
check "task.started t1" "wait_event $STREAM '.type==\"task.started\" and .data.task_id==\"t1\"'"
check "tool.called exec, ok, computer.exec, with a duration" "wait_event $STREAM '.type==\"tool.called\" and .data.task_id==\"t1\" and .data.tool==\"exec\" and .data.ok==true and .data.permission==\"computer.exec\"'"
check "that tool.called names the command that ran (its first line)" "wait_event $STREAM '.type==\"tool.called\" and .data.task_id==\"t1\" and .data.tool==\"exec\" and (.data.target|startswith(\"id -un > /home/dot/workspace/whoami.txt; ps -o \"))'"
check "task.completed t1 with the model's answer" "wait_event $STREAM '.type==\"task.completed\" and .data.task_id==\"t1\" and (.data.summary|test(\"ran-as-dot\"))'"
check "the command ran as dot (file content)" "[ \"\$(head -1 /home/dot/workspace/whoami.txt 2>/dev/null)\" = dot ]"
check "the command ran as dot (file owner)" "[ \"\$(stat -c %U /home/dot/workspace/whoami.txt 2>/dev/null)\" = dot ]"
echo "whoami.txt: $(cat /home/dot/workspace/whoami.txt 2>/dev/null | tr '\n' ' ')"
echo "offered tools: $(tail -1 /tmp/fake-tools.jsonl | jq -c '.tools|sort')"
check "the model is offered exec and nothing outside the allowed permissions" "tail -1 /tmp/fake-tools.jsonl | jq -e '(.tools|index(\"exec\")) != null and (.tools - [\"exec\",\"exec_session\",\"list_exec_sessions\"] | length) == 0' >/dev/null"

# --- task.progress: the text the model writes beside a tool call of a task ---
check "a task whose model writes a line beside its exec call is accepted" "[ \"\$(ev task-ev-7 task.created '{\"task_id\":\"t7\",\"description\":\"SAY-RUN-EXEC Checking the workspace first. :: echo progress-ran\",\"priority\":0}')\" = 202 ]"
check "task.completed t7" "wait_event $STREAM '.type==\"task.completed\" and .data.task_id==\"t7\" and (.data.summary|test(\"progress-ran\"))'"
check "t7 reported its line once as task.progress, before the call and the completion" "grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e '[.[] | select(.data.task_id==\"t7\") | .type] == [\"task.started\",\"task.progress\",\"tool.called\",\"task.completed\"] and ([.[] | select(.type==\"task.progress\" and .data.task_id==\"t7\")] | map(.data.text) == [\"Checking the workspace first.\"])' >/dev/null"
check "the events of t7, which spent nothing, report spent_usd 0" "grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e '[.[] | select(.data.task_id==\"t7\" and (.type==\"task.progress\" or .type==\"task.completed\"))] | length == 2 and all(.data.spent_usd == 0)' >/dev/null"
check "the chat's own line beside a tool call is no progress" "[ \"\$(ev msg-narrated user.message '{\"text\":\"SAY-RUN-EXEC Chat narration. :: echo chat-ran\"}')\" = 202 ] && wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-narrated\"' && [ \"\$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -c 'select(.type==\"task.progress\")' | wc -l)\" = 1 ]"

# --- kill -9 and seq resume ---
LAST=$(grep '^id: ' "$STREAM" | tail -1 | sed 's/^id: //')
echo "last seq before the crash: $LAST"
# A task the crash will cut while its command runs.
ev task-ev-2 task.created '{"task_id":"t2","description":"RUN-EXEC sleep 60; echo late","priority":0}' >/dev/null
for _ in $(seq 1 60); do pgrep -u dot -f 'sleep 60' >/dev/null && break; sleep 1; done
check "the long command runs as dot" "pgrep -u dot -f 'sleep 60' >/dev/null"
pkill -9 -u dotengine   # the engine and every process of its cgroup, as systemd's restart does
sleep 2
check "the command died with the engine that started it" "! pgrep -u dot -f 'sleep 60' >/dev/null"
start_engine
check "the restarted engine answers /health" "wait_health"
STREAM2=$STREAM
check "agent.started after the restart, read by the reconnected host" "wait_event $STREAM2 '.type==\"agent.started\" and .seq > $LAST'"
check "the host pushed the key again on agent.started" "wait_key"
check "the cut call is reported once as interrupted" "wait_event $STREAM2 '.type==\"tool.called\" and .data.task_id==\"t2\" and .data.interrupted==true'"
check "the task resumes and completes" "wait_event $STREAM2 '.type==\"task.completed\" and .data.task_id==\"t2\"'"
check "a message after the restart is answered" "[ \"\$(ev msg-2 user.message '{\"text\":\"still there?\"}')\" = 202 ] && wait_event $STREAM2 '.type==\"message.assistant\" and .data.in_reply_to==\"msg-2\"'"
# --- an automation that came due while the engine was off runs once, and a kill -9 does not repeat it ---
# The engine is stopped, a one-time job whose time passed an hour ago is written into its cron store (as the cron tool
# leaves a job), and the engine is started again: it makes the run at start and tells the host the time it was due,
# then that nothing is due. A kill -9 and another start run nothing a second time.
AUTO_LAST=$(grep '^id: ' "$STREAM" | tail -1 | sed 's/^id: //')
kill -TERM "$(pgrep -o -u dotengine -f 'python.*-m nanobot')"
for _ in $(seq 1 30); do pgrep -u dotengine >/dev/null || break; sleep 1; done
AUTO_DUE_MS=$(( $(date +%s) * 1000 - 3600000 ))
cat > /tmp/missed-jobs.json <<JSON
{"version": 1, "jobs": [{"id": "missed01", "name": "missed reminder", "enabled": true,
  "schedule": {"kind": "at", "atMs": $AUTO_DUE_MS, "everyMs": null, "expr": null, "tz": null},
  "payload": {"kind": "agent_turn", "message": "remind me to call the dentist"},
  "state": {"nextRunAtMs": $AUTO_DUE_MS, "lastRunAtMs": null, "lastStatus": null, "lastError": null, "runHistory": []},
  "createdAtMs": $AUTO_DUE_MS, "updatedAtMs": $AUTO_DUE_MS, "deleteAfterRun": false}]}
JSON
install -D -o dotengine -g dotengine -m 0600 /tmp/missed-jobs.json /home/dotengine/state/cron/jobs.json
start_engine
check "the engine answers /health with a job whose time passed in its cron store" "wait_health && wait_key"
check "the host is told that job's due time, a past one, when the engine starts" "wait_event $STREAM '.type==\"automation.next_run\" and .data.next_run_at_ms==$AUTO_DUE_MS and .seq > $AUTO_LAST'"
check "the missed job ran at start: its firing is answered in the chat, with no message to reply to" "wait_event $STREAM '.type==\"message.assistant\" and (.data.in_reply_to|not) and .data.text==\"hello from the stand-in\" and .seq > $AUTO_LAST'"
check "the model was asked with the firing's text" "grep -q 'fired\\] remind me to call the dentist' /tmp/fake-full.jsonl"
check "the host is then told that nothing is due" "wait_event $STREAM '.type==\"automation.next_run\" and .data.next_run_at_ms==null and .seq > $AUTO_LAST'"
check "the one-time job is over in the cron store: disabled, with no next run, run once" "jq -e '.jobs[0] | .enabled == false and .state.nextRunAtMs == null and (.state.runHistory | length) == 1' /home/dotengine/state/cron/jobs.json >/dev/null"
# The firings of an automation answered in the chat since the engine was stopped: no message to reply to.
auto_answers() {
  grep '^data: ' "$STREAM" | sed 's/^data: //' | jq -c "select(.type==\"message.assistant\" and (.data.in_reply_to|not) and .seq > $AUTO_LAST)" | wc -l
}
AUTO_KILLED_AT=$(grep '^id: ' "$STREAM" | tail -1 | sed 's/^id: //')
pkill -9 -u dotengine
sleep 2
start_engine
check "the engine started again after a kill -9 answers /health" "wait_health && wait_key"
check "agent.started after that kill" "wait_event $STREAM '.type==\"agent.started\" and .seq > $AUTO_KILLED_AT'"
sleep 5
check "the job did not run again: its firing is answered once in all" "[ \"\$(auto_answers)\" = 1 ]"
check "the engine has no route for the host to list or change the jobs: they are the Dot's own (404)" "[ \"\$(api -o /dev/null -w '%{http_code}' $A/automations)\" = 404 ]"
# --- cancel and terminate end the remote command, as dot ---
# The engine ends a command by killing the relay it started, in the relay's own process group; nothing
# else tells dot-agentd. On the closed socket dot-agentd must end the remote process group: the shell,
# the foreground command and the background child alike. (The stand-in names every call "call_0".)
ev task-ev-5 task.created '{"task_id":"t5","description":"RUN-EXEC sleep 61 & sleep 62; echo late5 > /home/dot/workspace/late5.txt","priority":0}' >/dev/null
for _ in $(seq 1 60); do pgrep -u dot -f 'sleep 62' >/dev/null && pgrep -u dot -f 'sleep 61' >/dev/null && break; sleep 1; done
check "t5's command and its background child run as dot" "pgrep -u dot -f 'sleep 62' >/dev/null && pgrep -u dot -f 'sleep 61' >/dev/null"
echo "dot's processes while t5 runs:"; ps -o pid,ppid,pgid,args -u dot | cut -c1-120
ev cancel-t5 system.event '{"name":"task.cancelled","data":{"task_id":"t5"}}' >/dev/null
check "cancelling the task ended its command and its background child within 10 s" "gone_within 10 'sleep 6[12]'"
check "the cancelled task's call is reported as interrupted" "wait_event $STREAM '.type==\"tool.called\" and .data.task_id==\"t5\" and .data.interrupted==true'"
check "the cancelled command never reached its last line" "sleep 1; [ ! -e /home/dot/workspace/late5.txt ]"
ev msg-sess user.message '{"text":"RUN-SESSION sleep 63 & sleep 64"}' >/dev/null
check "an exec session starts and the model is told its id" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-sess\" and (.data.text|test(\"session_id\"))'"
check "the session's command and its background child run as dot" "pgrep -u dot -f 'sleep 64' >/dev/null && pgrep -u dot -f 'sleep 63' >/dev/null"
ev msg-kill user.message '{"text":"KILL-SESSION"}' >/dev/null
check "the model terminates the session" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-kill\"'"
check "terminating the exec session ended its command and its background child within 10 s" "gone_within 10 'sleep 6[34]'"

# --- exec on a pseudo-terminal (the tty argument): a real terminal from the real relay ---
# The program asks a question in color on a terminal; the model answers it through exec_session and
# reads the screen's text, not the byte stream (no escape sequence, no carriage return).
cat > /tmp/tty-ask.sh <<'TTYASK'
#!/bin/bash
if [ -t 0 ] && [ -t 1 ]; then echo "stdio-is-a-tty"; else echo "stdio-is-not-a-tty"; fi
echo "term=$TERM size=$(stty size)"
printf '\033[1;32mname?\033[0m '
read -r name
printf 'hello %s\n' "$name"
TTYASK
chmod 755 /tmp/tty-ask.sh
ev msg-tty1 user.message '{"text":"RUN-TTY bash /tmp/tty-ask.sh"}' >/dev/null
check "a tty exec starts a session, the program saw a terminal of 80x24 with a TERM, and the result has no escape sequence" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-tty1\" and (.data.text|test(\"stdio-is-a-tty\")) and (.data.text|test(\"term=xterm-256color size=24 80\")) and (.data.text|test(\"name\\\\? \")) and (.data.text|test(\"session_id\")) and (.data.text|test(\"\\u001b\")|not) and (.data.text|test(\"\\r\")|not)'"
check "the terminal program runs as dot, waiting for its answer" "pgrep -u dot -f 'bash /tmp/tty-ask.sh' >/dev/null"
ev msg-tty2 user.message '{"text":"TTY-ANSWER Ada"}' >/dev/null
check "the answer reaches the program: the model reads its reply and the exit, with no escape sequence or carriage return" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-tty2\" and (.data.text|test(\"hello Ada\")) and (.data.text|test(\"Exit code: 0\")) and (.data.text|test(\"\\u001b\")|not) and (.data.text|test(\"\\r\")|not)'"
check "the terminal program ended" "gone_within 10 'bash /tmp/tty-ask.sh'"
check "that exec call is reported with tty true and names its command, and no other call of the run says tty" "grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e '[.[] | select(.type==\"tool.called\" and .data.tty==true) | .data.target] == [\"bash /tmp/tty-ask.sh\"]' >/dev/null"

# --- SIGTERM while a tool runs: the engine is gone within systemd's TimeoutStopSec=30 ---
ev task-ev-6 task.created '{"task_id":"t6","description":"RUN-EXEC sleep 70; echo late6 > /home/dot/workspace/late6.txt","priority":0}' >/dev/null
for _ in $(seq 1 60); do pgrep -u dot -f 'sleep 70' >/dev/null && break; sleep 1; done
check "t6's long command runs as dot" "pgrep -u dot -f 'sleep 70' >/dev/null"
EPID6=$(pgrep -o -u dotengine -f 'python.*-m nanobot')
STOP_T0=$(date +%s.%N)
kill -TERM "$EPID6"
for _ in $(seq 1 400); do kill -0 "$EPID6" 2>/dev/null || break; sleep 0.1; done
STOP_T1=$(date +%s.%N)
STOP_S=$(awk -v a="$STOP_T0" -v b="$STOP_T1" 'BEGIN { printf "%.1f", b - a }')
echo "MEASURED: the engine exited $STOP_S s after SIGTERM with a tool running"
check "SIGTERM with a tool running stops the engine within systemd's 30 s ($STOP_S s)" "awk -v s=$STOP_S 'BEGIN { exit !(s < 30) }'"
check "that stop left no process of the engine and no command of dot" "! pgrep -u dotengine >/dev/null && ! pgrep -u dot -f 'sleep 70' >/dev/null"
start_engine
check "the restarted engine answers /health (stopped with a tool running)" "wait_health && wait_key"
check "the task t6 the stop cut resumes and completes" "wait_event $STREAM '.type==\"task.completed\" and .data.task_id==\"t6\"'"

# --- approvals (architecture 8.4): ask parks the call, the decision survives kill -9 ---
echo '{"computer.exec":"ask"}' > /tmp/perms.json
check "the host pushes a config where exec asks (204 204)" "[ \"\$(push)\" = '204 204' ]"
ev task-ev-3 task.created '{"task_id":"t3","description":"RUN-EXEC echo approved-ran > /home/dot/workspace/approved.txt; echo approved-out","priority":0}' >/dev/null
check "approval.requested for t3's exec, with its exact arguments" "wait_event $STREAM '.type==\"approval.requested\" and .data.task_id==\"t3\" and .data.tool==\"exec\" and .data.permission==\"computer.exec\" and (.data.arguments.command|test(\"approved-ran\"))'"
AP3=$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -r 'select(.type=="approval.requested" and .data.task_id=="t3") | .data.approval_id' | head -1)
echo "t3 approval: $AP3"
sleep 3
check "the parked call did not run" "[ ! -e /home/dot/workspace/approved.txt ]"
check "the task waits: neither completed nor failed" "! grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e 'any(.[]; (.type==\"task.completed\" or .type==\"task.failed\") and .data.task_id==\"t3\")' >/dev/null"
check "/state says WAITING_APPROVAL on that approval" "st | jq -e --arg id \"$AP3\" '.state==\"WAITING_APPROVAL\" and .pending_approval==\$id' >/dev/null"
LAST3=$(grep '^id: ' "$STREAM" | tail -1 | sed 's/^id: //')
pkill -9 -u dotengine
sleep 2
start_engine
check "the restarted engine answers /health (approval pending)" "wait_health && wait_key"
check "the approval is still pending after kill -9" "st | jq -e --arg id \"$AP3\" '.pending_approval==\$id' >/dev/null"
sleep 3
check "the restart asked nothing new and did not resume the parked task" "[ \"\$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -c 'select(.type==\"approval.requested\" and .data.task_id==\"t3\")' | wc -l)\" = 1 ] && [ ! -e /home/dot/workspace/approved.txt ]"
check "approval.received approve accepted (202)" "[ \"\$(ev ap-3 approval.received '{\"approval_id\":\"'$AP3'\",\"decision\":\"approve\"}')\" = 202 ]"
check "tool.called t3 exec, decision ask, ok" "wait_event $STREAM '.type==\"tool.called\" and .data.task_id==\"t3\" and .data.decision==\"ask\" and .data.ok==true and .seq > $LAST3'"
check "the approved call ran as dot" "[ \"\$(stat -c %U /home/dot/workspace/approved.txt 2>/dev/null)\" = dot ] && grep -q approved-ran /home/dot/workspace/approved.txt"
check "task.completed t3 with the call's result in the continuation" "wait_event $STREAM '.type==\"task.completed\" and .data.task_id==\"t3\" and (.data.summary|test(\"approved-out\"))'"
check "it ran once: one tool.called for t3" "[ \"\$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -c 'select(.type==\"tool.called\" and .data.task_id==\"t3\")' | wc -l)\" = 1 ]"

# A chat call, rejected with a note.
ev msg-3 user.message '{"text":"RUN-EXEC touch /home/dot/workspace/rejected.txt"}' >/dev/null
check "approval.requested for the chat's exec (no task)" "wait_event $STREAM '.type==\"approval.requested\" and (.data.task_id|not) and (.data.arguments.command|test(\"rejected.txt\"))'"
APC=$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -r 'select(.type=="approval.requested" and (.data.task_id|not)) | .data.approval_id' | tail -1)
check "approval.received reject accepted (202)" "[ \"\$(ev ap-c approval.received '{\"approval_id\":\"'$APC'\",\"decision\":\"reject\",\"note\":\"leave it\"}')\" = 202 ]"
check "the chat hears the rejection" "wait_event $STREAM '.type==\"message.assistant\" and .data.text==\"rejection noted\"'"
check "the rejected call never ran" "[ ! -e /home/dot/workspace/rejected.txt ]"

# An approved call cut by kill -9 while it runs: reported once as interrupted, never run again.
ev task-ev-4 task.created '{"task_id":"t4","description":"RUN-EXEC sleep 45; echo late4 > /home/dot/workspace/late4.txt","priority":0}' >/dev/null
check "approval.requested for t4" "wait_event $STREAM '.type==\"approval.requested\" and .data.task_id==\"t4\"'"
AP4=$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -r 'select(.type=="approval.requested" and .data.task_id=="t4") | .data.approval_id' | head -1)
ev ap-4 approval.received '{"approval_id":"'$AP4'","decision":"approve"}' >/dev/null
for _ in $(seq 1 60); do pgrep -u dot -f 'sleep 45' >/dev/null && break; sleep 1; done
check "the approved long call runs as dot" "pgrep -u dot -f 'sleep 45' >/dev/null"
pkill -9 -u dotengine
sleep 2
start_engine
check "the restarted engine answers /health (approved call cut)" "wait_health && wait_key"
check "the cut approved call is reported as interrupted, decision ask" "wait_event $STREAM '.type==\"tool.called\" and .data.task_id==\"t4\" and .data.decision==\"ask\" and .data.interrupted==true'"
check "t4 resumes, told it was interrupted, and completes" "wait_event $STREAM '.type==\"task.completed\" and .data.task_id==\"t4\" and .data.summary==\"resumed and finished\"'"
check "the cut call was not run again" "! pgrep -u dot -f 'sleep 45' >/dev/null && [ ! -e /home/dot/workspace/late4.txt ]"
check "/state is IDLE with nothing pending" "st | jq -e '.state==\"IDLE\" and .pending_approval==null' >/dev/null"

# --- the offered tools follow the permission map (the pin on exec, exec_session and
#     list_exec_sessions above holds for that one map; these are the others) ---
# A config is pushed, then a chat turn runs; the request that turn made to the model
# lists the tools it was offered. The expected list is the permission table of
# nanobot/dots/permissions.py, written out here: a tool the engine offers that the
# table does not name (an MCP tool, a core tool left in) makes a list differ.
offered_with() { # n, permissions json: the tools the model is offered in a chat turn
  echo "$2" > /tmp/perms.json
  [ "$(push)" = '204 204' ] || return 1
  [ "$(ev "msg-tools-$1" user.message '{"text":"which tools?"}')" = 202 ] || return 1
  wait_event $STREAM ".type==\"message.assistant\" and .data.in_reply_to==\"msg-tools-$1\"" || return 1
  tail -1 /tmp/fake-tools.jsonl | jq -c '.tools|sort'
}
check_offered() { # n, label, permissions json, expected tools (sorted JSON)
  local got; got=$(offered_with "$1" "$3")
  echo "offered ($2): $got"
  check "offered tools: $2" "[ '$got' = '$4' ]"
}
BROWSER_GRANTED='"computer.screenshot":"allow","browser.identity.list":"allow","browser.identity.create":"allow","browser.identity.delete":"ask","browser.identity.launch":"allow","browser.identity.close":"allow","browser.navigate":"allow","browser.read":"allow","browser.act":"allow"'
check_offered 1 "every permission granted (files.write and browser.identity.delete ask)" \
  '{"computer.exec":"allow","files.read":"allow","files.write":"ask","automations":"allow",'"$BROWSER_GRANTED"'}' \
  '["apply_patch","browser_click","browser_click_at","browser_identity_close","browser_identity_create","browser_identity_delete","browser_identity_launch","browser_identity_list","browser_navigate","browser_press_key","browser_read_text","browser_screenshot","browser_scroll","browser_select_option","browser_snapshot","browser_type","computer_screenshot","cron","edit_file","exec","exec_session","find_files","grep","list_dir","list_exec_sessions","read_file","write_file"]'
check_offered 2 "exec denied, files.read allowed, the rest missing from the map (deny)" \
  '{"computer.exec":"deny","files.read":"allow"}' \
  '["find_files","grep","list_dir","read_file"]'
check_offered 3 "only exec allowed: the command tools and nothing else" \
  '{"computer.exec":"allow"}' \
  '["exec","exec_session","list_exec_sessions"]'
check_offered 4 "an empty permission map offers nothing" '{}' '[]'
check_offered 5 "browser.identity.delete asks and browser.read is allowed: the delete and the reading tools" \
  '{"browser.identity.delete":"ask","browser.read":"allow"}' \
  '["browser_identity_delete","browser_read_text","browser_screenshot","browser_snapshot"]'
check_offered 6 "delete asks, create is denied, nothing else" \
  '{"browser.identity.delete":"ask","browser.identity.create":"deny"}' \
  '["browser_identity_delete"]'
# GET /tools is the same table seen from the host: the whole table, and `offered` says what the model got.
# The map of check 3 is pushed again: the model was offered exactly exec and its two sessions tools.
offered_with 3b '{"computer.exec":"allow"}' >/dev/null
# As many as the engine's permission table has rows: counted from the table, so a tool added or taken out is not a
# number to remember here.
TABLE_TOOLS=$(grep -c '^        "[a-z_]*": ToolEntry(' "$ENGINE_TESTS/../nanobot/dots/permissions.py")
check "GET /tools through dot-agentd lists the $TABLE_TOOLS tools of the table, each with a description" "[ $TABLE_TOOLS -gt 0 ] && api $A/tools | jq -e '(.tools|length)==$TABLE_TOOLS and all(.tools[]; (.description|length)>0 and (.permission|length)>0)' >/dev/null"
check "GET /tools offers what the model was offered" "[ \"\$(api $A/tools | jq -c '[.tools[]|select(.offered)|.name]|sort')\" = '[\"exec\",\"exec_session\",\"list_exec_sessions\"]' ]"
check "GET /tools names the permission each tool exercises" "api $A/tools | jq -e '(.tools|map({(.name):.permission})|add) | .exec==\"computer.exec\" and .read_file==\"files.read\" and .write_file==\"files.write\" and .cron==\"automations\"' >/dev/null"
# The host reads the Dot's files through the TCP port, which is limited to /home/dot with every symbolic link followed.
# A link a page could make the Dot stage must not show the proxy password in /proc/<pid>/environ of the browser server
# (it runs as dot), nor the Dot's token. The engine's socket takes any path dot can open.
su -s /bin/bash dot -c 'printf hello > /home/dot/hello.txt; ln -s /home/dot/hello.txt /home/dot/hello-link; ln -s /proc/self/environ /home/dot/environ-link; ln -s /etc/invisible-dots/config.json /home/dot/config-link; ln -s /etc /home/dot/etc-link'
reads_hello() { local out; out=$(files_get "$1"); [ "$(printf '%s\n' "$out" | tail -n 1)" = 200 ] && [ "$(printf '%s\n' "$out" | head -n 1)" = hello ]; }
lists_links_as_other() {
  [ "$(files_list etc-link | tail -n 1)" = 403 ] || return 1
  files_list . | head -n 1 | jq -e '([.entries[]|select(.name=="environ-link" or .name=="etc-link" or .name=="config-link")|.type]|sort)==["other","other","other"] and ([.entries[]|select(.name=="hello-link")|.type]==["file"])' >/dev/null
}
engine_socket_status() { curl -sS --unix-socket /run/invisible-dots/agentd.sock -o /dev/null -w '%{http_code}' "http://agentd/v1/files?path=$1"; }
host_wrote_file_as_dot() {
  [ "$(api -o /dev/null -w '%{http_code}' -X PUT --data-binary hi 'http://127.0.0.1:1024/v1/files?path=notes/host-wrote.txt')" = 204 ] || return 1
  [ "$(stat -c %U:%G /home/dot/notes/host-wrote.txt)" = dot:dot ] && [ "$(stat -c %U:%G /home/dot/notes)" = dot:dot ]
}
check "the TCP port reads a file under home, also through a link that stays in home" "reads_hello hello.txt && reads_hello hello-link"
check "the TCP port refuses a link under home to /proc/<pid>/environ, to the token file and to /etc, and a path outside home (403 outside_home)" "refuses_outside_home environ-link config-link etc-link/hostname /proc/self/environ /etc/hostname ../../etc/hostname"
check "the TCP port refuses to list a directory behind a link out of home, and lists such a link as other" "lists_links_as_other"
check "the engine's socket still reads through such a link out of home (the Dot owns its computer), the file system's own answer for dot" "[ \"\$(engine_socket_status etc-link/hostname)\" = 200 ]"
check "the files of the engine's socket and of the TCP port are dot's, not dot-agentd's: the token behind a link is refused to them as to dot (403), and the host's file is written and owned by dot" "[ \"\$(engine_socket_status config-link)\" = 403 ] && [ \"\$(files_get config-link | tail -n 1)\" = 403 ] && host_wrote_file_as_dot"
# A call of a tool the model was not offered (the stand-in makes it anyway) never runs: the turn's
# registry holds only the offered tools, so the call fails as an unknown tool before the gate is asked
# (design: an unknown tool never reaches the gate; tool.called reports it with decision allow, ok false).
echo '{"computer.exec":"deny"}' > /tmp/perms.json
check "the host pushes a config where exec is denied (204 204)" "[ \"\$(push)\" = '204 204' ]"
ev msg-deny user.message '{"text":"RUN-EXEC touch /home/dot/workspace/denied.txt"}' >/dev/null
check "a call of the tool that was not offered is reported as tool.called, not ok" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"exec\" and .data.ok==false and .data.permission==\"computer.exec\"'"
check "the model is told the tool is not found, and the chat answers" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-deny\" and (.data.text|test(\"Tool .exec. not found\"))'"
check "the call of the tool that was not offered never ran" "sleep 2; [ ! -e /home/dot/workspace/denied.txt ]"
echo '{"computer.exec":"allow"}' > /tmp/perms.json
check "the host pushes the allow-everything config again (204 204)" "[ \"\$(push)\" = '204 204' ]"

# --- memory: a note is a file of /home/dot/memory, which the Dot writes and finds with its file tools ---
echo '{"computer.exec":"allow","files.read":"allow","files.write":"allow"}' > /tmp/perms.json
check "the host pushes a config where the Dot may read and write files (204 204)" "[ \"\$(push)\" = '204 204' ]"
check "a chat asks the Dot to write a note two directories deep" "[ \"\$(ev msg-note-1 user.message '{\"text\":\"WRITE-NOTE trips/smoke-note.md :: smoke-needle in a note\"}')\" = 202 ] && wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-note-1\"'"
check "the note is a file of the memory directory, owned by dot" "[ \"\$(cat /home/dot/memory/trips/smoke-note.md 2>/dev/null)\" = 'smoke-needle in a note' ] && [ \"\$(stat -c %U /home/dot/memory/trips/smoke-note.md)\" = dot ]"
check "that tool.called names the path it wrote and none of what it wrote" "grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e '[.[] | select(.type==\"tool.called\" and .data.tool==\"write_file\") | .data.target] == [\"/home/dot/memory/trips/smoke-note.md\"]' >/dev/null"
check "grep finds the note the Dot wrote" "[ \"\$(ev msg-note-2 user.message '{\"text\":\"FIND-NOTE smoke-needle\"}')\" = 202 ] && wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-note-2\" and (.data.text|test(\"trips/smoke-note.md\"))'"
check "the engine reports no note of its own: a note is the write_file that wrote it (no memory.written)" "[ \"\$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -c 'select(.type==\"memory.written\")' | wc -l)\" = 0 ]"
echo '{"computer.exec":"allow"}' > /tmp/perms.json
check "the host pushes the allow-everything config once more (204 204)" "[ \"\$(push)\" = '204 204' ]"

# --- the browser (architecture 6): the engine, dot-agentd and the relay are the real ones; the MCP server is the stand-in
#     installed above (invisible-playwright-mcp's tools, answered by the engine's test fake) ---
# One stand-in process per open identity, started by dot-agentd as dot through the relay. Its record
# ($INVISIBLE_MCP_HOME/record.jsonl) holds its environment, its working directory and every call it received.
BROWSERS=/home/dot/browsers
MCP_HOMES=/var/lib/invisible-dots/mcp   # the stand-ins' homes, outside /home/dot (architecture 4.2)
rec() { echo "$MCP_HOMES/$1/record.jsonl"; }
fakes_running() { pgrep -u dot -f fake_mcp_server.py | wc -l; }
wait_fakes() { # n: the stand-in's processes of dot number n within 10 s
  for _ in $(seq 1 50); do [ "$(fakes_running)" = "$1" ] && return 0; sleep 0.2; done
  return 1
}
call_seen() { jq -s -e --arg tool "$2" "any(.[]; .kind==\"call\" and .name==\$tool and $3)" "$(rec "$1")" >/dev/null; } # id, tool, jq condition on the call
# The first start of the id's process: its working directory and environment, as dot's process had them.
mcp_env_ok() { # id, expected STEALTHFOX_PROXY ("" for none)
  jq -s -e --arg id "$1" --arg proxy "$2" --arg key "$KEY" '
    [.[] | select(.kind == "start")][0] as $s | ($s.env) as $e
    | $s.cwd == ("/home/dot/browsers/" + $id)
    and $e.INVISIBLE_MCP_HOME == ("/var/lib/invisible-dots/mcp/" + $id)
    and $e.INVISIBLE_MCP_SESSION_ID == $id
    and $e.STEALTHFOX_PROFILE_DIR == ("/home/dot/browsers/" + $id + "/profile")
    and $e.STEALTHFOX_HEADLESS == "0" and $e.DISPLAY == ":0" and $e.HOME == "/home/dot"
    and $e.INVISIBLE_CORE_AUTOFIX == "off"
    and (if $proxy == "" then ($e | has("STEALTHFOX_PROXY") | not) else $e.STEALTHFOX_PROXY == $proxy end)
    and ([$e | keys[] | select(startswith("INVISIBLE_DOTS_") or . == "TIKTOKEN_CACHE_DIR" or . == "OPENROUTER_API_KEY")] | length == 0)
    and ([$e[] | select(contains($key))] | length == 0)' "$(rec "$1")" >/dev/null
}
PROXY_PASSWORD=pw-smoke-proxy
no_proxy_password_in() { ! grep -qs "$PROXY_PASSWORD" "$@"; }

echo '{"computer.exec":"allow","computer.screenshot":"allow","browser.identity.list":"allow","browser.identity.create":"ask","browser.identity.delete":"ask","browser.identity.launch":"allow","browser.identity.close":"allow","browser.navigate":"allow","browser.read":"allow","browser.act":"allow"}' > /tmp/perms.json
check "the host pushes a config where the Dot browses (creating and deleting identities ask) (204 204)" "[ \"\$(push)\" = '204 204' ]"
check "no identity yet: /health counts none, the list is empty" "health_is 0 0 && api $A/browser-identities | jq -e '.identities == []' >/dev/null"

CODE1=$(api -o /tmp/bid-1.json -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"name":"research"}' "$A/browser-identities")
ID1=$(jq -r .id /tmp/bid-1.json)
identity_one_ok() { jq -e --arg id "$1" '.id == $id and .name == "research" and .status == "available" and .profilePath == ("/home/dot/browsers/" + $id + "/profile") and .hasProxy == false and (has("proxy") | not)' /tmp/bid-1.json >/dev/null; }
check "POST /browser-identities answers 201 with a closed identity whose profile is under /home/dot/browsers" "[ '$CODE1' = 201 ] && identity_one_ok '$ID1'"
check "browser.identity.created names it" "wait_event $STREAM '.type==\"browser.identity.created\" and .data.identity_id==\"$ID1\" and .data.name==\"research\"'"
check "its profile and MCP home exist, dot's, the home outside /home/dot and not in the identity's directory" "[ \"\$(stat -c %U $BROWSERS/$ID1/profile $MCP_HOMES/$ID1 | tr '\n' ' ')\" = 'dot dot ' ] && [ ! -e $BROWSERS/$ID1/mcp ]"
check "no browser runs for a closed identity, and /health counts one identity, none open" "[ \"\$(fakes_running)\" = 0 ] && health_is 1 0"

check "the model launches the identity" "tool_turn 1 browser_identity_launch '{\"identity_id\":\"$ID1\"}'"
check "browser.identity.launched names it" "launched $ID1"
check "the MCP server runs as dot, one process, and none of it runs as dotengine" "[ \"\$(fakes_running)\" = 1 ] && ! pgrep -u dotengine -f fake_mcp_server.py >/dev/null"
check "its environment has the profile, the display, the session id and its home, no self-repair of the library, no proxy, none of the engine's variables and no key; its working directory is the identity's" "mcp_env_ok $ID1 ''"
check "browser_open was called with the browser role main, once" "call_seen $ID1 browser_open '.args.browser==\"main\"' && [ \"\$(jq -s '[.[] | select(.kind==\"call\" and .name==\"browser_open\")] | length' $(rec $ID1))\" = 1 ]"
check "/health counts one identity, one open" "health_is 1 1"
check "the browser tool call for the open identity is made" "tool_turn 2 browser_navigate '{\"identity_id\":\"$ID1\",\"url\":\"http://example.test/one\"}'"
check "tool.called browser_navigate: ok, permission browser.navigate, allow, naming the identity and the page" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_navigate\" and .data.ok==true and .data.permission==\"browser.navigate\" and .data.decision==\"allow\" and (.data.target|startswith(\"$ID1: http://example.test/one\"))'"
check "the MCP server got browser_navigate with browser main and the url" "call_seen $ID1 browser_navigate '.args.browser==\"main\" and .args.url==\"http://example.test/one\"'"
check "the model takes a screenshot of the page" "tool_turn 3 browser_screenshot '{\"identity_id\":\"$ID1\"}'"
check "tool.called browser_screenshot: ok, permission browser.read" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_screenshot\" and .data.ok==true and .data.permission==\"browser.read\"'"
check "the screenshot reached the model's next request as an image part" "jq -s -e 'any(.[]; [.messages[]? | .content? | arrays | .[] | select(.type==\"image_url\") | .image_url.url] | any(startswith(\"data:image/png;base64,\")))' $FULL >/dev/null"

ID2=$(new_identity second); ID3=$(new_identity third); ID4=$(new_identity lossy)
check "three more identities exist; /health counts four, one open" "[ -n '$ID2' ] && [ -n '$ID3' ] && [ -n '$ID4' ] && health_is 4 1"
# The fourth identity's server reports its browser gone after the first page action, as after a Firefox crash (the
# library's own sentence: the browser is gone, call browser_open; the model cannot, so the engine says to launch).
printf '{"lose_browser_once":true}' > "$MCP_HOMES/$ID4/control.json"
check "the model launches the second and the third identity: three are open (max_open 3), three servers run as dot" "tool_turn 4 browser_identity_launch '{\"identity_id\":\"$ID2\"}' && tool_turn 5 browser_identity_launch '{\"identity_id\":\"$ID3\"}' && wait_fakes 3 && health_is 4 3"
check "the model launches a fourth identity" "tool_turn 6 browser_identity_launch '{\"identity_id\":\"$ID4\"}'"
check "the least recently used identity (the first) was closed: browser.identity.closed" "closed $ID1"
check "it was closed through browser_close, then its server ended; three servers run, three identities are open" "call_seen $ID1 browser_close true && wait_fakes 3 && health_is 4 3"
check "/browser-identities/:id says closed for the first and open for the fourth" "[ \"\$(api $A/browser-identities/$ID1 | jq -r .status)\" = available ] && [ \"\$(api $A/browser-identities/$ID4 | jq -r .status)\" = open ]"
check "a browser action on the closed identity fails and says to launch it" "tool_turn 7 browser_navigate '{\"identity_id\":\"$ID1\",\"url\":\"http://example.test/closed\"}' && wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-bt-7\" and (.data.text|test(\"is not open; call browser_identity_launch first\"))'"
check "that call is reported as tool.called, not ok, and it started no browser" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_navigate\" and .data.ok==false and .data.permission==\"browser.navigate\" and (.data.target|startswith(\"$ID1: http://example.test/closed\"))' && [ \"\$(fakes_running)\" = 3 ] && [ \"\$(jq -s '[.[] | select(.kind==\"start\")] | length' $(rec $ID1))\" = 1 ]"
check "a page action after the browser closed under a live server is not repeated and the browser is not reopened: the model is told it is gone and to launch the identity again" "tool_turn 8 browser_navigate '{\"identity_id\":\"$ID4\",\"url\":\"http://example.test/lossy\"}' && wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-bt-8\" and (.data.text|test(\"is gone: it closed or crashed\")) and (.data.text|test(\"call browser_identity_launch to open it again\"))' && wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_navigate\" and .data.ok==false and (.data.target|startswith(\"$ID4: http://example.test/lossy\"))' && [ \"\$(jq -s '[.[] | select(.kind==\"call\" and .name==\"browser_open\")] | length' $(rec $ID4))\" = 1 ] && [ \"\$(jq -s '[.[] | select(.kind==\"call\" and .name==\"browser_navigate\")] | length' $(rec $ID4))\" = 1 ]"
check "the identity whose browser was lost is closed (browser.identity.closed), its server ended, and it holds no slot: two servers run, two identities are open" "closed $ID4 && wait_fakes 2 && health_is 4 2 && [ \"\$(api $A/browser-identities/$ID4 | jq -r .status)\" = available ]"

# An identity the model creates with a proxy: the approval shows the proxy masked, and nothing else shows it.
PROXY="http://smoke-user:$PROXY_PASSWORD@127.0.0.1:9"
say msg-bt-proxy "RUN-TOOL browser_identity_create $(jq -nc --arg p "$PROXY" '{name:"shopping",proxy:$p}')" >/dev/null
check "approval.requested for the identity the model creates: its proxy is masked in the arguments" "wait_event $STREAM '.type==\"approval.requested\" and .data.tool==\"browser_identity_create\" and .data.permission==\"browser.identity.create\" and .data.arguments.name==\"shopping\" and .data.arguments.proxy==\"***\"'"
APP=$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -r 'select(.type=="approval.requested" and .data.tool=="browser_identity_create") | .data.approval_id' | head -1)
check "the proxy password is in no event, no engine log and no dot-agentd log so far" "no_proxy_password_in $STREAM /tmp/engine.log /tmp/agentd.log"
check "approval.received approve accepted (202)" "[ \"\$(ev ap-proxy approval.received '{\"approval_id\":\"'$APP'\",\"decision\":\"approve\"}')\" = 202 ]"
check "tool.called browser_identity_create: ok, decision ask, permission browser.identity.create, naming the identity and not its proxy" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_identity_create\" and .data.ok==true and .data.decision==\"ask\" and .data.permission==\"browser.identity.create\" and .data.target==\"shopping\"'"
ID5=$(identity_named shopping)
check "the identity is listed as having a proxy and says no more, and browser.identity.created names it" "api $A/browser-identities/$ID5 | jq -e '.hasProxy == true and (has(\"proxy\") | not)' >/dev/null && wait_event $STREAM '.type==\"browser.identity.created\" and .data.identity_id==\"$ID5\" and .data.name==\"shopping\"'"
check "the model launches it: nothing is closed, because the identity whose browser was lost holds no slot (the second, the third and this one are open)" "tool_turn 9 browser_identity_launch '{\"identity_id\":\"$ID5\"}' && launched $ID5 && wait_fakes 3 && health_is 5 3 && [ \"\$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -s '[.[] | select(.type==\"browser.identity.closed\" and .data.identity_id==\"$ID2\")] | length')\" = 0 ]"
check "its server got the proxy in STEALTHFOX_PROXY (dot's process, not the engine's), with the rest of the environment as before" "mcp_env_ok $ID5 '$PROXY'"
# The real server writes who `main` is, the proxy with its password included, to <home>/sessions/<session id>.json
# (the stand-in does the same). The host's file routes reach /home/dot only, and the home of the servers is outside it.
SESSION_FILE=$MCP_HOMES/$ID5/sessions/$ID5.json
session_file_refused() { # the TCP port, which the host's file routes are the client of, refuses every way to it
  su -s /bin/bash dot -c "ln -s $MCP_HOMES /home/dot/mcp-link"
  refuses_outside_home "$SESSION_FILE" "$MCP_HOMES/$ID5/sessions" "mcp-link/$ID5/sessions/$ID5.json" "../../var/lib/invisible-dots/mcp/$ID5/sessions/$ID5.json"
}
check "the session file the server saved holds the proxy with its password, and it is outside /home/dot" "[ \"\$(stat -c %U $SESSION_FILE)\" = dot ] && grep -q $PROXY_PASSWORD $SESSION_FILE && ! grep -rqs $PROXY_PASSWORD /home/dot"
check "the TCP port refuses that file, its directory and a link to it (403 outside_home): no file route of the host can read the proxy" "session_file_refused"
check "the proxy password is in no event, no engine log and no dot-agentd log after the launch either" "no_proxy_password_in $STREAM /tmp/engine.log /tmp/agentd.log"
check "the proxy password is on no process's command line, which every user can read (the relay of the open browser names the variable and nothing else)" "cmdline_holds '--env-from STEALTHFOX_PROXY' && ! cmdline_holds \$PROXY_PASSWORD"

# browser.identity.delete asks: the parked call survives kill -9, and the servers die with the engine that started them.
say msg-bt-del "RUN-TOOL browser_identity_delete {\"identity_id\":\"$ID3\"}" >/dev/null
check "approval.requested for the delete of an open identity, permission browser.identity.delete" "wait_event $STREAM '.type==\"approval.requested\" and .data.tool==\"browser_identity_delete\" and .data.permission==\"browser.identity.delete\" and .data.arguments.identity_id==\"$ID3\"'"
APD=$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -r 'select(.type=="approval.requested" and .data.tool=="browser_identity_delete") | .data.approval_id' | head -1)
sleep 2
check "the parked delete did not run: the identity and its directory are there, still open" "[ -d $BROWSERS/$ID3 ] && [ \"\$(api $A/browser-identities/$ID3 | jq -r .status)\" = open ] && st | jq -e --arg id \"$APD\" '.pending_approval==\$id' >/dev/null"
LASTD=$(grep '^id: ' "$STREAM" | tail -1 | sed 's/^id: //')
check "three servers run as dot before the kill" "[ \"\$(fakes_running)\" = 3 ]"
pkill -9 -u dotengine
check "kill -9 of the engine ended every MCP server within 10 s (dot-agentd ended their groups)" "gone_within 10 fake_mcp_server.py"
start_engine
check "the restarted engine answers /health (delete pending)" "wait_health && wait_key"
check "the delete is still pending after kill -9" "st | jq -e --arg id \"$APD\" '.pending_approval==\$id' >/dev/null"
check "after the restart every identity is available, none open, and /health counts five and none" "api $A/browser-identities | jq -e '(.identities|length)==5 and all(.identities[]; .status==\"available\")' >/dev/null && health_is 5 0"
check "approval.received approve accepted (202)" "[ \"\$(ev ap-del approval.received '{\"approval_id\":\"'$APD'\",\"decision\":\"approve\"}')\" = 202 ]"
check "tool.called browser_identity_delete: ok, decision ask" "wait_event $STREAM '.type==\"tool.called\" and .data.tool==\"browser_identity_delete\" and .data.ok==true and .data.decision==\"ask\" and .data.target==\"$ID3\" and .seq > $LASTD'"
check "browser.identity.deleted names it; its directory is gone and it is no longer listed" "wait_event $STREAM '.type==\"browser.identity.deleted\" and .data.identity_id==\"$ID3\" and .data.name==\"third\"' && [ ! -e $BROWSERS/$ID3 ] && [ ! -e $MCP_HOMES/$ID3 ] && [ \"\$(api -o /dev/null -w '%{http_code}' $A/browser-identities/$ID3)\" = 404 ] && health_is 4 0"

# SIGTERM closes an open browser through browser_close before its server ends.
check "the model launches an identity again after the restart" "tool_turn 10 browser_identity_launch '{\"identity_id\":\"$ID4\"}' && wait_fakes 1"
EPIDB=$(pgrep -o -u dotengine -f 'python.*-m nanobot')
kill -TERM "$EPIDB"
for _ in $(seq 1 300); do kill -0 "$EPIDB" 2>/dev/null || break; sleep 0.1; done
check "SIGTERM stopped the engine and the browser's server ended" "! kill -0 $EPIDB 2>/dev/null && wait_fakes 0"
last_start_closed_ok() { # id: after its last start the server was asked browser_open, then browser_close, and answered both
  jq -s -e '. as $all | ([range(0; length) | select($all[.].kind == "start")] | last) as $i | $all[$i:]
    | ([.[] | select(.kind == "call") | .name] == ["browser_open", "browser_close"])
      and ([.[] | select(.kind == "done") | .name] == ["browser_open", "browser_close"])' "$(rec "$1")" >/dev/null
}
check "the server of the open identity was asked browser_close, so Firefox could flush its profile, and answered it" "last_start_closed_ok $ID4"
start_engine
check "the restarted engine answers /health (browser closed by SIGTERM)" "wait_health && wait_key"

# A delete from the host while the identity is open closes it first.
check "the model launches the proxy identity" "tool_turn 11 browser_identity_launch '{\"identity_id\":\"$ID5\"}' && wait_fakes 1 && health_is 4 1"
# The host's two actions on one identity: a frame of its window (only while it is open) and closing its browser.
status_of() { api -o "${2:-/dev/null}" -w '%{http_code}' "${@:3}" "$1"; } # url, output file, curl arguments
closed_total() { grep '^data: ' $STREAM | sed 's/^data: //' | jq -s "[.[] | select(.type==\"browser.identity.closed\" and .data.identity_id==\"$1\")] | length"; } # id
wait_closed_total() { for _ in $(seq 1 30); do [ "$(closed_total "$1")" = "$2" ] && return 0; sleep 1; done; return 1; } # id, n
check "GET /browser-identities/:id/frame answers a JPEG of the open identity, 409 not_open for a closed one, 404 for an unknown one" "[ \"\$(status_of $A/browser-identities/$ID5/frame /tmp/frame-5.jpg)\" = 200 ] && [ \"\$(head -c 3 /tmp/frame-5.jpg | od -An -tx1 | tr -d ' \n')\" = ffd8ff ] && [ \"\$(status_of $A/browser-identities/$ID1/frame)\" = 409 ] && [ \"\$(status_of $A/browser-identities/nobody-abc123/frame)\" = 404 ]"
check "the frame was the server's browser_watch with the browser role main, and it launched nothing" "call_seen $ID5 browser_watch '.args.browser==\"main\"' && wait_fakes 1 && health_is 4 1"
CLOSED_BEFORE=$(closed_total $ID5)
check "POST /browser-identities/:id/close answers 204: the browser is closed, the server ends, closed is emitted once, the profile stays" "[ \"\$(status_of $A/browser-identities/$ID5/close /dev/null -X POST)\" = 204 ] && wait_fakes 0 && wait_closed_total $ID5 $((CLOSED_BEFORE + 1)) && [ -d $BROWSERS/$ID5/profile ] && [ \"\$(api $A/browser-identities/$ID5 | jq -r .status)\" = available ] && health_is 4 0"
check "closing a closed identity answers 204 and emits nothing; an unknown one is 404" "[ \"\$(status_of $A/browser-identities/$ID5/close /dev/null -X POST)\" = 204 ] && [ \"\$(status_of $A/browser-identities/nobody-abc123/close /dev/null -X POST)\" = 404 ] && [ \"\$(closed_total $ID5)\" = $((CLOSED_BEFORE + 1)) ]"
check "the model launches it again, so the idle kill below meets an open identity" "tool_turn 12 browser_identity_launch '{\"identity_id\":\"$ID5\"}' && wait_fakes 1 && health_is 4 1"
# A server that dies while nothing calls it (its relay ends with it): the engine hears of it when it happens.
CLOSED_BEFORE=$(closed_total $ID5)
check "a server killed while idle closes its identity at once, with no call: closed is emitted once and /health counts none open" "pkill -9 -u dot -f fake_mcp_server.py; wait_fakes 0 && wait_closed_total $ID5 $((CLOSED_BEFORE + 1)) && health_is 4 0 && [ \"\$(api $A/browser-identities/$ID5 | jq -r .status)\" = available ]"
check "the model launches it once more, so the delete below meets an open identity" "tool_turn 13 browser_identity_launch '{\"identity_id\":\"$ID5\"}' && wait_fakes 1 && health_is 4 1"
check "DELETE /browser-identities/:id of the open identity answers 204" "[ \"\$(api -o /dev/null -w '%{http_code}' -X DELETE $A/browser-identities/$ID5)\" = 204 ]"
check "its browser was closed, then it was deleted: closed, then deleted" "wait_event $STREAM '.type==\"browser.identity.deleted\" and .data.identity_id==\"$ID5\"' && grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e '[.[] | select(.data.identity_id==\"$ID5\" and (.type==\"browser.identity.closed\" or .type==\"browser.identity.deleted\")) | .type] | .[-2:] == [\"browser.identity.closed\",\"browser.identity.deleted\"]' >/dev/null"
check "its server ended, its directory and its server's home (the session file with the proxy) are gone, /health counts three identities, none open" "wait_fakes 0 && [ ! -e $BROWSERS/$ID5 ] && [ ! -e $MCP_HOMES/$ID5 ] && health_is 3 0"
check "the proxy password is in no event, no engine log and no dot-agentd log at the end of the browser checks" "no_proxy_password_in $STREAM /tmp/engine.log /tmp/agentd.log"
echo '{"computer.exec":"allow"}' > /tmp/perms.json
check "the host pushes the allow-everything config once more (204 204)" "[ \"\$(push)\" = '204 204' ]"

# --- limits.max_cost_per_task_usd (1 in the pushed config): the cap stops a task and a chat turn, and holds after kill -9 ---
# The stand-in reports a cost of 0.6 in every response of a conversation whose last user text has a COST 0.6 line,
# and REPEAT-EXEC makes it call exec after every result: only the cap ends such a task.
ev task-ev-8 task.created '{"task_id":"t8","description":"COST 0.6\nREPEAT-EXEC echo spend","priority":0}' >/dev/null
check "t8 (0.6 a response, a model that never stops) fails with the cap's text, having spent 1.2" "wait_event $STREAM '.type==\"task.failed\" and .data.task_id==\"t8\" and .data.error==\"stopped: the task reached limits.max_cost_per_task_usd (spent 1.2000 USD of 1.00)\"'"
check "the failure of t8 reports what the task spent: spent_usd 1.2" "wait_event $STREAM '.type==\"task.failed\" and .data.task_id==\"t8\" and .data.spent_usd==1.2'"
check "t8 made two requests: the third was never asked (two tool.called, no task.completed)" "[ \"\$(grep '^data: ' $STREAM | sed 's/^data: //' | jq -c 'select(.type==\"tool.called\" and .data.task_id==\"t8\")' | wc -l)\" = 2 ] && [ \"\$(grep -c 'REPEAT-EXEC echo spend' /tmp/fake-tools.jsonl)\" = 2 ]"
ev msg-spend user.message '{"text":"COST 0.6\nREPEAT-EXEC echo chat-spend"}' >/dev/null
check "a chat turn that spent the cap answers with the turn's text" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-spend\" and .data.text==\"I could not answer: stopped: the turn reached limits.max_cost_per_task_usd (spent 1.2000 USD of 1.00)\"'"
check "the answer of that chat turn reports the turn's spend: spent_usd 1.2" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-spend\" and .data.spent_usd==1.2'"
# The first response of t9 is paid (0.6) and its command runs; the engine is killed then. The restarted engine
# resumes the task from the spend it stored: one more response ends it. Were the spend lost with the process,
# a third request would be made.
ev task-ev-9 task.created '{"task_id":"t9","description":"COST 0.6\nREPEAT-EXEC sleep 4","priority":0}' >/dev/null
for _ in $(seq 1 60); do pgrep -u dot -f 'sleep 4$' >/dev/null && break; sleep 0.5; done
check "t9's first command runs as dot" "pgrep -u dot -f 'sleep 4\$' >/dev/null"
pkill -9 -u dotengine
sleep 2
start_engine
check "the restarted engine answers /health (the cap's task cut)" "wait_health && wait_key"
check "t9 fails with the cap's text after one more response: the spend survived the kill" "wait_event $STREAM '.type==\"task.failed\" and .data.task_id==\"t9\" and .data.error==\"stopped: the task reached limits.max_cost_per_task_usd (spent 1.2000 USD of 1.00)\"'"
check "the failure of t9 reports the spend of both processes: spent_usd 1.2" "wait_event $STREAM '.type==\"task.failed\" and .data.task_id==\"t9\" and .data.spent_usd==1.2'"
check "t9 asked the model twice in all: once before the kill, once after" "[ \"\$(grep -c 'REPEAT-EXEC sleep 4' /tmp/fake-tools.jsonl)\" = 2 ]"

# --- models.summary: a thread that outgrows its model's window is summarized by the role's model ---
# smoke/small's window, as the stand-in publishes it, is 24000 tokens and its longest answer 4096, the room kept
# for it; with the safety buffer of 1024 a request over 18880 tokens (as the engine sizes it: its estimate times
# 1.35, nanobot/providers/prompt_count.py) is compacted. The Dot's first request, its prompt and the exec tools,
# fits; each of the five messages is about 2100 tokens, so the thread outgrows the budget within them. The messages
# carry no tool result to clear, so the summary model is asked; its own request has the same budget, and what does
# not fit of the thread loses its oldest messages first. The stand-in answers each message with the same short text,
# and every turn must answer it: a window too small for the Dot's own prompt fails every turn instead.
echo '{"summary":"smoke/summarizer"}' > /tmp/models.json; echo smoke/small > /tmp/model.txt
check "the host pushes a config with a summary model and a model of a 24000 token window (204 204)" "[ \"\$(push)\" = '204 204' ]"
LONG=$(yes 'alpha beta gamma delta epsilon zeta' | head -n 300 | tr '\n' ' ')
for n in 1 2 3 4 5; do
  ev "msg-long-$n" user.message "{\"text\":\"$n $LONG\"}" >/dev/null
  wait_event $STREAM ".type==\"message.assistant\" and .data.in_reply_to==\"msg-long-$n\"" || break
done
check "the five long messages were answered" "wait_event $STREAM '.type==\"message.assistant\" and .data.in_reply_to==\"msg-long-5\"'"
check "each of them by the model, none with a failure" "grep '^data: ' $STREAM | sed 's/^data: //' | jq -s -e '[.[] | select(.type==\"message.assistant\" and ((.data.in_reply_to // \"\") | startswith(\"msg-long-\")))] | length == 5 and all(.[]; (.data.text | startswith(\"I could not answer\")) | not)' >/dev/null"
check "a request went to the summary role's model, with no tool in it" "jq -s -e 'any(.[]; .model==\"smoke/summarizer\" and (.tools|length)==0)' /tmp/fake-tools.jsonl >/dev/null"
check "every request the summary role's model got was offered no tool (it never answers a turn)" "jq -s -e '[.[] | select(.model==\"smoke/summarizer\")] | length > 0 and all(.[]; (.tools|length)==0)' /tmp/fake-tools.jsonl >/dev/null"
check "the turns themselves went to the Dot's own model, offered the tools of the permission map" "jq -s -e '[.[] | select(.model==\"smoke/small\")] | length >= 5 and (last | .tools | index(\"exec\") != null)' /tmp/fake-tools.jsonl >/dev/null"
echo '{}' > /tmp/models.json; echo openai/gpt-4o-mini > /tmp/model.txt
check "the host pushes the config without a summary model, with the usual model, again (204 204)" "[ \"\$(push)\" = '204 204' ]"

# --- what the model is sent, read whole ---
# Here, after the last model turn of the run, so the checks judge EVERY request:
# the allow-mode chat and tasks, the resumes after each restart, the ask-mode
# turns with their approval and rejection continuations (where approval wording
# would show up) and the permission-map turns above. Nothing below this point
# calls the model.
echo "requests logged whole: $(wc -l < "$FULL" 2>/dev/null)"
check "a Dot run's request has a system prompt and an exec tool schema" "req_prompt_and_exec"
echo "banned text the model is sent (pins prompt-text):"; req_banned_seen | sed 's/^/  | /'
check_pinned prompt-text "no request's system prompt or exec description names /approve, approval-pending, Guardian, elevated" "req_no_approval_text"
check_pinned exec-schema "no request's exec tool schema has an elevated property" "req_exec_schema_clean"

sleep 3
stop_host_stream
# Everything committed, read again from 0: what the host received across the crash must be exactly that.
ALL=/tmp/stream-all.txt
timeout 5 curl "${H[@]}" -N "$A/events/stream?after=0" > "$ALL" 2>/dev/null
check "seqs of the full stream are 1..N without a gap" "[ \"\$(seqs $ALL | tr '\n' ' ')\" = \"\$(seq 1 \$(seqs $ALL | wc -l) | tr '\n' ' ')\" ]"
check "the host received every event exactly once across the crash (no loss, no repeat)" "[ \"\$(seqs $STREAM | tr '\n' ' ')\" = \"\$(seqs $ALL | tr '\n' ' ')\" ]"
check "event ids are unique" "[ \"\$(grep '^data: ' $ALL | sed 's/^data: //' | jq -r .id | sort | uniq -d | wc -l)\" = 0 ]"
check "tool.called for t2 appears once as interrupted" "[ \"\$(grep '^data: ' $ALL | sed 's/^data: //' | jq -c 'select(.type==\"tool.called\" and .data.task_id==\"t2\" and .data.interrupted==true)' | wc -l)\" = 1 ]"
check "agent.started ten times in all (ten starts)" "[ \"\$(grep '^data: ' $ALL | sed 's/^data: //' | jq -c 'select(.type==\"agent.started\")' | wc -l)\" = 10 ]"
check "the browser identity events are all in the stream, each once: five created, launched nine times, closed six times and deleted twice" "grep '^data: ' $ALL | sed 's/^data: //' | jq -s -e '([.[] | select(.type==\"browser.identity.created\")] | length) == 5 and ([.[] | select(.type==\"browser.identity.deleted\")] | length) == 2 and ([.[] | select(.type==\"browser.identity.launched\")] | length) == 9 and ([.[] | select(.type==\"browser.identity.closed\")] | length) == 6' >/dev/null"
check "the proxy password is in no event of the whole stream" "no_proxy_password_in $ALL"
echo "event types: $(grep '^data: ' $ALL | sed 's/^data: //' | jq -r .type | sort | uniq -c | tr '\n' ' ')"

# --- the key on disk ---
check "the key is in no file of the engine, the config or the Dot" "! grep -rIl \"$KEY\" /home/dotengine /etc/invisible-dots /home/dot /run/invisible-dots /run/invisible-dots-agent 2>/dev/null | grep -q ."
check "the key is in no SQLite file either" "! find /home/dotengine -type f -exec grep -l -a \"$KEY\" {} + 2>/dev/null | grep -q ."
check "the key is in no engine log" "! grep -rIl \"$KEY\" /tmp/engine.log 2>/dev/null | grep -q ."
check "the key is not in the environment of any process" "! environ_holds \"$KEY\""
# --- a graceful stop: SIGTERM, as systemd stops the unit (TimeoutStopSec=30) ---
echo "engine processes before the stop:"; ps -o pid,ppid,etimes,args -u dotengine | cut -c1-160
EPID=$(pgrep -o -u dotengine -f 'python.*-m nanobot')
kill -TERM "$EPID"
for _ in $(seq 1 30); do pgrep -u dotengine >/dev/null || break; sleep 1; done
echo "engine processes after the stop:"; ps -o pid,ppid,etimes,args -u dotengine | cut -c1-160
check "SIGTERM stops the engine within systemd's 30 s" "! kill -0 $EPID 2>/dev/null"
check "the stop leaves no process of the engine" "! pgrep -u dotengine >/dev/null"
check "the stop is logged as a clean shutdown, not a crash" "tail -40 /tmp/engine.log | grep -q 'Dot API stopped' && ! tail -40 /tmp/engine.log | grep -q 'Traceback'"
# --- what the stopped engine left: its state, its config, its logs ---
# (The old engine kept a config file for root to write; this one has none, so the
# same questions are asked of what it does keep.)
check "the engine wrote nothing under /etc/invisible-dots (only the host's token file is there)" "[ \"\$(ls -A /etc/invisible-dots)\" = config.json ]"
check "everything under the engine's home is dotengine's, and its home and state directories are 0700 (they close the files inside)" "[ -z \"\$(find /home/dotengine ! -user dotengine 2>/dev/null)\" ] && [ \"\$(stat -c %a /home/dotengine /home/dotengine/state | tr '\n' ' ')\" = '700 700 ' ]"
check "dot cannot read the engine's database by path" "! su -s /bin/bash dot -c 'cat /home/dotengine/state/engine.sqlite' >/dev/null 2>&1"
# The engine's config is the runtime_config row of that database (the old engine's file
# was root:dotengine 0640 and dot could not read it): dot reaches neither the file, nor
# the row through sqlite, nor any file under the engine's home.
cat > /tmp/dot-read-config.py <<'PYEOF'
import sqlite3
sqlite3.connect("file:/home/dotengine/state/engine.sqlite?mode=ro", uri=True).execute("select value_json from dots_kv")
PYEOF
chmod 0644 /tmp/dot-read-config.py
check "dot cannot see the engine's database file at all (it exists: root sees it)" "[ -e /home/dotengine/state/engine.sqlite ] && ! su -s /bin/bash dot -c 'test -e /home/dotengine/state/engine.sqlite' 2>/dev/null"
check "dot cannot read the stored config row through sqlite" "! su -s /bin/bash dot -c 'python3 /tmp/dot-read-config.py' >/dev/null 2>&1"
check "dot finds no file under the engine's home" "[ -z \"\$(su -s /bin/bash dot -c 'find /home/dotengine -type f' 2>/dev/null)\" ]"
# No counterpart on purpose, the feature is gone: the sudoers rule and its visudo parse
# (the engine has no privilege), the config file's mode and its 'source: memory' key
# reference (there is no config file; the stored-config check below says no key is kept),
# /tmp/openclaw (the directory no longer exists; the key sweep over /tmp, /var/log,
# /var/tmp and /dev/shm below covers every log the engine could write).
cat > /tmp/read-config.py <<'PYEOF'
import sqlite3
conn = sqlite3.connect("file:/home/dotengine/state/engine.sqlite?mode=ro", uri=True)
print(conn.execute("select value_json from dots_kv where key = 'runtime_config'").fetchone()[0])
PYEOF
chmod 0644 /tmp/read-config.py
su -s /bin/bash dotengine -c "$ENGINE_PY -I -B /tmp/read-config.py" > /tmp/stored-config.json 2>/tmp/stored-config.err
echo "stored config: $(cut -c1-300 /tmp/stored-config.json)"
check "the engine stores the config the host pushed: the permission map, the model, no key" "jq -e '.permissions.\"computer.exec\" == \"allow\" and .model.id == \"openai/gpt-4o-mini\" and ([.. | strings | test(\"sk-or-\")] | any | not) and (has(\"openrouter_api_key\") | not)' /tmp/stored-config.json >/dev/null"
check "the key is in no log, no stream and no temporary file of the run (the push script holds it by construction)" "! grep -rIl \"$KEY\" /tmp /var/log /var/tmp /dev/shm --exclude=push.sh 2>/dev/null | grep -q ."
# --- the engine runs nothing but the Dot's engine ---
check "any other command is refused" "! su -s /bin/bash dotengine -c '$ENGINE_PY -I -B -m nanobot status' >/tmp/refused-cmd.log 2>&1 && grep -q 'runs only' /tmp/refused-cmd.log"
check "--version answers" "$ENGINE_PY -I -B -m nanobot --version | grep -q '^invisible_dots engine '"
# --- the image: the golden venv from the lock, the engine's source from the runtime disk ---
check "the engine's code is the runtime disk's, found through the venv's .pth file" "[ \"\$(su -s /bin/bash dotengine -c \"$ENGINE_PY -I -B -c 'import nanobot; print(nanobot.__file__)'\")\" = /opt/invisible-dots/engine/nanobot/__init__.py ]"
check "the venv is root's and dotengine cannot write into it" "[ \"\$(stat -c %U /opt/invisible-dots-engine/bin/python)\" = root ] && ! su -s /bin/bash dotengine -c 'touch /opt/invisible-dots-engine/x' 2>/dev/null"
check "no bytecode was written on the runtime disk (python -B)" "! find /opt/invisible-dots/engine -name __pycache__ | grep -q ."

echo "== engine log tail"; tail -25 /tmp/engine.log
echo "== agentd log tail"; tail -8 /tmp/agentd.log
echo "pinned removals: $PIN_REMOVALS"
echo "SMOKE: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ] && [ "$SKIP" = 0 ]
