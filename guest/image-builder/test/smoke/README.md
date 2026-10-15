# The engine smoke

A Dot's guest runs two daemons as two users, and the model's commands as a third:
`dot-agentd` as `dotagentd` (it starts everything of the model's as `dot`), the engine
(`invisible_engine_dots`, run as `python -m nanobot`) as `dotengine`. The unit tests of
each side cannot show that the two work together as the golden image and the runtime
disk lay them out. This smoke does, in one Linux container, with no QEMU:

- the engine's Python environment is built exactly as `builder/provision.sh` builds
  it: the pinned `uv` (checked against `pins.json`), then
  `builder/build-engine-env.sh` on the hashed `builder/engine-requirements.lock`;
- the engine's source is staged as the runtime ISO stages it (every `.py` and `.json`, the `.md`
  templates, the lock, `LICENSE`, `UPSTREAM.md`) and every module imports with what
  the lock installed and nothing else;
- `dot-agentd`, built from the same tree, and the engine run under their two users
  with `install.sh`'s directories and socket modes (`dot-agentd` through `setpriv`, with the three
  capabilities its unit gives it and no others), a fake host talking to
  `dot-agentd`'s TCP port with the Dot's token, and a stand-in for OpenRouter;
- the checks (`smoke.sh`) are about the seams: privileges (the engine has no sudo
  rule, and neither the engine nor `dot` can read the host's token; `dot` cannot read the engine's state),
  and what the model can reach, tried as the model does it, as a command through `POST /v1/exec`: a command
  runs as `dot` with dot's home, shell and groups and holds no capability (on pipes and on a terminal `dot`
  owns, through the engine's relay too); it cannot enter the engine's socket directory or connect to
  `agent.sock` (so no `PUT /config` and no `POST /events`), and when the directory and the socket are
  opened to everyone as a mistake would, the engine's own check of the connecting user refuses it (403
  `forbidden_peer` for `PUT /config`, `POST /events`, `POST /secrets` and `GET /health`); it reads the Dot's
  token nowhere (not its file, not `dot-agentd`'s environment, memory map or command line, and a sweep of
  the files it can read finds only a file planted for the purpose); it gets `401` on the daemon's TCP port,
  for the daemon's own routes and the engine's behind it; it cannot signal `dot-agentd`; and the files the
  host writes through the TCP port are `dot`'s,
  the event stream (`seq` 1..N across `kill -9`, no loss, no repeat), commands
  that run as `dot` and end with the call that started them (cancel, terminate,
  SIGTERM within systemd's 30 s), a program on a pseudo-terminal (`exec` with `tty`) that
  sees an 80x24 terminal and is answered through `exec_session`, its output read as the
  screen's text with no escape sequence and whose `tool.called` says `tty`, an automation whose time passed while the engine was
  off (run once at the next start, with the `automation.next_run` the host is told on the way, and not again after a `kill -9`),
  approvals that survive a crash, the cost cap that
  stops a task and a chat turn and still holds after a crash, the `spent_usd` the
  events of tasks and chat answers carry, the `target` of `tool.called` (the command's first
  line, the path a file tool wrote and none of the content), the tools offered
  for each permission map (and `GET /tools` through `dot-agentd` saying the same, and no `/automations` route), the summary of an outgrown thread going to the
  `models.summary` model with no tool in the request, the text sent to the model, the key reaching no file,
  log or process environment, the browser seams (below), the host's file routes (the TCP port) refusing a symbolic link
  under home that leads to `/proc/<pid>/environ`, the token file or `/etc` while the engine's socket
  still follows it.

## The browser seams

The Dot's browser is `invisible-playwright-mcp`, one process per open identity, started by the
engine through `dot-agentd`'s relay so that it runs as `dot`. The smoke installs a stand-in for it as
`INVISIBLE_DOTS_MCP_COMMAND`: the engine's own test fake (`invisible_engine_dots/tests/fakes/fake_mcp_server.py`,
the one owner of what a stand-in answers) serving the fixture `tests/fakes/invisible_playwright_mcp.json`,
installed the way the real server is, so the engine reads its tools as it reads the real server's. It records its
environment, its working directory and every call it receives in `$INVISIBLE_MCP_HOME/record.jsonl`,
and the checks read that file. What they pin:

