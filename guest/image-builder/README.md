# image-builder

`@invisible-dots/image-builder` builds the two guest images of architecture
section 3.3 on the host, with the same code on Linux and Windows. It is what
`invisible-dots image build` runs. Every host builds its runtime ISO from its
checkout; the golden image it downloads when CI published the one of exactly
its inputs (the release `golden-<inputs digest>`, `src/prebuilt.ts`), and
builds it from public sources otherwise.

Both images land in `INVISIBLE_DOTS_HOME/images`, each with a manifest next to
it (`golden-<v>.json`, `runtime-<v>.json`) that records what went in and the
image's SHA-256; `invisible-dots doctor` checks an image against it with
`verifyImage()`.

## Golden image

`buildGoldenImage({ qemu, accelerator, runner })`:

1. Downloads the Ubuntu 24.04 cloud image pinned in
   `virtualization/images/base.json` and the uv and hev-socks5-tunnel
   downloads pinned in `pins.json`, with Node's fetch. Each published checksum list
   (`SHA256SUMS`, `SHASUMS256.txt`, uv's `.sha256`) must name the pinned hash
   before the download starts, and the downloaded bytes must hash to it (Node
   crypto). hev-socks5-tunnel has no published list, so its pin alone decides.
   Cached copies are re-hashed before every build.
2. Copies the cloud image and grows it with `qemu-img resize` (default 10G;
   each Dot's overlay is larger and cloud-init grows the filesystem).
3. Writes the builder seed with `@invisible-dots/iso`: one ISO labelled
   `cidata` holding `user-data`, `meta-data`, `provision.sh`, `pins.env`,
   the pinned downloads, `engine-requirements.lock`, `build-engine-env.sh`,
   and the runtime disk's `dot-browser.sh` with `other-browsers.txt`. The engine's own source is
   not on it: it is ours, so it travels on the runtime ISO.
4. Boots it once with the QEMU the host runs Dots with, on the accelerator
   the vm-manager chose (`-accel kvm` or `-accel whpx`, never emulation), the
   same machine, CPU model and devices as a Dot (its command line is built
   from the vm-manager's `machineArgs()`). `provision.sh` installs the
   apt packages (Xvfb, a minimal XFCE, the browser's libraries, ImageMagick
   for dot-agentd's screenshots) from the Ubuntu archive as it was at
   `pins.json`'s `apt_snapshot` (`apt-get --snapshot`), uv, then removes the
   cloud image's services a Dot never uses (snapd, unattended-upgrades, apport, the LXD stubs, Ubuntu Pro,
   the release upgrader, the SSH server, pollinate, which would tell Canonical of
   every new Dot), then installs the Dot's browser with
   `dot-browser.sh install <the three releases>`, as user
   `dot`: a virtual environment of its own under `~/.local/share/invisible-dots/browser/`, filled with
   `uv pip install --only-binary :all:` of the versions `pins.env` names, its
   `invisible-playwright-mcp` linked into `~/.local/bin`, and
   `invisible-playwright fetch` run from that environment, so the cached browser
   engine is the one the MCP server expects (the library keeps its own GeoIP
   database, fetched from its release at a launch). The
   browser smoke runs the same script. The only
   browser a Dot has is that server: the build refuses an environment holding a
   package `runtime/other-browsers.txt` names, and a test refuses one among the apt
   packages and the build scripts. `provision.sh`
   then builds the engine's Python
   environment with `build-engine-env.sh <lock> /opt/invisible-dots-engine
   /opt/invisible-dots/engine`: a venv from `/usr/bin/python3` (CPython 3.12)
   filled with `uv pip install --require-hashes --only-binary :all:` from
   `engine-requirements.lock` (wheels only, so no build script of a
   third-party package runs as root), a `.pth` file naming the engine's source
   directory on the runtime disk, tiktoken's encoding table
   prefetched into `share/tiktoken`, and the whole venv owned by root and not
   writable by anyone else. It removes any sudo rule the
   image had (the builder seed gives no user one; each Dot's seed adds a single
   poweroff rule for `dotagentd`, the user dot-agentd runs as), cleans the instance state and powers off.
5. Follows the serial console while the VM runs: `idots-build:` lines are
   progress, `IDOTS-BUILD-COMPONENT:` lines go into the manifest as what was
   installed, and `IDOTS-BUILD-RESULT: ok` is the verdict. A VM that does not
   power off within the timeout (default two hours) is killed. The builder
   VM gets 2 vCPUs and 4 GiB of memory by default.
6. Converts the disk into `golden-<version>.qcow2`, writes the manifest first
   and then the image, read-only.

The browser is never pinned. `src/browser-release.ts` asks PyPI for the newest
`invisible-playwright-mcp`, the newest `invisible-playwright` it accepts and the
`invisible-core` that one names; the three go into the inputs digest, `pins.env` and the
manifest, so a new release is a new image, and the scheduled run of
`.github/workflows/golden-image.yml` publishes it. The engine does not assume a
version: at start it reads the tools and instructions of the server its Dot has
(`invisible_engine_dots/nanobot/dots/server_interface.py`), so a Dot on an older
golden image keeps working with every new runtime disk. Its browser follows the newest release all the same:
at every start the runtime disk's `install.sh` switches to a release an earlier start staged, before the Dot's units
start, and stages the newest one in the background after them (`runtime/dot-browser.sh`).

`builder/engine-requirements.lock` is the same for the engine
(`invisible_engine_dots/pyproject.toml`): the one place its dependency
versions are fixed, regenerated with the command in its header. The same
parser checks it (`src/python-lock.ts`: a hash on every requirement, no
package twice), a test checks that every dependency `pyproject.toml` declares
is pinned in it, and its SHA-256 goes into the manifest as `engine.lock_sha256`.

The default version is `<UTC build time>-<digest of every input>`, the two
locks, `provision.sh` and `build-engine-env.sh` included (the engine's source is
not an input: it is on the runtime ISO). The control
plane gives a new Dot the golden image with the highest version, so the time
prefix makes the newest build win, and a second run with the same inputs finds
the image with that digest and stops. On failure the work directory
(`images/.golden-<version>.work`, with the disk and `serial.log`) is kept and
named in the error.

## Runtime ISO

`buildRuntimeIso()` packs, with label `IDOTS-RT`:

| on the ISO | from |
|---|---|
| `install.sh` | `runtime/install.sh` |
| `vmproxy.py` | `runtime/vmproxy.py`, which `install.sh` runs to set up the Dot's VM proxy |
| `VERSION` | the version |
| `bin/dot-agentd` | `guest/dot-agentd/bin/` (`CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -ldflags="-s -w" -o bin/dot-agentd ./cmd/dot-agentd`), refused unless it is a linux/amd64 ELF |
| `bin/dot-desktop` | `runtime/dot-desktop.sh` |
| `bin/dot-install` | `runtime/dot-install.sh`, the one command `dot` may run as root |
| `engine/nanobot/...` | `invisible_engine_dots/nanobot/`: every `*.py`, the `*.json` data and the `*.md` under `templates/` |
| `engine/skills/<name>/SKILL.md` | `invisible_engine_dots/skills/`, the built-in skills |
| `engine/LICENSE`, `engine/UPSTREAM.md` | `invisible_engine_dots/` |
| `units/*.service` | `units/` |

The version is `<UTC build time>-<digest of the contents>`: every VM start
attaches the ISO with the highest version, and rebuilding unchanged code finds
the ISO with that digest and does nothing. The ISO has no Rock Ridge, so Linux
shows every file on it as readable and executable by everyone; no permission
bit has to survive a Windows host.

Each Dot's seed mounts the ISO by label at `/opt/invisible-dots` and runs
`install.sh` on every boot. The hook copies the units into
`/etc/systemd/system`, creates the two socket directories through tmpfiles (each
admits the two daemons and not `dot`) and the engine's state directory, refuses a golden image without
`dotagentd` or without `/opt/invisible-dots-engine/bin/python`, enables lingering for `dot`, then
enables and starts the units (restarting any whose unit file changed).

## Guest units

| unit | runs |
|---|---|
| `dot-desktop.service` | `Xvfb :0 -nolisten tcp` and `xfce4-session` under `dbus-launch` |
| `dot-agentd.service` | `/opt/invisible-dots/bin/dot-agentd`, as `dotagentd`, on TCP port 1024 of every guest address (QEMU's user-mode NAT delivers the host's forward to 10.0.2.15); it starts the model's commands as `dot`, with `AmbientCapabilities=CAP_SETUID CAP_SETGID CAP_KILL` and no other privilege (architecture 4.1) |
| `invisible-dots-agent.service` | `/opt/invisible-dots-engine/bin/python -I -B -m nanobot`, as `dotengine`: the Dot's engine (architecture sections 4.1 and 8.8) |

The desktop runs as `dot`, the computer daemon as `dotagentd`, the engine as `dotengine` (the builder seed makes the three users); all with `DISPLAY=:0`; the desktop and the engine with a `PATH` starting with
`/home/dot/.local/bin`, where the provisioner linked `invisible-playwright-mcp`. The
daemon's own `PATH` holds system directories only (it starts the poweroff as
itself, so nothing in a directory dot writes may be found through it); it gives the model's commands the `PATH` with
`~/.local/bin`. The guest
enables no firewall: X listens on no TCP port, and port 1024 must stay
reachable from the NAT; every request to it needs the Dot's token.

## Files

Every file under `builder/`, `runtime/` and `units/` runs inside the guest. They
must stay LF-only ASCII (`.gitattributes` keeps them so on a Windows checkout,
and the builder refuses a CRLF file instead of shipping it).

## The engine smoke

`test/smoke/` runs `dot-agentd` (as `dotagentd`, with the capabilities of its unit and
no others) and the engine (as `dotengine`) in one Linux container, with the model's commands
as `dot`. The engine's environment is built by `builder/build-engine-env.sh` on the
hashed lock, as `provision.sh` builds it, and the engine's source is staged as the runtime
ISO stages it. `test/smoke/run.sh` is the entry, and the `smoke` job of
`.github/workflows/tests.yml` runs it; its README says what it proves and how to run it
from Linux or WSL.

## The browser smoke

`test/smoke/run.sh --suite browser` runs the same two daemons with the Dot's real browser:
the apt packages of `pins.json`, the browser installed by `runtime/dot-browser.sh` on the release
before the newest and brought to the newest as a Dot's starts bring it, the runtime disk's `dot-desktop` script (Xvfb and XFCE on
`:0`), and the stand-in model navigating, reading and taking screenshots of pages served
from the container. The `browser-smoke` job of `.github/workflows/tests.yml` runs it, and
the `gate` job needs it. It needs the network for the downloads of the build and for the
egress address of a launch. The README of `test/smoke/` lists what it pins.