- an identity is created over HTTP (201, `browser.identity.created`, its directories are `dot`'s) and
  launched by the model's `browser_identity_launch`; the server runs as `dot`, never as `dotengine`, with
  the profile, the display, the session id and its home in its environment and none of the engine's
  variables nor the key;
- a page tool reaches the server as the real tool with `browser: "main"` and shows in `tool.called` with
  its permission and its target; a screenshot reaches the model's next request as an image part;
- the fourth launch with `max_open` 3 closes the least recently used identity through `browser_close`;
  an action on a closed identity fails with the launch message and starts nothing; a server whose
  browser closed under it is not reopened and the call is not repeated: the call fails saying the browser
  is gone and to launch the identity again, the identity is closed (one `closed` event, its server ended,
  no slot held, so the next launch closes nothing);
- `browser.identity.delete: ask` parks the call and the approval survives `kill -9`, which also ends every
  server; after the restart every identity is `available`; SIGTERM asks an open browser to close before
  its server ends; a host `DELETE` of an open identity closes it first;
- the host's two actions on an identity: `GET .../frame` answers a JPEG (the stand-in's `browser_watch`) for an open
  identity and 409 `not_open` for a closed one, and `POST .../close` closes an open one through `browser_close`
  (one `closed` event, the profile kept) and is a 204 that changes nothing for a closed one;
- a server killed while nothing calls it closes its identity at once: one `closed` event, `/health` counts
  none open, with no call made to find out;
- a proxy password is in no approval, event, engine log or `dot-agentd` log, and on no process's command line (the
  relay is told the variable's name, `--env-from`, and reads the value from its own environment); `/health` counts the identities
  and the open ones;
- a server's home is `/var/lib/invisible-dots/mcp/<identity_id>`, outside `/home/dot`, and a delete removes it; the stand-in
  saves the proxy with its password in `sessions/<identity_id>.json` there, as the real server does, and the TCP port refuses
  that file, its directory and a link to it with `403 outside_home`.

The real server and a real Firefox are not run by this smoke: they are the browser smoke's (below).

## The browser smoke

`browser/smoke.sh` runs the Dot's real browser. The golden image's apt packages (`pins.json`:
the desktop, Firefox's libraries, ImageMagick) are installed, the browser is installed by
`runtime/dot-browser.sh` (the script `provision.sh` runs and `install.sh` updates every Dot with) on
the release before the newest, and the first checks bring it to the newest as a Dot's starts do:
a stage builds the newest beside it, a switch makes it the Dot's browser and removes the old one; the
runtime disk's `dot-desktop` script starts Xvfb and an XFCE session on `:0` as dot, and the Dot
runs as in the engine smoke with no stand-in for the browser: the engine finds
`invisible-playwright-mcp` on its PATH. Only the model is a stand-in, and the pages the browser
opens are served from the container. The browser needs the network twice, at the build (the
engine) and at a launch (the egress address, for the timezone, and the library's GeoIP database). What it pins:

- a Dot on the release before the newest is brought to the newest as its starts bring it: a stage builds the newest
  beside its browser and changes nothing else, a second stage builds nothing, the switch makes the newest the Dot's
  browser and removes the old one, and on the newest a stage and a switch change nothing;
- the model launches an identity and the real server answers that its browser is open; Firefox
  and the server run as `dot`, the server with the profile, its home, a real window on `:0`, no
  proxy variable (an identity with no proxy of its own, the default, inherits the VM's egress) and
  none of the engine's variables nor the key, and nothing of the browser runs as `dotengine`;
- the model navigates to a page, reads its text and takes a snapshot, and what the page says
  reaches the model's request; a screenshot reaches the next request as an image part that is a
  real PNG of the page, with the page's own color in it, and the engine's database holds no
  picture, only the placeholder;
- the screenshot of a page of random pixels, a PNG of more than 500 kB, crosses the relay whole
  and the server still answers after it;
- `GET /v1/screenshot` of `dot-agentd` shows the desktop with the page in it;
- `GET .../frame` answers a JPEG of the identity's real window, not a blank one, and 409 `not_open` after the
  model's close;
- the profile's `.stealth-identity.json` is identical after the model closes the identity and
  launches it again, and after a `kill -9` of the engine in the middle of a session, which ends
  the server and Firefox and leaves the profile locked: the next launch works with that stale
  lock; what a page stored in the profile (localStorage) before the model's close, and before
  SIGTERM, which asks the browser to close, is still there after the next launch;
- Firefox killed under a live server: the model's next page action is answered that the browser is gone and to
  launch the identity again, nothing is reopened (no Firefox), the identity is closed with its server ended, and
  a launch brings back the same person (the seed file is unchanged);
- a proxy is not judged at create: one without a port, which the library cannot use, is kept as written (201, the
  answer says only `hasProxy`), and the model's launch of it fails with the library's own refusal, which names the
  missing port; an identity with a proxy of its own, an
  explicit option (a small authenticating proxy
  of the smoke, `browser/proxy.py`, whose credentials come by its environment) launches: its egress
  lookup went through the proxy with the credentials. The real server saves the proxy with its password in
  its session file under its home (`/var/lib/invisible-dots/mcp/<id>/sessions/<id>.json`, outside
  `/home/dot`): no file under `/home/dot` holds the password, the TCP port refuses the file (`403
  outside_home`), the identity's directory has no MCP home, and a delete removes the home;
- the key is in no file, process environment or log, the browser's included, and the identity's
  events are all in the stream.

## Run it

Only docker is needed, with the images `golang:1.26.8` and `ubuntu:24.04` (pulled when
absent; the container downloads the pinned `uv`, the engine's locked wheels and, for the
browser smoke, the newest browser).

```sh
guest/image-builder/test/smoke/run.sh                  # the repository this script is in
guest/image-builder/test/smoke/run.sh /path/to/tree    # another checkout
git archive --format=tar -o head.tar HEAD
guest/image-builder/test/smoke/run.sh --archive head.tar   # the commit as committed
guest/image-builder/test/smoke/run.sh --suite browser      # the browser smoke (same arguments after it)
```

The same command runs from a Linux shell and from WSL on a Windows host (use the
`/mnt/c/...` path of the repository there). The last line is

```
SMOKE: <passed> passed, <failed> failed, <skipped> skipped
```

and the exit status is 0 only for `0 failed, 0 skipped` and at least one check passed:
a failed check, a skipped check, and a run that never reached the summary all exit 1.
Nothing is kept between runs: the tree is mounted read-only (an archive is unpacked into
a docker volume), what is built goes to a docker volume made for the run, and `run.sh`
removes the volume and the container on exit.

## The files

| file | what it is |
|---|---|
| `run.sh` | the entry: runs dot-agentd's `privileged` Go tests as root in `golang:1.26.8` (they run work as another user; a skipped one fails the run), builds `dot-agentd` there, starts `ubuntu:24.04` with the tree, checks the exit status and the summary line; `--suite browser` runs the browser smoke |
| `prepare-engine.sh` | in the container: the golden image's users, `uv`, the engine's environment, the staged engine source (and for the browser suite the apt packages and the browser); then it runs the suite's checks |
| `lib.sh` | what both suites share: the guest laid out as `install.sh` lays it out, `dot-agentd` and the engine started and restarted, the key and config push, the event stream and the helpers that read it |
| `smoke.sh` | the engine smoke's checks; prints `PASS:` or `FAIL:` per check and the summary line |
| `browser/smoke.sh` | the browser smoke's checks, same output |
| `browser/proxy.py` | the small forward proxy with Basic authentication that the browser smoke's identity with a proxy goes through |
| `fake_openrouter.py` | the stand-in for OpenRouter's chat completions: answers by the last message (`RUN-EXEC <cmd>` makes it call the engine's `exec` tool, `SAY-RUN-EXEC <text> :: <cmd>` the same with `<text>` written beside the call, `WRITE-NOTE <path> :: <text>` a `write_file` into `/home/dot/memory/<path>`, `FIND-NOTE <word>` a `grep` of `/home/dot/memory`, `REPEAT-EXEC <cmd>` an `exec` after every result too, a `COST <usd>` line the cost every response reports in its usage, `RUN-TOOL <name> <json>` a call of any tool with those arguments) and logs every request whole |
| `host-stream.sh` | the fake host's event reader: reads `/v1/agent/events/stream` from its last `seq`, reconnects after a drop, pushes the key and the config on every `agent.started` |

`smoke.sh` is written against the engine as it is: a check that pins something the
engine no longer has is deleted with it. `PIN_REMOVALS` (see the top of `smoke.sh`)
is the one switch left; it reaches the container only when it is set in the
environment of `run.sh`, and a check it leaves out counts as skipped, which fails the
run.

## In CI

The `smoke` job of `.github/workflows/tests.yml` runs `run.sh` on the checkout, on
`ubuntu-latest`, and the `gate` job needs it like every other job. The `browser-smoke` job
runs `run.sh --suite browser` the same way, and the `gate` job needs it too.
`tests/repo/engine-smoke.test.ts` keeps the files, the job and the exit rule from
drifting apart.
