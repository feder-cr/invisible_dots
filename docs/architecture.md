# invisible_dots architecture

This document is the contract every part of the repository is written against.
When code and this document disagree, one of them is a bug: fix the code or
change the document in the same commit.

## 1. What a Dot is

A Dot is a persistent agent that owns a computer. Every Dot has:

- a configuration (name, instructions, model, permissions, resources),
- its own QEMU virtual machine (hardware accelerated) with a persistent qcow2 disk,
- inside that VM, its own agent runtime, which calls models through OpenRouter,
- its own memory, conversation and task state, stored inside the VM,
- zero or more browser identities, each one a separate browser profile with
  its own cookies, storage, logins and fingerprint.

The control plane on the host manages infrastructure: the Dot registry, VM
lifecycle, task dispatch, events, approvals. It never decides what a Dot does
step by step. The reasoning happens inside the Dot's VM.

### 1.1 One mechanism on every host

invisible_dots runs on Linux and on Windows with the SAME code path: the same
QEMU command line, the same networking, the same host to guest channel, the
same way of starting, watching and stopping QEMU, the same database, the same
data directory layout, the same commands. A
difference between the two is allowed only where the operating system makes
sameness impossible, and every such difference lives in ONE function that a
test covers. The complete list today:

| what | Linux | Windows | where |
|---|---|---|---|
| QEMU accelerator | `-accel kvm` | `-accel whpx` | `apps/vm-manager/src/host.ts` `accelerator()` |
| how `doctor` (the CLI's and `GET /api/doctor`'s) reads the accelerator before probing it | `/dev/kvm` opens read-write | the `HypervisorPlatform` feature state through `Get-CimInstance` | `apps/vm-manager/src/accelerator-access.ts` `checkAcceleratorAccess()`, given the host's platform by `hostAccessDeps()` in the same file |
| how `invisible-dots setup` installs QEMU and enables the accelerator | `sudo apt-get install` (or the distribution's equivalent, printed) | one UAC prompt: enables the Windows Hypervisor Platform feature and runs the official QEMU installer silently | `apps/cli/src/setup/install.ts` `installHostPrerequisites()`, given the host's platform by `hostAccessDeps()` of `apps/vm-manager/src/accelerator-access.ts` |
| `setup` run as root | refused: it would check `/dev/kvm` as root and add root to the `kvm` group, not the person who runs the server; it calls `sudo` itself | there is no root; setup always runs as the normal user and elevates its one step | `apps/cli/src/setup/install.ts` `setupRefusal()` |
| a file or directory private to the user (`config/`, `master.key`, `api.token`, `db/`, the data directory) | mode `0600` / `0700` | an ACL that no account but the current user can use, inheritance removed (`icacls`), because Windows ignores the mode bits and a directory under a drive root inherits "Authenticated Users: Modify"; SYSTEM and the local Administrators may stay, as root does on Linux, since some machines grant them explicitly on every new directory | `packages/shared/src/files.ts` `permissionBitsEnforced()` and `restrictToOwner()` |

One line names a platform without being a branch: `agentdBuildCommand()` in
`guest/image-builder/src/runtime.ts` builds dot-agentd with `GOOS=linux
GOARCH=amd64` on both hosts, because that is the guest's platform, not the
host's.

One more branch exists only to let tests run on a Windows developer host:
`packages/shared/src/sockets.ts` `testSocketPath()` hands out a named pipe
there, because Node cannot serve a unix socket on Windows. The guest
code that serves sockets decides from the path (`socketIsAFile()`), never
from the platform. dot-agentd ships for linux/amd64 only, and the build
constraints of ten of its files let its package compile and its tests run on a
Windows developer host; no shipped binary contains the `!unix` or `!linux` side:

- the account the model's work runs as (`LookupAccount`, `actAs`, `ForgetAmbientCapabilities`, `RequireCapabilities`; passwd, `setfsuid` and `prctl` are Linux calls, section 4.1): `guest/dot-agentd/internal/agentd/account_linux.go`, `guest/dot-agentd/internal/agentd/account_other.go`
- `setProcessGroup`: `guest/dot-agentd/internal/agentd/exec_unix.go`, `guest/dot-agentd/internal/agentd/exec_other.go`
- `listenUnixPrivate`: `guest/dot-agentd/internal/agentd/listen_unix.go`, `guest/dot-agentd/internal/agentd/listen_other.go`
- `diskUsage`: `guest/dot-agentd/internal/agentd/platform_unix.go`, `guest/dot-agentd/internal/agentd/platform_other.go`
- the process route and its relay (`startProc`, `killGroup`, `TerminalSize`, `MakeRaw`, `WatchTerminalSize`, `ForwardedSignals`; pseudo-terminals are Linux ioctls): `guest/dot-agentd/internal/agentd/proc_linux.go`, `guest/dot-agentd/internal/agentd/proc_other.go`

`tests/repo/platform-branches.test.ts` reads every product source file
(TypeScript and JavaScript, the build scripts, the guest's shell scripts and
dot-agentd's Go) and fails on a platform check outside this list: Node's
platform and OS probes, `getuid`, the Windows path module, a platform name
as a string, Go's `runtime.GOOS`, build constraints and platform file name
suffixes. The engine under `invisible_engine_dots/` (section 2) is Python and
the test does not read it: it runs only inside the Linux guest, uses unix
sockets and process groups, and has no platform branch (the Windows, macOS and
service-manager code of the nanobot it was forked from is gone).

QEMU has no monitor (no QMP, no HMP) on either host. The control plane sees a
VM's QEMU only as a process, through `process.kill(pid, 0)` and the guest
port its user networking listens on, and reaches the guest only through
dot-agentd (section 5.1); both behave the same on Linux and Windows. That is
what removed the one host-side branch a monitor needed: Node has no AF_UNIX
client on Windows, QEMU's `pipe` chardev there blocks the start until a client
connects and serves one client for the life of the process, and a monitor on
TCP would be reachable from every guest (section 3.6).

Never fall back silently: when the accelerator is missing, starting a VM fails
with a message that says which command fixes it. Software emulation (TCG) is
never used. macOS is not supported in this version: it needs an arm64 guest
image and an arm64 browser build, which are not wired.

## 2. Repository layout

```text
apps/
  api/             control-plane HTTP API + SSE, and the control plane composed as one process (`invisible-dots server` runs it)
  scheduler/       task dispatcher, wake on work, sleep on idle
  vm-manager/      QEMU driver: overlays, seed and runtime ISOs, QEMU argv, port forwards, the guest client, the host's one process runner, the doctor report (section 11.1)
  web/             Next.js web client
  cli/             `invisible-dots`: setup, doctor, image build, server, and the API client commands
packages/
  shared/          types and schemas shared by host and guest: config, protocol, events, states
  database/        PostgreSQL schema (PGlite embedded or an external server), migrations, repositories, durable queue
  iso/             ISO 9660 + Joliet writer in plain TypeScript (seed and runtime disks)
  events/          event types, the host event log and its fan-out to SSE subscribers
  channels/        the messaging channel hub and the Telegram and WhatsApp adapters (section 9.8): pairing, who may talk, the messages between a chat and its Dot; runs inside the control plane process
  sdk/             typed HTTP client for the API (used by cli and web)
guest/
  dot-agentd/             the computer daemon (Go): the guest endpoint, exec, files, screenshots
  image-builder/          golden image and runtime disk builders (TypeScript), guest systemd units
invisible_engine_dots/
                   the Dot's engine, run by `python -I -B -m nanobot` in the guest: a hard fork of
                   nanobot (HKUDS/nanobot, MIT, commit f75470e7), Python 3.11 or newer, provenance
                   and everything removed since the import in invisible_engine_dots/UPSTREAM.md.
                   Import package `nanobot`, distribution `invisible-dots-engine`. Only
                   the engine core is kept: no channel, web UI, TUI, audio, pairing, nanobot
                   skill machinery, subagent, web tool or CLI (the one entry point answers
                   `--version` and refuses every other command). What it carries: nanobot's
                   tool-calling turn runner, chat completions to OpenRouter and no other
                   provider, the tools of the permission table (section 8.8), nanobot's cron
                   service and its MCP client (which serves the Dot's browsers,
                   `invisible-playwright-mcp`, through the `BrowserManager`, and the MCP servers
                   the person declares, through `nanobot/dots/mcp_servers.py`). The Dot's own
                   layer, the contract of sections 5.3 to 5.4, its skills (section 8.6,
                   `nanobot/dots/skills.py`) included, is `nanobot/dots/`. Its own pytest suite runs in CI's `engine` job
                   (`.github/workflows/tests.yml`, Linux only: unix sockets)
virtualization/
  qemu/            the pinned QEMU version for Windows setup (installer URL + SHA-256) and argv notes
  cloud-init/      NoCloud templates
  images/          pinned base image metadata
tests/
  repo/            checks over the whole repository (the platform branches of section 1.1, and the
                   contract of the end-to-end run below with the product)
  e2e/             the real-VM acceptance run (`node tests/e2e/run.ts`, on a Linux host with an
                   accelerator and an OpenRouter key; not in CI), its stand-in Linux host for
                   machines that cannot run it directly, and README.md
  bench/           the agent benchmark on real Dots (Harbor tasks, written by its generators before
                   every run, and LongMemEval), run by hand in a container; README.md
docs/
```

There is no host installer script, no service unit and no container: the host
needs Node 24 and QEMU, and `invisible-dots setup` gets QEMU (section 11).

Everything under `apps/`, `packages/` and `guest/image-builder/` is TypeScript in one
npm workspace. `invisible_engine_dots/` is not part of it: it is a Python project
(`pyproject.toml`, pytest) of its own, and this repository's TypeScript project,
vitest run and npm workspaces all leave `invisible_engine_dots/` out
(`tests/repo/vendored-nanobot.test.ts` checks it). It is a hard fork: it is
changed in place and upstream changes are never merged. `dot-agentd`
is a Go module. Node 24 or newer for the TypeScript. Go 1.25 or newer. Python 3.11 or newer for
the engine; the guest runs it on Ubuntu 24.04's CPython 3.12.

The control plane runs as ONE process (`invisible-dots server`) that composes
`api`, `scheduler` and `vm-manager`. They are separate packages so that each
can be tested alone, not separate daemons. It runs in the foreground the same
way on every host; running it as a service is left to the person.

## 3. Host

### 3.1 Requirements

Linux or Windows on x86-64, Node 24, and QEMU 8.2 or newer (Ubuntu 24.04's
own package; the number lives in `MIN_QEMU_VERSION`, `apps/vm-manager/src/host.ts`)
(`qemu-system-x86_64` and `qemu-img`) with its hardware accelerator usable:
`/dev/kvm` readable and writable by the user on Linux, the Windows Hypervisor
Platform feature enabled on Windows. No administrator rights are needed at run
time. `invisible-dots doctor` checks each item and names the command that fixes
it; `invisible-dots setup` performs those commands (section 11). Building the
golden image boots a builder VM with 2 vCPUs and 4 GiB of memory by default
(`GOLDEN_DEFAULTS` in `guest/image-builder/src/golden.ts`).

QEMU is found in `INVISIBLE_DOTS_QEMU_DIR` alone when that is set (a QEMU from
there mixed with a `qemu-img` from somewhere else would run two versions on the
same disks); otherwise first in the default install location of the official
Windows installer, `%ProgramW6432%\qemu` (read from the variable Windows sets,
so a Program Files on another drive is found; Linux has no such variable and
nothing to check), then on `PATH`. The installer's directory comes first so
the QEMU `setup` just installed wins over an older one on `PATH`; when the
installer reused an earlier install directory, `setup` prints the
`INVISIBLE_DOTS_QEMU_DIR` line that points at it. QEMU is always invoked by
absolute path once found, with the server's home as its working directory
(a Windows process holds its working directory open, so inheriting the
directory the server was started from would keep that directory from being
moved or deleted while any Dot runs).

### 3.2 Host filesystem

One directory, `INVISIBLE_DOTS_HOME`, default `~/.invisible-dots` on every
host (`%USERPROFILE%\.invisible-dots` on Windows):

```text
~/.invisible-dots/
  config/
    master.key                          32 random bytes: encrypts secrets in the database
    api.token                           bearer token for the API (its first line)
  db/                                   the embedded PostgreSQL (PGlite) data directory
  server.lock                           { pid, host_uptime_s } of the one server running on this home
  images/
    noble-minimal-cloudimg-amd64.img     pinned by SHA-256 (virtualization/images/base.json)
    golden-<version>.qcow2              immutable, read-only
    golden-<version>.json               its manifest: inputs, versions, SHA-256
    runtime-<version>.iso               our code: agent bundle + dot-agentd + units
    runtime-<version>.json              its manifest
    .cache/                             verified downloads (re-hashed on every build)
    .golden-<version>.work/             a golden build in progress, kept when it fails
    .golden-build.lock .runtime-build.lock
  vms/<dot_id>/
    disk.qcow2                          overlay, backing file = a golden image
    seed.iso                            NoCloud seed
    qemu.json                           pid file of the running VM: { pid, guest_port, host_uptime_s }, written at spawn
    serial.log                          the guest serial console, truncated at each start
  logs/
    qemu-<dot_id>.log                   QEMU's own output
```

Both hosts use the same layout and the same names; only the root differs, and
only because home directories differ. `<version>` is `<UTC build time>-<digest
of the inputs>`, so the newest build sorts last and rebuilding unchanged inputs
is a no-op; `packages/shared/src/paths.ts` is the one place that names these
files. A path under `INVISIBLE_DOTS_HOME` that contains a comma or any
character outside plain ASCII is refused (`qemuPathProblem()`,
`apps/vm-manager/src/qemu-args.ts`), and `doctor` reports such a home before a
build or a Dot fails on it: QEMU's option syntax cannot carry a comma in every
flag, and the pinned Windows QEMU 11.1, measured, cannot open a `-drive` file
whose path holds a non-ASCII character (an accented Latin letter as much as a
Cyrillic one). Linux would accept UTF-8, but the default home sits under the
account name, and a home that works on one host and not on the other is the
divergence section 1.1 rules out. Nothing under it is a unix socket, so its
length is not limited.

The data directory, `config/` and `db/` are private to the user who runs the
server, and so are `master.key` and `api.token` (section 1.1 says how on each
host); every start brings an existing directory back to that.

`server.lock`, the two build locks and every `qemu.json` record the host's
uptime when they were written (`host_uptime_s`). It only grows within one boot
and starts from zero at the next, so a record from before a host restart is
recognized as stale without trusting a pid, which the operating system may
have handed to another process since. (Windows Fast Startup keeps counting
across a shutdown; such a record falls back to the pid checks of section 3.4.)
The locks are one helper, `acquirePidLock()` in `packages/shared/src/process.ts`:
a lock is taken over only when it is stale (the host restarted, or its pid and
the child process it records are gone, or it names this process's own pid,
which can only be an earlier holder's), only by the one process that creates
`<lock>.takeover` first, and only after reading the lock again unchanged; it is
released only by its holder. The golden build records its builder VM as that
child, so a build killed outright never has its work directory deleted under
a QEMU that still runs. A refusal names the holder and the file to remove.

`qemu.json` is written by the vm-manager (to a temporary name, then renamed)
right after it spawns QEMU, from the spawned process's pid and the guest port
it passed to QEMU. It is the one record of which process and which port belong
to the Dot: QEMU's own `-pidfile` is not used, and the `computers` row (section
9.1) is corrected from it on reconciliation, never the other way round. A file
that does not parse makes the VM's state ERROR, never STOPPED, because a second
QEMU on the same disk would corrupt it.

### 3.3 Two images, two lifetimes

- The **golden image** carries the operating system and third-party software:
  Ubuntu 24.04, Xvfb and a minimal XFCE session, the libraries
  the browser needs, `uv`, `invisible-playwright-mcp` in its own
  Python environment, the browser engine already downloaded (the library
  keeps its own GeoIP database, fetched from its release at a launch), and the Python
  environment of the Dot's engine (`/opt/invisible-dots-engine`). It changes
  rarely. It is never modified once a VM uses it: a new one gets a new version
  in its name.
- The engine's environment holds its third-party packages and not its code.
  `builder/build-engine-env.sh` makes a venv from Ubuntu's own
  `/usr/bin/python3` (CPython 3.12) and installs into it, with
  `uv pip install --require-hashes --only-binary :all:`, every package of
  `guest/image-builder/builder/engine-requirements.lock`: exact versions with
  the SHA-256 of their files, transitive packages included, wheels only, so no
  build script of a third-party package runs as root in the builder VM. The
  lock is the one place the engine's dependency versions are fixed (a test
  checks that every dependency `invisible_engine_dots/pyproject.toml` declares
  is in it), and it is part of the inputs digest, so a changed package is a new
  image. The build also prefetches tiktoken's `cl100k_base` table into
  `share/tiktoken` (the engine never fetches it) and leaves the whole venv
  owned by root and writable by nobody else.
- The engine's own code is on the runtime disk, at `/opt/invisible-dots/engine`
  (its `nanobot` package, `LICENSE` and `UPSTREAM.md`), and a `.pth`
  file in the venv's site-packages puts that directory on the venv's path. Our
  code is ours to change often, so a change to it is a new ISO and not an hour
  of golden build (the engine's source is not an input of the golden digest).
  A runtime disk that needs another dependency needs a new golden image.
- Every input of the golden image but the browser is pinned by content: the
  cloud image, `uv` and the tunnel by SHA-256 (`virtualization/images/base.json`,
  `guest/image-builder/pins.json`). The browser is never pinned: each build
  takes the newest release of `invisible-playwright-mcp` on PyPI, with the
  newest `invisible-playwright` it accepts and the `invisible-core` that one
  names (`guest/image-builder/src/browser-release.ts`). The three versions are
  part of the inputs digest, so a new release is a new image, and the image's
  manifest records the ones installed; the scheduled run of
  `.github/workflows/golden-image.yml` publishes that image without any change
  to this repository. The builder installs them with
  `uv pip install --only-binary :all:`, so no package's build script runs, and
  refuses an environment that holds another browser (the names in
  `guest/image-builder/builder/other-browsers.txt`). The apt packages come from the Ubuntu archive as it
  was at the moment `apt_snapshot` of `pins.json` names (snapshot.ubuntu.com,
  `apt-get --snapshot`), so they and their dependencies are the same on any day
  of the build; apt checks their signatures.
- The **runtime disk** (`runtime-<version>.iso`, attached read-only to every VM
  and mounted at `/opt/invisible-dots`) carries our code: the engine's source,
  the `dot-agentd` binary and the systemd units. A new
  version of our code is a new ISO and a VM restart, not a new golden image and
  not a rebuilt overlay.
- `install.sh` (cloud-init's per-boot script) is what starts the Dot's units,
  on every boot, after the VM proxy: they are copied into
  `/etc/systemd/system` and never enabled. Enabled, systemd would start them at
  `multi-user.target`, and cloud-init's final stage, which runs `install.sh`
  and writes the seed's `config.json` first, comes after that target
  (`cloud-final.service` is `After=multi-user.target`): on every boot after the
  first, a Dot would have gone out before its proxy was set.

The host builds the runtime disk from this checkout, and the golden image from
public sources (`invisible-dots image build`, code in `guest/image-builder/`)
unless CI has published the golden image of exactly the same inputs: the
release `golden-<inputs digest>` of `.github/workflows/golden-image.yml`,
which `image build` downloads instead (`guest/image-builder/src/prebuilt.ts`;
section 11.3). Either way the golden image is provisioned with the same QEMU a
host runs Dots with and the same machine: the builder VM's command line is built from the vm-manager's `machineArgs()`, drive and device
functions, the ones `qemuArgs()` uses, plus only what a builder needs, so a
golden image is provisioned on the machine type, accelerator and CPU model a
Dot boots it on. The seed and runtime ISO labels are each defined once, in
`apps/vm-manager/src/seed.ts`. Both ISOs are written by
`packages/iso`, so no ISO tool is needed on any host.

### 3.4 VM definition

One QEMU process per running Dot, started by the vm-manager with an argument
array (never a shell) built by ONE function, `qemuArgs()`, the same on every
host apart from the accelerator:

```text
qemu-system-x86_64
  -name invisible-dot-<dot_id>
  -machine q35 -accel <kvm|whpx> -cpu host,-vmx,-svm
  -smp <cpu> -m <memory MiB>
  -drive if=virtio,file=<vms/id/disk.qcow2>,format=qcow2,discard=unmap
  -drive if=virtio,file=<vms/id/seed.iso>,format=raw,readonly=on
  -drive if=virtio,file=<images/runtime-<v>.iso>,format=raw,readonly=on
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:<guest_port>-:1024
  -device virtio-net-pci,netdev=net0
  -device virtio-rng-pci
  -serial file:<vms/id/serial.log>
  -display none
```

- No monitor and nothing that pauses: no `-qmp`, no `-monitor`, no `-S`, no
  `-no-shutdown`. QEMU starts running the guest at once and exits when the
  guest powers off. A test fails on any of these flags.
- No fallback: if `-accel` fails, the start fails and the error names the
  fix. If the CPU model is rejected by an accelerator, the error says so; it
  is not replaced by a guessed model without an explicit decision recorded here.
- Start: spawn QEMU detached (so the control plane can restart without
  stopping Dots), with an allowlist of the server's environment
  (`allowlistedEnvironment()`, `packages/shared/src/environment.ts`: what a
  program needs to start and find its files, never `INVISIBLE_DOTS_TOKEN` or a
  `DATABASE_URL`, which a QEMU that outlives the server would otherwise keep),
  write `qemu.json`, then wait until QEMU listens on the guest
  port and is still running 1 s later. The listening port means QEMU parsed
  its command line, opened the accelerator and set up networking; the second
  look catches what fails just after (QEMU checks the CPU model when it builds
  the machine). A QEMU that exits is reported with what it wrote to
  `logs/qemu-<dot_id>.log` during this start; one that never listens within
  30 s is killed and reported the same way.
- A QEMU that starts but never brings the guest up (a vCPU the accelerator
  stopped, a guest stuck in its firmware or kernel) is caught by the READY
  procedure (section 9.3): waiting for `GET /v1/health` fails after its timeout
  with the end of `logs/qemu-<dot_id>.log` and of `vms/<dot_id>/serial.log` in
  the error, and at once when QEMU exits meanwhile.
- State: STOPPED when there is no `qemu.json`, its process is gone, or it was
  written before the host last restarted; RUNNING when its process is this
  Dot's QEMU (the rule below); ERROR when a live pid cannot be proven to be (it
  is reported and never killed). Whether the guest inside is up is guest
  health, which the READY procedure checks; the state of a Dot is both
  (section 9.3).
- Which process may be killed, the one rule: a process this control plane
  spawned and whose exit Node has not reported (Node holds that process, so
  its pid cannot be recycled meanwhile), or a pid from a `qemu.json` written
  in this boot that is alive and this user's (`process.kill(pid, 0)`
  succeeds; EPERM means another user's process, and a QEMU this control plane
  spawned always runs as its own user) AND whose guest port from the same file
  accepts a TCP connection on 127.0.0.1. QEMU's user networking listens on that
  port from the moment it is set up until the process exits, whether or not the
  guest is up; a process that inherited a recycled pid after a crash or a host
  restart does not listen on that one port. The rule is checked again right
  before every kill. Anything else is never killed. A listener that passes it
  is still not trusted with the Dot's token: the guest must prove it holds the
  token first (section 5.1).
- Stop: `POST /v1/system/poweroff` through the guest channel with the Dot's
  token (section 5.2), then wait up to 60 s for QEMU to exit, then kill it
  (SIGKILL on Linux, TerminateProcess on Windows, both through
  `process.kill`) and wait up to 10 s for it to go. A guest that does not
  accept the poweroff (it is not up, or the request fails) cannot power itself
  off, so its QEMU is killed at once. Destroy kills without a poweroff: the
  disk goes too. The VM's files are rewritten or removed right after its QEMU
  stopped (the seed at the next start, everything at a destroy) through one
  retry while a file is in use (`retryWhileInUse()`,
  `packages/shared/src/replace-file.ts`, which also replaces every file this
  repository writes atomically, through `replaceFile()`): Windows can report a process gone before
  its handles are closed, and an antivirus may hold a file for a moment; on
  Linux the first try succeeds.
- Reboot is a stop and a start, not a reset: a reset skips the guest's
  shutdown and would not apply a new runtime ISO, CPU count or memory size.
  The guest port changes on reboot.
- Reconciliation, the one path for it: reading a VM's state (the vm-manager's
  `state()`, which the control plane's recovery after a restart calls for
  every Dot) removes a `qemu.json` whose process is gone the moment it reads
  it, under the Dot's lock, so a pid recycled later cannot make it look alive.
  A VM whose process is its QEMU is adopted with the pid and port from the
  file, and the READY procedure then checks its guest.
- The seed is rewritten at every start. Its cloud-init instance-id is
  `iid-<dot_id>-<digest of the seed>`, so cloud-init re-runs its per-instance
  steps only when the seed's content changes.
- Measured with QEMU 8.2.2 (Ubuntu 24.04) and KVM: this argv starts, the
  forward listens about 0.2 s after the spawn, and a taken port exits with
  `Could not set up host forwarding rule`, the message the start retries on.
- The CPU model is the host's own without the virtualization extensions,
  `host,-vmx,-svm` (`CPU_MODEL` in apps/vm-manager/src/qemu-args.ts), on every
  accelerator: a Dot never runs a hypervisor. Measured with QEMU 11.1 on
  Windows 11 (Intel Core Ultra 7 255H, hypervisor running): `-cpu host` and
  `-cpu max` pause the VM at its first firmware instructions with
  `WHPX: Unexpected VP exit code 4`, while `-cpu host,-vmx` boots the Ubuntu
  cloud image to its login prompt; no other host CPU feature mattered
  (bisected). `-svm` is the AMD name of the same extension.

### 3.5 Port forwards

`<guest_port>` is a free TCP port on 127.0.0.1, chosen at each start (bind to
port 0, read it, release it, pass it to QEMU; retried if QEMU reports the port
taken) and recorded in the `computers` table. A port is never a credential:
every request to a guest carries the Dot's token (section 5.1).

### 3.6 Networking and its limits

QEMU user-mode networking gives every Dot its own NAT with no bridge, no
administrator rights and the same behaviour on every host. Dots cannot reach
each other's guest addresses. A guest CAN reach services on the host's
loopback through `10.0.2.2`, which includes the control plane API, the web
client and the other Dots' forwarded ports. All of them require a credential
the guest does not have: the API's bearer token, the web client's session
(section 9.7; its Host and Origin checks are written by the client and so
cannot be what lets a request through), and each Dot's own token, which a
forwarded port answers only after proving it holds it (section 5.1). QEMU has
no monitor anywhere. Nothing else should listen unauthenticated on the host's
loopback while Dots run; `invisible-dots doctor` cannot check that, and this
document says so.

## 4. Guest

### 4.1 Processes (systemd, each unit as the user it names)

| unit | user | what |
|---|---|---|
| `dot-desktop.service` | `dot` | `Xvfb :0 -nolisten tcp` plus a minimal XFCE session on it |
| `dot-agentd.service` | `dotagentd` | the computer daemon; TCP port 1024 (reached only through the host's port forward) and a local unix socket |
| `invisible-dots-agent.service` | `dotengine` | the Dot itself: the engine (`/opt/invisible-dots-engine/bin/python -I -B -m nanobot`) |

Three users, none of them shared (all made by the image builder's seed):

- `dot` runs the desktop, the browser and **every command of the model**. It is
  the one user the model controls. It is in the groups `audio`, `video` and
  `systemd-journal` (it reads its computer's system journal; cloud-init adds no
  group to a user that exists already, so the groups are given where the user is
  created, by the image builder's seed). It has no sudo rule.
- `dotagentd` runs dot-agentd. It holds the Dot's token (`/etc/invisible-dots/config.json`,
  0600) and owns `agentd.sock`. It has no home, no login and no group but its own.
  It is the one user that may run one command as root, `/usr/bin/systemctl
  poweroff` without a password, which is what dot-agentd starts when the host
  stops the VM (section 5.2). The Dot's seed writes that rule; the golden image's
  builder seed gives nobody one and the provisioner removes any rule the image
  had, because a Dot's seed only adds its rule to that file.
- `dotengine` runs the engine. It is in group `dot` so it can read and seed the
  Dot's workspace, and its unit runs it with `UMask=0002`. It holds the
  OpenRouter key in memory and owns its state (`/home/dotengine/state`, 0700).
  It needs no privilege: there is no sudo rule for it and no root-owned
  configuration file (the Dot's config is stored in the engine's own database,
  section 8.8), and its unit sets `NoNewPrivileges=yes`, so nothing it starts can
  gain one.

dot-agentd does not run the model's work as itself. Every command (`POST /v1/exec`
and the engine's `dot-agentd relay`), every file operation of the file routes of
both listeners, the browser's MCP servers (which the engine starts through the
relay) and the screenshot run as `dot`:

- a process is started with `SysProcAttr.Credential`: dot's uid, gid and
  supplementary groups (the daemon's own are not inherited);
- a file route acts as `dot` for the length of the request: the file-system user
  and groups of the thread that serves it are dot's, as an NFS server's are for a
  client's. The files it opens, creates and renames are dot's and are checked as
  dot's, and the home confinement of the TCP listener (section 5.2) is decided on
  top of that, unchanged;
- a pseudo-terminal for a command is opened as `dot`, so the terminal belongs to
  it.

The privileges that takes are the unit's `AmbientCapabilities=CAP_SETUID
CAP_SETGID CAP_KILL` (change to dot; end a process group of dot's) and nothing
else. The daemon empties its ambient set before it starts anything, whatever
`--run-as` says, so no program it starts holds one: a command of the model has
`CapPrm`, `CapEff` and `CapAmb` zero, and the smoke asserts it. It refuses to
start without the three when it is to act as another user. `--run-as` (default
`dot`, `INVISIBLE_DOTS_RUN_AS`) names the user; an empty value runs the work as
the daemon's own user, which is for development and which the daemon says in its
log (the ambient set is emptied then too).

What the daemon runs as itself is found through no directory the model writes.
The unit gives it a `PATH` of system directories only, and every program it
starts for itself is named by path (`/usr/bin/sudo -n /usr/bin/systemctl
poweroff`, `/bin/bash`, `/usr/bin/import`): a `sudo` planted in dot's
`~/.local/bin` (dot owns its home and can open it) would otherwise be run as
`dotagentd` by the next poweroff. The `PATH` of the model's commands, dot's
`~/.local/bin` in front of the system's, is built by the daemon with the rest of
their environment (`execEnv`), not inherited from its own. The engine, which holds
the OpenRouter key, has the same rule: its unit's `PATH` is system directories
only, and the one program of dot's it needs, the browser's MCP server, is named by
its path (`INVISIBLE_DOTS_MCP_COMMAND=/home/dot/.local/bin/invisible-playwright-mcp`)
and started as dot through the relay.

What this closes: no process of the model's shares a uid with a daemon, so the
model can neither read the Dot's token nor read the memory of dot-agentd or of
the engine, nor signal or stop either, nor reach either socket (their
directories admit only the two daemons, section 4.2). The engine's socket does
not rely on its directory alone: the engine asks the kernel who connected
(`SO_PEERCRED`) and refuses a process of `dot` (`INVISIBLE_DOTS_MODEL_USER`,
default `dot`; the engine does not start when that user does not exist). The
engine's API has no authentication of its own, so what would let the model
`PUT /config` with every permission `allow`, or approve its own parked calls
with `POST /events`, is exactly what these two walls keep out, and the smoke
tries both as the model does. The model can connect to TCP port 1024 inside its own
computer too, and gets `401` without the token. A process of `dot` could listen
on port 1024 only while dot-agentd is not running, and the host does not send
the token or the key to a listener that cannot answer the proof of section 5.1.
What this does not protect, stated as it is:

- The split is the guest operating system's. A flaw in the guest's kernel, or a
  way to become root that is not known here, would let a process of `dot` read
  what the other two users hold. The VM is the outer wall then, and what it lets
  the guest reach is section 3.6's.
- The daemon's three capabilities make a flaw in dot-agentd worth more than a
  flaw in an ordinary program: `CAP_SETUID` lets it become any user, root
  included, and it is the one user with a sudo rule (the power-off). It is a
  small program and its one door, the TCP port, needs the token, which `dot`
  cannot read; the model can reach the port and gets `401`.
- `dot` owns the desktop, the browser and `/home/dot`, and reads the proxy of an
  identity whose browser is open (section 6). That is the model's computer, not
  a leak out of it.
- Nothing limits how much disk, memory or processor time `dot`'s processes use
  of the VM's (no cgroup limit, no quota), so a runaway command can starve the
  daemons of the same VM until the host stops or restarts it. The control plane
  records a VM that stops without being asked as STOPPED and starts it again
  when the Dot has work (section 9.5).

There is no long-running browser service. The engine's `BrowserManager`
starts one `invisible-playwright-mcp` process per launched browser identity
(section 6), through `dot-agentd relay`, so the process runs as `dot` and not
as `dotengine`: its environment is the one the relay builds for `dot` (none of
the engine's variables, never the OpenRouter key) plus the variables of
section 6. The engine closes them with the rest of its work (section 8.8).

Everything the model runs (the engine's `exec`, `POST /v1/exec`) therefore runs
as `dot`, which has no way to become root: the model cannot power its computer
off through sudo. A Dot that stops without being asked is still recorded as
STOPPED and started again when it has work (section 9.5).

### 4.2 Guest filesystem

```text
/etc/invisible-dots/config.json     written by cloud-init: dotId, token (0600, owner dotagentd: dot-agentd's alone)
/opt/invisible-dots/                the runtime ISO, read-only: the engine's source (engine/), dot-agentd and the units
/opt/invisible-dots-engine/         the engine's Python environment, built into the golden image (section 3.3)
/home/dotengine/state/              the engine's state (0700): engine.sqlite, which holds the Dot's tables and the
                                    transcripts (section 8.8), and cron/jobs.json, the automations
/home/dot/
  workspace/                        the engine's agent workspace too: group dot, setgid, 2775
  downloads/  documents/
  memory/                           long-term memory notes (files; MEMORY.md is in every prompt; section 8.6)
  conversations/                    chat/<day>.md and tasks/<day>-<task id>.md, what was said (section 8.6)
  browsers/<identity_id>/
    profile/                        the browser profile
/var/lib/invisible-dots/            root, 0755
  mcp/<identity_id>/                INVISIBLE_MCP_HOME for that identity's server (dot, 0700; outside /home/dot on purpose)
/run/invisible-dots/                dotagentd:dotengine 2750
  agentd.sock                       dot-agentd's local API for the engine (dotagentd:dotengine 0660)
/run/invisible-dots-agent/          dotengine:dotagentd 2750
  agent.sock                        the engine's API, reached by dot-agentd's proxy (dotengine:dotagentd 0660)
```

The home of an identity's MCP server is not under `/home/dot` because the
server saves who its browser is, and for an identity that has a proxy of its
own that proxy with its password included, in
`<home>/sessions/<identity_id>.json` on every `browser_open`: a file under
`/home/dot` would be served by the host's file routes (section 9.6), which read
`/home/dot` and nothing else, and dot-agentd's TCP listener refuses a path
outside it (`403 outside_home`). The directory is made by the image's
provisioner and by `install.sh` (dot owns it, the server runs as dot) and the
`BrowserManager` makes and removes one subdirectory per identity.

Each socket sits in a directory its server owns and only the other side may
enter, setgid so the socket takes that side's group (`install.sh` writes both
to tmpfiles): dot-agentd's directory is `dotagentd:dotengine`, so the engine
(group `dotengine`) reaches `agentd.sock`, and the engine's is
`dotengine:dotagentd`, so dot-agentd (group `dotagentd`) reaches `agent.sock`.
`dot` is in neither group and owns neither directory: it cannot enter either
one, so it can neither talk to the engine or to dot-agentd's local socket nor
put another socket where the host pushes the key. The engine adds a check of
its own on the connection (section 4.1).

One engine process owns `engine.sqlite`: it opens it in SQLite's exclusive
locking mode and takes the write lock at once, so a second process on the same
file fails at open ("another engine owns ...") and refuses to start, and the
kernel releases the lock the moment the owner dies, so a restart opens it
again without waiting. Nothing else opens the file; the host reads the guest
only through the engine's API.

dot-agentd reads the Dot's home from `DOT_HOME` (default `/home/dot`; the
units do not set it). `INVISIBLE_DOTS_HOME` is the host's data directory
(section 3.2) and is never read in the guest: one name, one place.

### 4.3 Secrets

The OpenRouter key is never written into the golden image, the runtime ISO or
the seed. After the guest reports healthy, the control plane pushes it over
the guest channel (`POST /v1/agent/secrets`) and the engine keeps it in memory only. A VM
that restarts asks for nothing: the control plane pushes it again on every
READY transition, and an engine process that restarts inside a running VM
(systemd restarts it after a crash) announces itself with an `agent.started`
outbound event, on which the control plane pushes the key and the config
again. The Dot's own token is the one secret in the seed; it only
authorizes requests to this one VM.

"Memory only" keeps the key off every disk; it is not on its own what keeps
it from the commands the model runs. What does: they run as `dot`, a user that
is neither the engine's nor dot-agentd's, and `dot` cannot become root (section
4.1), so it cannot read another process's memory through root; Ubuntu's Yama
`ptrace_scope=1` lets a process trace only its own descendants, and the
model's commands descend from dot-agentd, not from the engine; and the engine
is a process of another user, so ptrace of it is refused in any case. CPython opens no debugger or inspector
on a signal, so nothing can be asked of the process from outside; the unit's
`LimitCORE=0` keeps the key out of core files and `NoNewPrivileges=yes` keeps
anything the engine starts from gaining a privilege. A change to any of these
reopens the question.

In the engine the key lives in one object, `KeyHolder`
(`nanobot/dots/secrets.py`): `POST /secrets` sets it, and the one place that
builds the model provider (`nanobot/dots/provider.py`) reads it. It is never
logged, written or put in an environment, and the server logs a request's
method, path and status and never a body. Nor does it leave in an error:
the holder refuses a key that cannot travel in a header (anything but printable
ASCII without spaces: a newline inside a key makes h11 raise `Illegal header
value b'Bearer <key>'`, and the openai client chains that under its own
exception). That rule has one owner, `packages/shared` (`OPENROUTER_KEY_PATTERN`
and `OPENROUTER_KEY_RULE`): the host applies it where the key enters, so
`PUT /api/secrets/openrouter` answers `400 invalid_request` for a key that breaks
it, and the holder applies the engine's copy of the same two constants again on
`POST /secrets` (a repository test keeps the copy equal). The same key again changes nothing:
no new provider is built and no running turn is disturbed, so the host's
pushes at every READY and `agent.started` cost nothing. A new key builds the
provider of the next turn; a running turn keeps the one it began with. The
engine reads no credential from its environment: no provider spec names an
environment variable.

The secrets of the MCP servers a Dot declares (section 7) travel the same
way: stored encrypted under the Dot's scope as `mcp/<server>/<NAME>`, set and
cleared write-only (section 9.6), pushed in the same `POST /secrets` as the key
(`mcp_secrets`, by server and name, only those the config names), held in
memory by `McpSecrets` (`nanobot/dots/secrets.py`) and masked in the
conversation files. Unlike the key, a secret leaves the engine for the server
that names it, because that is what it is for, as in every MCP host: a
command's secret is an environment variable of its process, which the relay
receives in its own environment (only its name is on the relay's command line,
`--env-from`), and a URL's is a header of its requests. Its value is printable
ASCII, a space allowed (`Bearer <token>`): one rule, `MCP_SECRET_PATTERN` and
`MCP_SECRET_RULE` in `packages/shared`, applied by the host where it enters and
by the engine on `POST /secrets`. A config that no longer names a secret (its
server removed, its name dropped) deletes its value in the same transaction, so
none is kept that nothing uses.

A secret also never travels in an error: a failed push of the key is reported
by route, status and code only (`the guest did not take the OpenRouter key
(status 502, ...)`), never with the text the guest or a proxy answered, which
could echo the key into a Dot's error, the log or the event log.

## 5. Host to guest protocol

### 5.1 Transport

HTTP/1.1 over TCP. `dot-agentd` listens on port 1024 inside the guest, and
QEMU forwards `127.0.0.1:<guest_port>` on the host to it (section 3.5). Node
calls `http.request({ host: "127.0.0.1", port })`, the same on every host.
Every request carries
`Authorization: Bearer <dot token>`; `dot-agentd` answers 401 to anything else.
Connections go host to guest only: the guest never connects to the host. Events
flow back over a stream the host opens (5.3).

A port is not a credential (section 3.5), so the host does not send the token
to whatever listens on one: after a host restart or a QEMU that died, another
local process can listen on a port the host still has on record. Before the
first request that carries the token, the guest client asks
`GET /v1/proof?nonce=<16 random bytes in hex>`, the one route without a token,
and requires `{ proof: HMAC-SHA256(token, "invisible-dots guest proof v1\n" +
nonce) }`, compared in constant time. A listener that cannot answer it never
sees the token, the key or the config; the call fails with
`guest_unproven`, which is not retried.

### 5.2 dot-agentd routes (TCP port 1024, token required)

| method and path | body / query | answer |
|---|---|---|
| `GET /v1/proof` | `?nonce=` (32 to 128 lowercase hex characters); no token | `{ proof }`, section 5.1 |
| `GET /v1/health` | | `{ agentd: "ok", agent: <agent /health or {status:"down"}>, uptime_s }` |
| `GET /v1/system` | | `{ hostname, uptime_s, cpus, mem_total_bytes, mem_available_bytes, disk_total_bytes, disk_free_bytes }` |
| `POST /v1/exec` | `{ command, cwd?, timeout_ms? }` | `{ exit_code, stdout, stderr, timed_out }` (bash -lc, output capped at 1 MiB each) |
| `GET /v1/files` | `?path=` | file bytes |
| `PUT /v1/files` | `?path=`, body = bytes | `204` |
| `GET /v1/files/list` | `?path=` | `{ entries: [{ name, type: "file"\|"dir"\|"other", size, mtime }] }` |
| `GET /v1/screenshot` | | `image/png` of display `:0` |
| `POST /v1/system/poweroff` | | `202 { status: "powering_off" }` after starting `/usr/bin/sudo -n /usr/bin/systemctl poweroff` detached (the seed lets `dotagentd`, the user the daemon runs as, run exactly that without a password, section 4.1); `500 poweroff_failed` when it cannot be started. How the control plane stops a VM (section 3.4) |
| `* /v1/agent/<rest>` | | reverse proxy to `unix:/run/invisible-dots-agent/agent.sock` at `/<rest>` |

The three file routes are limited to home on the TCP port, the host's door:
the path is resolved with every symbolic link followed and a real location not
under home is a `403 outside_home`. On `agentd.sock` they take any path the
Dot's user may open. On both, the routes act as `dot` (section 4.1): the daemon
runs as `dotagentd`, which cannot open the Dot's files, and a file one of them
creates belongs to `dot`. So a path `dot` may not open, the Dot's token file
and the engine's state among them, is a `403 permission_denied` on both.

The same routes, without `/v1/agent`, `/v1/proof` and `/v1/system/poweroff`,
are served on `agentd.sock` for the engine (no token: section 4.2 says who can
reach the socket), plus one route of that socket only:

| method and path | body | answer |
|---|---|---|
| `POST /v1/proc` | `{ argv, cwd?, env?, tty?: { cols, rows } }`, with `Connection: Upgrade`, `Upgrade: dots-proc/1` | `101 Switching Protocols`, then frames both ways (one type byte, a big-endian uint32 length, the payload): from the caller `i` input, `e` end of input (^D on a terminal), `r` size (uint16 cols, uint16 rows), `s` a signal number for the process group; from dot-agentd `o` output, `E` error output (none on a terminal), and last `x`, the JSON `{ exit_code, signal? }`. `426` without the upgrade, `400` for an empty program or a bad cwd |

It runs the program as `dot` (the daemon changes to that user for the program;
section 4.1), without a shell, in its own process group, on a pseudo-terminal
when asked (a new session whose controlling terminal it is, and which `dot`
owns). The program's environment is the daemon's with `HOME`, `USER`, `LOGNAME`
and `SHELL` of `dot`'s account, plus `DISPLAY` and the request's `env`.
The process lives exactly as long as the connection: a caller that goes away
takes the whole group with it. Its client is `dot-agentd relay [--socket P]
[--cwd DIR] [--tty] [--env NAME=VALUE]... [--env-from NAME]... -- PROGRAM
[ARGS...]`, which copies its own standard input and output through and exits with the program's code
(128 plus the signal number when a signal ended it); with `--tty` and a
terminal on its input it puts that terminal in raw mode and forwards its size
changes. The engine runs the model's every command through it, and reads and
writes the model's files through the `/v1/files` routes of the same socket
(section 8.8). Sleep, stop and reboot are the control plane's decisions,
and the agent's socket offers no poweroff. Nor can the model power its computer
off through sudo: `dot` has no sudo rule (section 4.1), and cannot read the
token in `/etc/invisible-dots/config.json` either. A Dot owns its computer, not
the daemon that serves it. What the control plane guarantees is the outcome: a
VM that stops without being asked is recorded as STOPPED, and started again
when its Dot has work (section 9.5).
Paths in file routes are resolved against `/home/dot` when relative.

A command of `POST /v1/exec` runs in its own process group, and dot-agentd
kills the whole group when the command reaches its timeout and when the
request that started it goes away: a cancelled call, a tool cut at the stop
grace and an agent that died all take their command with them. A command that
runs through a relay (the engine's) is held the same way: the relay is a child
of the engine that lives as long as the remote command, and ending it ends the
remote process group. Only what the
command detached into another session outlives it.

### 5.3 Agent routes (the Dot's engine, reached as `/v1/agent/...`)

| method and path | body | answer |
|---|---|---|
| `GET /health` | | `{ status: "ok"\|"starting", state: AgentState, openrouter_configured: bool, browser: { identities: n, open: n }, checks }`; `identities` is the number of rows and `open` the number of identities with a live browser |
| `POST /secrets` | `{ openrouter_api_key, mcp_secrets }`; `mcp_secrets` is `{ <server>: { <NAME>: value } }`, the secrets of the config's MCP servers that are set | `204`; `400 invalid_secret` holds neither, and never says a value |
| `PUT /config` | `DotRuntimeConfig` (section 7) | `204`, validated, persisted in the engine's database (`dots_kv`) and projected onto the engine's settings in process (section 8.8); a config that does not validate is `400 invalid_config` |
| `POST /events` | `InboundEvent` | `202 { accepted: true }` |
| `GET /events/stream` | `?after=<seq>` | `text/event-stream`, one SSE message per outbound event, `id: <seq>` |
| `GET /state` | | `{ state, current_task_id, pending_approval }`; `pending_approval` is the id of the oldest approval the engine waits on, or `null` |
| `GET /browser-identities` | | `{ identities: BrowserIdentity[] }`, oldest first; an identity says `hasProxy` and nothing of its proxy, which is a secret |
| `POST /browser-identities` | `{ name, proxy? }`; `proxy` is an explicit option: absent, `null` or blank means none, the normal case | `201 BrowserIdentity`; `400 invalid` (a name that is empty or too long, or a proxy that is not a string; a proxy that is a string is kept as written and judged by invisible-playwright-mcp when the identity launches), `409 limit` (the 20 identities the engine keeps at most) |
| `GET /browser-identities/:id` | | `BrowserIdentity`; `404 not_found` |
| `DELETE /browser-identities/:id` | | `204` after the identity's browser is closed and its directory removed; `404 not_found` |
| `GET /browser-identities/:id/frame` | | `200 image/jpeg` (`Cache-Control: no-store`), one frame of the identity's window, taken with the server's `browser_watch`; `404 not_found`; `409 not_open` when the identity is closed; `503 busy` when a call of the Dot held the identity for longer than 5 seconds; `502 frame_failed` (the server has no page to show, or sent a frame that is not a JPEG: the engine is the one owner of that rule, the host passes the bytes on as `image/jpeg`) or `crashed` |
| `POST /browser-identities/:id/close` | | `204` after the identity's browser is closed through `browser_close` and its server has ended; the profile stays. Closing a closed identity is a `204` too; `404 not_found` |
| `GET /tools` | | `{ tools: [{ name, permission, offered, description }], mcp_servers: [{ name, state, error, tools }] }`: the engine's tool table (section 8.8) in its order, then the tools of the declared MCP servers that are connected (permission `mcp.<server>`); `offered` is whether the model is offered the tool now (its permission is not `deny`, and a tool that creates or deletes a browser identity needs the Dot to manage its identities; before the first config, none); `description` is the one in the tool's schema. `mcp_servers` is every declared server by name, `state` `connecting`, `connected` or `failed`, `error` why it failed (section 8.3) |
| `GET /skills` | | `{ skills: [{ name, description, source, path, content }] }`: the Dot's skills (section 8.6) by name, the built-in ones and its own (`source` is `builtin` or `dot`), each with the whole of its SKILL.md |
| `POST /prepare-sleep` | | `204` after the state is flushed and browser sessions are closed; the agent then starts no new work. A model request in flight is abandoned; a tool in flight gets up to 20 seconds to finish and record its result, then is aborted (section 8.7). A `POST /secrets` (the READY procedure of a VM whose stop failed, so no shutdown followed) lifts that, and so does a new inbound event |

The identity routes and the model's identity tools are one code path, the
`BrowserManager` (section 6), so its limits hold for both. A route answers an
error as `{ error: <code>, message }` with the status of its code: `invalid`
400, `not_found` 404, `limit` and `not_open` 409, `busy` 503, `crashed` and
`frame_failed` 502. The engine has no route that launches an
identity: only the model's tools open a browser, so `browser.identity.launch`
alone decides whether one starts, and `launch_failed` is an answer of those tools,
never of a route. The host may look at an open identity (the
frame) and close it (or delete it); these are the owner's actions, not the Dot's, so
no permission of the Dot applies to them. A frame is no use of the identity: it does
not move it in the least-recently-used order, does not touch `last_used_at`,
and never reopens a browser the server lost (that is `not_open`, and the identity is closed, as for a call that finds it out); it waits for
the call in flight on the identity at most 5 seconds, so a page that asks for a
frame every two seconds cannot hold a browser open or starve the model.

Outbound events are written to an outbox table in the Dot's database before
they are streamed, with a monotonically increasing `seq`. The host stores the
last `seq` it saved per Dot and reconnects with `?after=`. Nothing is lost when
the control plane restarts or the VM sleeps.

The engine serves these routes from `nanobot/dots/server.py` (aiohttp), on the
unix socket `INVISIBLE_DOTS_AGENT_SOCKET` names (mode 0660; a socket file left
by a crash is removed first), and binds no TCP listener. Its outbox is the
`dots_outbox` table of `engine.sqlite` (section 8.8). Every outbox row is
written by this one process through `DotStore.write`, which wakes the open
streams after the transaction commits, so the stream replays from the table
after `?after=` (or `Last-Event-ID`) and then sends each row once as it
commits, with a keep-alive comment every 15 seconds; there is no poll.

### 5.4 Event shapes

```ts
// guest to host, persisted in the guest outbox
interface OutboundEvent { seq: number; id: string; type: OutboundEventType; ts: string; data: object }
// host to guest
interface InboundEvent  { id: string; type: InboundEventType; ts: string; data: object }
```

Inbound types: `user.message {text}`, `task.created {task_id, description,
priority}`, `approval.received {approval_id, decision: "approve"|"reject",
note?}`, `system.event {name, data}`. A task cancelled after its
`task.created` may have reached the guest is cancelled there with
`system.event { name: "task.cancelled", data: { task_id } }`. The guest keeps
the id of every inbound event it accepted and ignores one it already has, so
the host may send an event again whenever the outcome of a send is unknown
(section 9.2). An inbound event is recorded and applied in one transaction
(a `user.message` is applied when its chat turn is answered): an event the
guest has accepted is never lost to a restart, and one whose transaction
failed was not accepted, so its redelivery is.

Outbound types: `agent.started {}` (the first event of every start of the
agent process, section 4.3), `agent.state {state}`, `message.assistant {text,
in_reply_to?, spent_usd?}`, `task.started {task_id}`, `task.progress {task_id,
text, spent_usd?}`, `task.completed {task_id, summary, spent_usd?}`,
`task.failed {task_id, error, spent_usd?}`,
`approval.requested {approval_id, task_id?, tool, permission, arguments,
reason}`, `tool.called {task_id?, tool, permission, decision, ok,
duration_ms, target?, tty?, interrupted?}`, `browser.identity.created|deleted|launched|closed
{identity_id, name}`, `automation.next_run {next_run_at_ms}`,
`memory.updated {conversations, changed, spent_usd?}`, `mcp.server.added {arguments}`.
`interrupted: true` marks a call
the engine stopped during: its outcome is unknown and it was not run again, so
`ok` is false and `duration_ms` is 0. `tty: true` marks a call that started a
terminal session (`exec` with `tty`, section 8.3), which is not what its target
says (the command): a client shows "Started a terminal session: python3". It is
absent for every other call, and the permission table
(`TOOL_PERMISSIONS[...].starts_terminal`) is where a tool says it can.

`task.progress {task_id, text}` is the model saying what it is about to do: the
text an assistant message of a running task carries beside its tool calls (the
message is not the final answer). It is sent once per such message, in the
transaction that stores the message, so a restart neither loses nor repeats it
and it comes before the `tool.called` of those calls. The text is trimmed and
cut at 2000 characters, the last one an ellipsis. A message with no text beside
its calls sends nothing, and neither does the chat: the answer of a chat turn
is its `message.assistant`, and the final answer of a task is its
`task.completed`.

`tool.called.target` is what the call acted on, in one line of at most 160
characters (`TOOL_TARGET_MAX`, in code points as the host's schema counts them;
it refuses a longer, empty or multi-line one), so a client can say "ran `make test`" and not only "exec ok".
It is a name or a place, never content. The permission table
(`nanobot/dots/permissions.py`) gives each tool a function that states what of
its arguments may be shown: `exec` the first line of the command, as it is;
`read_file`, `list_dir`, `write_file` and `edit_file` the path; `find_files` the
query, else the glob, else the path; `grep` the pattern; `apply_patch` the path,
or `N files, first <path>`; `cron` the action and the name or job id (`add daily-standup`);
`exec_session` `input to <id>`, `terminate <id>` or `output of <id>`, and never
the input; `list_exec_sessions` nothing. The engine computes it when the call
starts and keeps it with the call's intent, so a call cut by a stop is reported
with what it was doing. A call that never started has no intent and no target:
a denied call, a call to a tool that is not offered, one whose arguments did not
fit. The key is then absent, as it is for a tool with nothing to name.

`spent_usd` on `message.assistant`, `task.progress`, `task.completed`,
`task.failed` and `memory.updated` is the model spend of the session the event belongs to, in USD,
read from the same ledger the cost cap uses (section 8.2) in the transaction
that stores the event, to the hundred-millionth of a USD. On a task's events it
is the spend of the task so far (it only grows, and survives a restart, an
approval and a resume); on the chat's `message.assistant` it is what the chat
spent since its last answer, because the answer takes the chat's spend with it
(a chat that parked a call for approval reports the spend before and after the
approval in the one answer it gives); on `memory.updated` it is what the memory
passes spent since the last one, a pass that failed included (section 8.6). The
engine always sends it (0 when nothing was spent); the schema makes it optional
so events logged before it existed stay valid. The host reads it as the
guest's report: it is never used to enforce anything (the cap is the guest's).

`mcp.server.added {arguments}` is a call of `add_mcp_server` that ran (section 8.3): the Dot adds an MCP server to its
own config, and `arguments` are the call's, as the model made it. The config is the host's, so the host decides
again: it writes the server only when the entry passes the config's own schema under a name not yet declared, and
the Dot's config allows `mcp.servers.add` or the person approved a call of exactly these arguments (an approval of the
Dot with that tool, its arguments equal as JSON values, keys in any order). That approval is used up in the same
transaction (`approvals.used_at`), so one approval adds one server once: a server the person removes is not brought
back by the call that added it. It writes the server in the transaction that stores the event, with `dot.updated
{name, mcp_server_added, approval_id?}`, and pushes the config; otherwise it logs `mcp.server.refused {name, reason}`
(a call refused for its entry or its name keeps its approval). The server's own permission is left to its default, ask.

`memory.updated {conversations, changed}` ends a memory pass (section 8.6): the
Dot had been quiet for a while, and the summary model rewrote its `MEMORY.md`
from what was said since the last pass. `conversations` is how many
conversation files it took messages from, `changed` whether `MEMORY.md` is different. A pass
that found nothing new sends nothing, and one that failed sends nothing either:
its spend goes with the next `memory.updated`.

`automation.next_run {next_run_at_ms}` is when the earliest enabled automation of
the Dot is next due, in milliseconds since the epoch, or `null` when none is (no
job, every job paused, or only one-time jobs that already ran). The engine sends
it each time that value changes, so the last one the host has is the true one: when
the cron service arms its timer, which it does after every change of the jobs (the
`cron` tool) and after every tick, the engine compares
the value with the one it last reported, kept in its database in the transaction
that writes the event, and writes the event only when they differ. A restart
therefore does not say it again, a computer that never had a job has said nothing
(the host takes that as `null`), and a time already past is reported as it is: it
is a run the engine has not made yet, which it makes when it starts (section 8.8).
The host keeps the value in `computers.next_automation_at` and uses it to wake a
stopped computer shortly before the run and to not put one to sleep that is about
to need it (section 9.5).

The `arguments` of `approval.requested` are what the person decides on, and
they leave the guest: a tool argument that carries a secret is redacted there
by the engine, at the point where the event is built, and nowhere after it: the
host, the web UI and a chat prompt (section 9.8) show the arguments as the event
has them. The engine masks the proxy of `browser_identity_create` (shown as `***`: a
proxy is a secret, and neither its user, its password nor its host is shown), and
removes the user and password of the URL of
`browser_navigate` (the query and the fragment stay: see section 6). The pending
call in the Dot's database keeps the full arguments, so the approved call is made
as asked.

An outbound event is handed to the event stream only after the transaction
that wrote it to the outbox committed: one written inside a transaction that
rolls back is never streamed, so its `seq` cannot reach the host and then be
reused for another event.

The control plane adds its own: `dot.created`, `dot.updated` (a saved config,
`{name}`, or a Dot that went to ERROR, `{name, status: "ERROR", error}`, which
the Activity page tells apart), `dot.deleted`,
`computer.state {state}`, `computer.started`, `computer.stopped`,
`task.created`, `task.cancelled`, `task.failed {task_id, error}` (the guest's
type: the host writes it when it gives a task up because its `task.created` could not
be delivered, section 9.2, so a client follows one type whoever ended the task), `approval.resolved {approval_id, decision,
task_id?, note?, always?}` (`task_id` is the task the approval was asked in, so
the events of a task hold the answer beside the request), and the two of a messaging
channel: `channel.status {kind, status, detail?}` (`kind` is `telegram` or
`whatsapp`; `status` is `connecting`, `connected`, `needs_relink` or `error`,
and `detail` never holds a credential), `channel.peer.paired {kind, peer_id,
label}` and `channel.changed {kind, change}` (`change` is `paused`, `resumed`
or `removed`: what the person did, which no status says, so that every view of
the channel follows it). A channel lives in the control plane only: the Dot never sees one, so
no inbound or outbound type names it.

The last of them is `guest.event.refused {seq, type, problem}`. The host parses
every message of the guest's event stream with the schemas of `packages/shared`
and drops one it refuses (it is not an event the host knows, so it is not
stored as one), because one malformed message must not stall the stream. The
drop is not silent: the host writes this event, in order with the guest's, with
the `seq` and `type` the message carried when it was JSON that carried them
(null otherwise) and the problem in words (at most 300 characters, never a
credential: a schema message names a path and a rule), and moves the cursor
past the `seq` in the same transaction, so a reconnect does not record it
again. The Activity page shows it as "The computer sent an event that was not
read". The two sides cannot drift unseen: `tests/dots/test_wire_shapes.py`
writes one event of every type the engine writes, with each set of optional
keys, into `wire_shapes.json`, and `apps/scheduler/test/engine-shapes.test.ts`
requires that each parses back unchanged (the schemas strip an unknown key);
`apps/scheduler/test/host-shapes.test.ts` writes the events and the config the
host sends into `host_wire_shapes.json`, which the engine's own parsers must
accept with every key.

The message a person sends is logged as a `user.message` host event
`{message_id, text, origin?}`. `origin` is `{channel, binding_id, chat_id,
external_id}` for a message that came through a channel and is absent for the
web, the CLI and the SDK. The event log is the one place that says where a
message came from, and a reply is routed back by it; the guest receives the
event with `{text}` only. Only code inside the control plane can set an origin
(`Scheduler.sendMessage`): `POST /api/dots/:id/messages` takes `{text}` and
ignores anything else.

## 6. Browser identities

- Where a browser exits to the internet. An identity has no proxy of its own
  unless the person gave it one: that is the default everywhere (the API, the
  SDK, the CLI and the engine accept a create with a name only, and nothing
  asks for or fills in a proxy). The browser then inherits the egress of the
  Dot's VM: through the VM proxy when the Dot has one, directly otherwise. The
  VM proxy is a per-Dot secret (`vm_proxy` in `secrets`, set by
  `PUT /api/dots/:id/proxy` or `invisible-dots secret proxy`), a
  `socks5://[user:password@]host:port` URL that goes into the seed's root-only
  `config.json` at every start; the runtime's `install.sh` then routes the whole
  VM through `hev-socks5-tunnel` (TCP, UDP and DNS over `tun0`) and an
  nftables table drops every other way out, so nothing leaves when the proxy is
  down. Nothing tracks or compares the exit. Its time zone, locale and
  geography follow the exit the browser actually uses, which the browser layer
  learns from the address-echo services at each launch. A per-identity proxy
  stays an explicit option for one identity. It is one optional string, stored as
  a secret and handed to `invisible-playwright-mcp` unchanged, in the setting the
  library reads (`STEALTHFOX_PROXY`): the library owns what a proxy is (its
  schemes, its host and port, the errors it raises for one it cannot use, at the
  launch), and invisible_dots has no rule, parser or display form of its own for
  it. What is invisible_dots's own is that the secret is shown nowhere (below);
  when both a VM proxy and an identity proxy are set, the
  identity's proxy is reached through the VM's tunnel, so the exit is the
  identity proxy's. An identity proxy is not the way to give a browser a
  location: a Dot that should appear somewhere gets that from its VM's egress.
- An identity is a row of the engine's `dots_browser_identities` table (id,
  name, proxy, created, last used) and a directory under
  `/home/dot/browsers/<identity_id>/`. Its id is a slug of its name plus a short
  random suffix. The guest's database is the only record of which identities
  exist; the host never mirrors the list, it asks the guest. Whether an
  identity is open is never stored: it is derived from the live browser
  sessions of the running engine, so a file never claims an open browser for a
  process that is gone. An identity's proxy, when it has one, is stored as given, password included, in
  the engine's database (`dotengine`'s state directory, 0700, which the model
  cannot read); nothing of it is shown to a model, a person, an event or a log:
  an identity says only that it has a proxy (`hasProxy`). The browser's own process is the one exception, by
  decision: it runs as `dot` with the proxy in its environment, so the `dot`
  user, and the model through `exec`, can read the proxy of an identity whose
  browser is open from that process's `/proc/<pid>/environ`. The server's
  session file is the second copy on disk, again by the server's own design
  (it saves who its browser is, the proxy included, in
  `/var/lib/invisible-dots/mcp/<identity_id>/sessions/<identity_id>.json`, as
  `dot`, after every `browser_open`): the model's `exec` can read it, but it is
  outside `/home/dot`, so the host's file routes (the API, the SDK, the Files
  tab) can never serve it; deleting the identity removes it. That the server
  keeps the whole proxy at rest is a defect of the library (its `Work.remember()` saves it; its own
  identity file keeps only a digest), which this repository does not patch: the fix belongs upstream,
  and the browser smoke checks that no file of `/home/dot` (the profile, a cache, a log) holds the
  password and that the port refuses the session file. The proxy is never
  on a command line, which every user of the VM can read: the engine tells the
  relay the variable's name (`--env-from`) and the relay reads the value from
  its own environment, which only `dotengine` can read.
- The fingerprint seed of an identity is stored by the browser layer in the
  profile itself (`profile/.stealth-identity.json`). invisible_dots never stores
  or passes a seed: the first launch of a profile picks one and every later
  launch of the same profile gets the same one back.
- Launching an identity starts one `invisible-playwright-mcp` process over
  stdio. Its environment is the allowlist of section 4.1 plus, through the MCP
  server's documented settings: its home (`INVISIBLE_MCP_HOME=/var/lib/invisible-dots/mcp/<identity_id>`)
  and session id (`INVISIBLE_MCP_SESSION_ID=<identity_id>`), the identity's
  profile directory (`<identity>/profile`), headed mode, `DISPLAY=:0`, and the
  identity's proxy only when it has one (otherwise no proxy variable is set at
  all), and one setting of the libraries it
  uses: `INVISIBLE_CORE_AUTOFIX=off`, which stops `invisible_core` from
  reinstalling itself from the package index at a launch when its version
  drifts, so a drift fails loudly instead of installing files outside the
  hashed lock. The names of the browser layer's own
  settings are written in one place, `packages/shared/src/protocol.ts`
  (`ENV.PROFILE_DIR`, `ENV.HEADLESS`, `ENV.PROXY`,
  `ENV.CORE_AUTOFIX`). The browser therefore runs
  on the Dot's desktop and shows up in its screenshots.
- A launch also connects out, which no setting here turns off: to the
  address-echo services of the library (`api.ipify.org`, `icanhazip.com`,
  `checkip.amazonaws.com`, from the VM's egress, or through the identity's proxy
  when it has one) to learn the exit address for the timezone and locale; to the library's launch counter
  (a download of a file of `feder-cr/firefox_antidetect_patch`'s releases,
  switched off only by a preference the MCP server gives no way to pass); and
  it probes the exit's capabilities and caches the answer in
  `/tmp/exit_capability.json`; and it keeps its GeoIP database current from
  its GitHub release.
- The model never calls `browser_open`: the browser manager opens and closes
  each identity's browser, and starts its server with
  `INVISIBLE_MCP_HOST_MANAGED=1`, under which the server serves its `main`
  browser alone (no tool takes `browser`) and its instructions are the page
  rules, without `browser_open` and the `support` browser. The model's page
  tools are that server's own (section 8.3), each with the `identity_id` that
  picks the open identity's server. The manager opens the browser with
  no `profile`, `proxy` or `seed` argument, so for a first launch the
  environment above is the only source of those values. A later `browser_open`
  with no argument is a reopen, and the library then takes who the browser is
  from its session file (`/var/lib/invisible-dots/mcp/<identity_id>/sessions/<id>.json`: seed, proxy and
  profile directory, written at the first open) and does not read
  `STEALTHFOX_PROXY` or `STEALTHFOX_PROFILE_DIR` again: the file wins. An
  identity's proxy never changes after it is created (there is no route that
  edits it), so the two agree, but a proxy edited in the engine's database would
  not reach a browser whose session file already exists.
- At most 3 identities are open at once (roughly 0.8 GB of memory each).
  Launching one more closes the least recently used. At most 20 exist. Both are
  the engine's own (`DEFAULT_MAX_OPEN` and `DEFAULT_MAX_IDENTITIES` in
  `nanobot/dots/main.py`), not settings: the Dot manages its identities itself.
- Launching is explicit. A browser action on an identity that is not open does
  not launch it: it fails with "identity <id> is not open; call
  browser_identity_launch first". Each permission therefore decides only its own
  action, and `browser.identity.launch: deny` cannot be got round by navigating.
  The first launch of a machine can take minutes while the engine downloads the
  browser; the launch asks again (2 s doubling to 30 s) for up to 15 minutes.
  A launch waits only for its own browser: a config change, a close, a delete or
  a create of another identity does not wait for it, and neither does the
  answer of `PUT /config`, which closes the browsers beyond a lower `max_open`
  (least recently used first) after it has answered. A close, a delete or a
  launch of an identity that is still opening waits for that launch to finish.
- Closing a session asks the browser to close first (up to 30 s, so Firefox
  flushes its profile), then stops the process; the profile stays on disk.
  Deleting an identity closes it and removes its directory. The engine closes
  every open browser on prepare-sleep and on SIGTERM.
- The only browser of a Dot is `invisible-playwright-mcp`: no tool of the
  engine browses any other way, and the engine and the image carry no other
  browser, browser library, or web fetch or search tool.
- Screenshots. `browser_take_screenshot` (and `browser_click_at`, which answers
  with the page after the click) and `computer_screenshot` return an image
  the model looks at. The transcript, the outbox and the events never hold its
  bytes: the tool's stored result is its text and `[screenshot, 1280x720, not
  stored]`, and the engine adds the newest three images of a turn to each model
  request in one user message after the last tool message. A later turn
  replays the placeholder; the model takes another screenshot when it wants one.
- Secrets in the arguments. The proxy has no place in anything shown:
  `approval.requested` carries `browser_identity_create`'s proxy as `***` and `browser_navigate`'s URL without its user and password
  (the parked call keeps the real ones, so the approved call runs as asked), and
  no `target` of `tool.called` holds typed text. The query of a URL is not
  masked (owner decision): a
  query string is how a model that was talked into it sends data out, so it is
  what the approver has to see, as with the command of `exec`; a person who does
  not want it in a chat turns `show_arguments` off. The `text` of
  `browser_type` and the `value` of `browser_select_option` stay in the arguments
  of an approval when `browser.act` is set to `ask`: whether a field is a
  password cannot be known from the arguments, so a person approving typing sees
  what is typed. That includes a chat that carries approvals (section 9.8, not
  end-to-end encrypted): a person who does not want typed text there turns
  `show_arguments` off for the channel.

## 7. Dot configuration

YAML in, validated by one schema in `packages/shared` (zod):

```yaml
name: fare-watch                       # [a-z0-9-], 1..40
instructions: >                        # optional: how it should work, in its system prompt
  Write findings to ~/workspace/fares.csv.
model:
  provider: openrouter                 # the only accepted value
  id: z-ai/glm-5.3-flash               # any OpenRouter model id
models:                                # optional per-role models, OpenRouter ids; the roles: summary
  summary: openai/gpt-5-mini         # writes the summary when the thread outgrows the model's window (section 8.6)
computer:
  cpu: 2                               # 1..16
  memory: 4gb                          # 2gb..64gb
  disk: 40gb                           # 20gb..1024gb
  idle_timeout: 15m                    # sleep after this long with nothing to do; 0 = never
permissions:                           # allow | ask | deny, keyed by permission name
  computer.exec: allow
  browser.identity.delete: ask
limits:
  max_steps_per_task: 60               # model turns before a task is failed
  max_cost_per_task_usd: 1.00          # USD of model spend of a task or a chat turn, 0.01..100; the last request may exceed it (section 8.2)
mcp_servers:                           # optional: MCP servers whose tools the Dot may use, by name
  time:                                # [a-z0-9-], 1..32, starting with a letter or a digit
    command: uvx                       # run on the Dot's computer, as dot, in its home
    args: [mcp-server-time]
    env: {LOG_LEVEL: warning}          # optional: environment written here
    secrets: [TIME_API_KEY]            # optional: environment variables whose values are secrets (section 9.6)
    timeout_s: 120                     # optional: the longest one call may take, 1..600
    startup_timeout_s: 60              # optional: the longest it may take to start, 1..600
  search:
    url: https://search.example/mcp    # streamable HTTP, or SSE for a URL ending in /sse
    headers: {X-Client: dots}          # optional
    secrets: [Authorization]           # optional: headers whose values are secrets
```

A Dot has no goal: what it is for is what its person asks of it, in the chat, in a task or in its
instructions. Nor does it have browser settings: it manages its identities itself, within the
engine's limits (section 6). Nor does it set any token limit: every request uses its model's own
context window and longest answer, as OpenRouter publishes them (section 8.5). A config saved with
any of these before (migrations `0010_dot_has_no_goal.sql`, `0011_dot_has_no_browser_settings.sql`
and `0012_dot_has_no_context_tokens.sql` take them out) is refused as an unknown key.

The ranges and defaults of the numbers in that file (`computer.cpu`, `memory`,
`disk`, the default `idle_timeout`, `limits.max_cost_per_task_usd` and
`limits.max_steps_per_task`) are `CONFIG_BOUNDS` in
`packages/shared`. The schema takes its numbers from it and
so does the web client's form, so a slider can never offer what the API refuses.

`models` has one role, `summary`, and no other: the roles are what the engine
asks a model for, and a role it never asks for would be a setting that does
nothing, so a config that names another is refused as `unknown model role
"fast" (the roles are: summary)` (`MODEL_ROLES` in `packages/shared`, copied
into the guest's `protocol.py`). The role's value is an OpenRouter model id
like `model.id`; without it the Dot's own model writes the summary. A config
push that changes it applies from the next turn.

The permission names are the ones of `PERMISSIONS` in
`packages/shared/src/tools.ts`: those the tools of section 8.3 exercise, and no
others (a Dot has no tool for web reading or search, sub-agents or messaging,
and its notes are files written with `files.write`). A config that names any
other permission is refused as unknown. `PERMISSION_INFO` in the same file gives
each one the label, description and risk (`low`, `medium`, `high`) a person is
shown when they decide on it.

Defaults for permissions not listed: everything under `computer.*`,
`files.*`, `browser.*` and `memory.*` is `allow`, except
`browser.identity.delete`, which is `ask`; `automations` is `ask`. Any
permission name the registry does not know is `deny`.

`DotRuntimeConfig` (what `PUT /config` sends to the guest) is the same object
minus `computer`, with `permissions` resolved by the host: one decision for
every permission the registry knows, defaults applied. The guest applies the
map as it is and denies a permission missing from it, so the defaults live in
one place (`resolvePermission` in `packages/shared`).

`mcp_servers` are the MCP servers the Dot may use, declared the way
Claude Code (`.mcp.json`), Codex (`[mcp_servers]`) and nanobot declare them: a
`command` with its `args` and `env`, or a `url` with its `headers`. The person
declares one in the settings or the YAML, and the Dot can add one itself, as
NanoClaw's agents can (`add_mcp_server`, section 8.3), once it has installed the
program the server needs (section 4.2): its permission, `mcp.servers.add`, asks
by default, the person reads the whole entry on the approval, and the host checks
that approval again before it writes the server (section 5.4). A stdio server
runs as `dot`, with what `computer.exec` already gives the Dot, so adding one
gives the Dot no new power over its computer: what it adds are tools, and each
asks under the server's own permission until the person allows it. Only the
person changes or removes a server. A server's name is the prefix of its tools
as the model sees them, `mcp_<server>_<tool>` (nanobot's naming), so it holds no
`_` and the engine reads the server back from a tool's name. `secrets` names the
environment variables (of a command) or headers (of a URL) whose values are
secrets: they are set apart from the config, write-only (section 9.6), never in
it, so the config can be shown, exported and edited as YAML. A secret named twice,
or named as a value the entry also writes, is refused.

Each declared server has a permission, `mcp.<server>`, that covers all of its
tools: what a server's tool does is that server's to say, which the host cannot
know, so a server is one decision, as it is in Claude Code's permission rules
(`mcp__<server>`), and it asks by default. Its risk is `high`, as running
commands is. A permission of a server the config does not declare is refused,
and `resolvePermission` denies it. `MCP_SERVER_NAME_PATTERN` and
`MCP_TIMEOUT_BOUNDS` and `MCP_STARTUP_TIMEOUT_BOUNDS` (Codex's `tool_timeout_sec` and
`startup_timeout_sec`) are in `packages/shared`; the guest's `protocol.py` keeps a
copy of the name rule. The servers are listed by name everywhere (the status,
the prompt, the settings): the database keeps a config as `jsonb`, which does
not keep the order of an object's keys.

## 8. Agent runtime

Sections 8.1 to 8.7 are the contract of a Dot's runtime. Section 8.8 is the
engine that keeps it (`invisible_engine_dots/`), how it keeps it, and what it
does not do yet.

### 8.1 States

`IDLE -> THINKING -> EXECUTING -> (THINKING | WAITING_APPROVAL) -> DONE -> IDLE`

`DONE` follows a failed unit as well as a completed one. `THINKING` is a model
request in flight; `EXECUTING` is a tool running. Every transition is an
`agent.state` event. The protocol also names `PLANNING` (the model's answer
being turned into tool calls); the engine has no such step and never reports it.

### 8.2 Work

The runtime is event driven. Work arrives as `user.message` (a chat turn in
the Dot's single persistent conversation), as `task.created` (queued locally,
run one at a time in priority order, then creation order) or as the firing of
one of the Dot's own automations (section 8.8, answered in the chat). A task
ends when the model answers without tool calls (`task.completed`, the answer is
the summary), or when an approval is rejected and the model gives up. It fails
(`task.failed`, with a reason the owner can read) when it exceeds
`max_steps_per_task`; when a model request fails for good after the retries of
section 8.5, or the run ends without an answer; or after being interrupted
three times (section 8.7). A chat turn has the same limits; a failed chat turn
answers "I could not answer: ...".

`limits.max_cost_per_task_usd` caps the model spend of a task, or of the chat
between one answer and the next. The events that end work carry the spend (section 5.4). The cost of a request is what OpenRouter reports for it in the usage
of the last chunk of its response (`usage.cost`, USD; for a BYOK request the
upstream cost it reports beside it is added, which may count more than was
charged and never less). The engine adds the cost of every response of a turn,
the requests of the turn, their retries and the summary requests alike, to the
spend of its session in the Dot's database as each arrives, and checks the
spend before every model request: when it has reached the cap the turn stops
without asking again, and fails with `stopped: the task reached
limits.max_cost_per_task_usd (spent 1.0423 USD of 1.00)` (`task.failed`'s
`error`; "the turn" instead of "the task" for the chat, which then answers "I
could not answer: ..."). A request cannot be priced before it is answered, so
the cap may be exceeded by the last request, and an answer that crosses it is
delivered and the task completes: the cap only stops the work from going on. A
request that failed has no cost and counts for nothing: OpenRouter reports the cost in the last chunk of a
stream, so a stream that stalled or was cut after tokens were streamed (and billed) has no figure to count, and
neither has an attempt the retries of section 8.5 went past (4 attempts a request). The cap can therefore be
exceeded by those partial streams, each at most the cost of one full response. A task's spend is kept
across a restart, an approval and a resume (a task that was cut by a crash goes
on from what it had spent); the chat's spend starts again with each answer it gives, so an approval or a
restart does not reset it.
A lowered cap applies from the next turn, like the step limit. A response that
reports no cost fails the turn, `stopped: OpenRouter reported
no cost for a request, so limits.max_cost_per_task_usd cannot be enforced`,
before anything is done on that response: its tool calls are not written and do
not run, or its answer is not delivered and the task does not complete (a
summary request is not acted on this way, so the failure comes at the next
check). The note is a column
of the same ledger row as the money (`dots_spend.unpriced`), so a restart does
not forget it: the cap never runs blind. A request abandoned by a sleep may have cost something
that was never reported; that gap is at most one request a sleep.

### 8.3 Tools

Function names use `_` because OpenAI-style function names cannot contain
dots. Each tool declares the permission it needs, in one table
(`nanobot/dots/permissions.py`) that offers the model its tools, decides every
call and reports the permission of each `tool.called`. A tool that is not in
the table is neither offered nor allowed. Every permission named below is one
of `PERMISSIONS` (section 7); a tool cannot take a permission the host's config
does not know.

| tool | permission | what it does |
|---|---|---|
| `exec` | `computer.exec` | runs a command through `bash -lc` in a working directory with a timeout (60 s by default, 600 s at most); with `yield_time_ms` it returns while the command still runs, which makes it a background job; with `tty: true` it runs on a pseudo-terminal, as a background job that `exec_session` drives (no new tool, the same permission) |
| `exec_session` | `computer.exec` | sends input to, waits for, reads or terminates a background job (a terminal's output is the text of its screen, section 8.8) |
| `list_exec_sessions` | `computer.exec` | lists the background jobs |
| `read_file` | `files.read` | reads a text file, by line window; reports a binary file as binary |
| `list_dir` | `files.read` | lists a directory, optionally recursively |
| `find_files` | `files.read` | finds files by path terms, glob or type |
| `grep` | `files.read` | searches file contents by regular expression |
| `write_file` | `files.write` | writes a whole file |
| `edit_file` | `files.write` | replaces text in a file |
| `apply_patch` | `files.write` | applies a list of structured edits (replace or add) to files, with a dry run |
| `cron` | `automations` | adds, lists and removes the Dot's own scheduled automations |
| `computer_screenshot` | `computer.screenshot` | takes a screenshot of the Dot's whole desktop and shows it to the model (no arguments) |
| `browser_identity_list` | `browser.identity.list` | lists the browser identities with their status (open or available), whether each has a proxy of its own (and nothing of the proxy), and the two limits |
| `browser_identity_create` | `browser.identity.create` | makes an identity, closed: `name`, `proxy?` (an explicit option that the model leaves out unless the person gave one) |
| `browser_identity_delete` | `browser.identity.delete` | closes an identity and deletes it with its profile: `identity_id` |
| `browser_identity_launch` | `browser.identity.launch` | opens the browser of an identity, closing the least recently used one at `max_open`: `identity_id` |
| `browser_identity_close` | `browser.identity.close` | closes the browser of an identity, keeping its profile: `identity_id` |
| `browser_navigate` | `browser.navigate` | the server's; the engine refuses a URL that is not `http://` or `https://` before it reaches the server (`file:`, `about:`, `view-source:`, `data:` and `javascript:`), so the permission to navigate is not a permission to read files |
| `browser_snapshot` | `browser.read` | the server's: the page's interactive elements with their selectors and coordinates |
| `browser_read_text` | `browser.read` | the server's: the text of the page or of the element a selector names |
| `browser_read_html` | `browser.read` | the server's: the page's HTML, cleaned |
| `browser_take_screenshot` | `browser.read` | the server's: a screenshot of the page, shown to the model |
| `browser_evaluate` | `browser.read` | the server's: reads with a script, and refuses one that acts on the page |
| `browser_click` | `browser.act` | the server's: clicks the element a selector names |
| `browser_click_at` | `browser.act` | the server's: clicks a point and answers with the page after it |
| `browser_type` | `browser.act` | the server's: fills a field key by key, a long text going on in the background |
| `browser_press_key` | `browser.act` | the server's: presses a key or a shortcut |
| `browser_select_option` | `browser.act` | the server's: chooses an option by its label or its value |
| `browser_upload_files` | `browser.act` | the server's: attaches files of the dot user to a file field |
| `add_mcp_server` | `mcp.servers.add` | adds an MCP server to the Dot's own config: `name`, a `command` with `args` and `env` or a `url` with `headers`, the names of its `secrets`, and a `reason` for the person; the host checks the permission again and writes it (section 7) |

The page tools are `invisible-playwright-mcp`'s, the only browser of a Dot,
offered as an MCP host offers a server's tools: the server's name, description
and input schema, plus the `identity_id` of the open identity whose server the
call goes to. The engine reads them, with the server's instructions, from the
server its Dot has, when it starts: `nanobot/dots/server_capture.py`, run as dot
by the python of the installed `invisible-playwright-mcp`, starts the server as
the engine starts it and prints what it answers (`nanobot/dots/server_interface.py`).
A Dot keeps the golden image it was made from and takes every new runtime disk,
so the engine never assumes a version of the server: it offers the tools the
server it finds serves. A page tool that server does not serve is not offered
(`GET /tools` says so), and a Dot whose server cannot be read offers no page
tool, and a launch says why. Which of the server's tools the model is
offered is the permission table's: `browser_open`, `browser_close`,
`browser_list` and `browser_status` are the manager's (the identity tools), and
`browser_watch` is the UI's frame. The server's instructions go into the
system prompt whenever a page tool is offered, as an MCP host carries a
server's instructions. A browser action on an identity that is not open does
not launch it, it says so (section 6). An image the server answers with is
shown to the model and not stored (section 6).

The tools of the MCP servers the person declares (`mcp_servers`, section 7)
are not rows of the table: which they are is each server's to say, at run time.
`nanobot/dots/mcp_servers.py` keeps one nanobot `MCPProvider` per declared
server, on a registry of its own, as the browser has one per identity, so
spawning, `initialize`, `tools/list` and the per-call timeout (`timeout_s`)
are the client's. The client never reconnects a server and never repeats a
call: a server whose process exited or whose connection dropped is reported
(`on_terminated`), and the call that found out fails with its error, since the
server may have run it already. What is the Dot's:

- where it runs. A `command` is started through `dot-agentd relay`, as the
  user `dot`, in its home, like every program of the model: it reads and writes
  what the Dot's commands can, and nothing of the engine's. Its `env` is passed
  with `--env`, its secrets with `--env-from` (their names only, the values in
  the relay's own environment), so no secret is on a command line. A `url` is
  reached from the engine, its secrets as headers.
- when. A server is started when it is declared, and again when a config or a
  secret changes its entry (that server only). The next turn waits for the
  servers being started, each for at most its `startup_timeout_s` (60 s by
  default: a first start through `uvx` or `npx` downloads the server). One that
  failed (its program is not installed yet, it exited) is started again when the
  next turn starts, so a server whose program the Dot installs works from the
  next message. One that did not start in time, or whose secret is not set, is
  not started again until its entry or its secrets change, so it never holds up
  every turn.
- why it is not connected. The client says why a connection failed, and a
  command's standard error is drained into a pipe of the engine, of which the
  last 2000 characters are kept: the error a person and the model read is what
  the server wrote (`npx: not found`, `the API key is missing`), with the
  server's secrets masked.
- what the model gets. Each tool of a connected server, under the client's name
  `mcp_<server>_<tool>`, is offered while the permission `mcp.<server>` is
  `allow` or `ask`, and the gate decides each call by it (section 8.4). The
  system prompt has a section for those servers: each one's instructions (what
  it said at `initialize`, cut at 2048 characters as Claude Code cuts them), or
  why it is not connected and that it is started again at the next turn. An
  image a tool answers with is shown to the model as the browser's are. A call
  shows no target in `tool.called`, and an approval shows all its arguments.

`GET /tools` lists those tools after the table's, each under its server's
permission, and every declared server with its state: `connecting`,
`connected` (with how many tools) or `failed` (with why).

The tool calls of one response run one at a time, in the order the model
gave them. Only the response's `tool_calls` count: a call written in the
assistant's text runs nothing. The registry validates a call's arguments
before the policy sees it: an unknown tool or invalid arguments never reach
the gate and never run, and the model gets the error. A result comes back
whole: no tool has a fixed cap. A request that outgrows the model's window is
compacted first (old results cleared, then the history summarized, section
8.5); only if it still does not fit are the results of its latest round cut,
to what the window leaves (`ContextGovernor.fit_latest_round`), and the cut says
how many characters came through of how many and how to ask for less. A result
is stored cut only beyond what no compaction could make room for: the window
less the system prompt and the tool definitions.

### 8.4 Policy

Every tool call goes through the policy gate before it runs: a function of the
current config, and the only place that denies a tool the config does not
offer. `allow` runs it, `deny` returns an error result to the model, `ask`
emits `approval.requested`, moves to `WAITING_APPROVAL` and persists the
pending call, with its full arguments, in the Dot's database, keyed by the
call's id. A call that needs approval stops the round: later calls of the same
response are not run either, and the turn ends. `approval.received` is
recorded when it is accepted. With `approve` the model is told, in a turn of
its own, that the call was approved and has not run; it makes the same call
again and the gate lets that one call through, once. With `reject` the model
is told the call did not run, with the note if there is one. A decision is
recorded once: a second one for the same approval is ignored. An approved call
runs at most once. Section 8.8 says how the gate does this.

### 8.5 OpenRouter

`POST https://openrouter.ai/api/v1/chat/completions` with
`HTTP-Referer: https://github.com/feder-cr/invisible_dots` and `X-Title: invisible_dots`
(sent only when the base URL's host is `openrouter.ai`, so a stand-in used by
tests never receives them), the key from memory (section 4.3). Tool calling in
the OpenAI format, `tool_choice: "auto"`, every request streamed (with
`stream_options.include_usage`, so the final chunk carries the usage and the
cost, section 8.2).

Every request uses the whole of what its model can do. The engine reads the
model's limits at the start of every turn from the providers OpenRouter lists
for it (`GET /models/{model}/endpoints`), not once: an engine runs for weeks and
OpenRouter changes a model's providers meanwhile. Of the providers serving it,
the widest window and the longest answer at that window are the model's, and
the model's requests go only to the providers of that window (`provider.only`,
by the slug OpenRouter lists for each): OpenRouter routes a request by the
answer it asks for but not by the prompt it carries, so one sized for the
widest window could otherwise land on a narrower provider and fail there. This
gives up the narrower providers as fallbacks; when none of the widest can
serve, OpenRouter refuses the request ("No allowed providers are available")
and the turn fails with those words. A model OpenRouter does not know fails the
turn in words; a router, which lists no provider, gets no limits and no route. Each request
sends the longest answer as `max_tokens`, or what the window leaves after the
prompt when that is less (OpenRouter refuses more, and without a `max_tokens`
each provider applies a default of its own), so no answer is cut shorter than
the model allows. A response cut there all the same (`finish_reason:
"length"`) has none of its tool calls executed: what it said is stored without
them and the model is asked to go on, a bounded number of times; a response cut
before any text (the budget went to a call that never finished) is told that
nothing ran and to do the work in smaller steps. Retries with exponential backoff on 429 and 5xx (at most 4
attempts, honouring `Retry-After`). A tool result is cut only where the
model's window ends (section 8.3), with a marker that says how much came
through.

### 8.6 Memory

- Working memory: the thread is append-only in the Dot's database; what is
  sent is bounded only by the model's own context window (section 8.5). Before
  every model request the runner measures the request (the system prompt, the
  tool definitions and the messages; the provider's reported usage when it
  matches) against that window less the room kept for the answer (20000
  tokens, or the model's longest answer when shorter, opencode's rule), and
  compacts it when it does not fit, in two steps:
  1. old tool results are cleared: walking back from the newest, the first
     40000 tokens of results stay, and the older ones become a short note
     saying the tool can be called again, when that frees 20000 tokens or more.
     The calls, the reasoning and every message stay as they are. This needs no
     model call; on SWE-bench it costs half as much as a summary for the same
     solve rate (JetBrains, "The Complexity Trap", arXiv 2508.21433);
  2. only when the request still does not fit, the thread is replaced by a
     summary its model writes: a handoff for the model that resumes the work
     (Codex's framing, under the headings of OpenHands' summarizing prompt
     plus the approvals and files of the Dot), after which the person's latest
     messages are kept as they wrote them, newest first up to 20000 tokens
     (Codex's rule). When the thread is too long for the summary model, its
     oldest messages go first, each with the results of its calls; when the
     model cannot summarize at all, the messages themselves, up to half of its
     budget, are the summary.
  The summary is stored with the session, at the boundary it covers, when the
  turn ends, and the next request is the system prompt, the summary and the
  thread after it. `models.summary` (section 7) names another model for the
  summary request. That request goes through the same metered provider, so its
  real cost counts toward the cap (section 8.2); it works within that model's
  own window; and it carries no tool definitions, because a model other than
  the turn's may not accept them (the turn's own model keeps sending them so
  that its prompt cache is reused). `THIRD_PARTY_NOTICES.md` names the three
  projects this takes from.
- Past conversations: the transcripts live in `engine.sqlite`, which the
  model's commands cannot read, and a long chat reaches the model only as a
  summary of its older part. So after every turn the engine also writes what
  the chat and the task said to `/home/dot/conversations` (`conversations.py`):
  `chat/<day>.md`, one file a day of the chat, and `tasks/<day>-<task id>.md`,
  one a task, each message under a heading with its time, each call a line (not
  what it returned). A file is written whole from the transcript, and the first
  turn after an upgrade writes the chat and every task from before. The files
  are under `/home/dot`, which the host's file routes serve, so nothing a
  transcript holds that the events mask reaches them: a decision on a call is
  written as its public line (the call and its target, never the arguments the
  continuation hands the model), and every secret the engine knows is masked
  as `***` in whatever text carries it, the person's and the model's included:
  the proxies of the browser identities, gathered in `dots_kv` as they appear
  and never forgotten (a file is written again whole, after an identity may
  be gone), and the OpenRouter key, from the holder's memory only. The memory
  pass masks them in `MEMORY.md` the same way. The system
  prompt says to search there with grep when something said before matters, and
  before advice or a recommendation for the person. On LongMemEval (500
  questions over ~115K tokens of dated chats; `tests/bench/README.md`) this took
  a Dot from 7.8% to 88% of the answers; searching plain files is also what
  remembers best in the published measures (the agent-memory runs of
  LongMemEval, "Is Grep All You Need?").
- Long-term memory: notes, one file each, in `/home/dot/memory` on the Dot's
  computer, which the Dot keeps itself, as Claude Code keeps its own. One of
  them, `MEMORY.md`, is given to the Dot in every prompt, whole up to 25000
  characters (cut there, with a word to shorten it, as Claude Code does): what
  it should always know about the person, each fact with its day, and a line
  for every other note. The system prompt says where the notes are, what goes
  in MEMORY.md and in the others, that a note no longer true is changed or
  deleted, and names the 20 most recently changed. The Dot reads and searches
  them with the file tools (`read_file`, `grep`, `find_files`: `files.read`)
  and writes them with `write_file`, `edit_file` and `apply_patch`
  (`files.write`); a note is a file, and the host sees it as the `tool.called`
  of the call that wrote it, with its path as the target. A listing of the
  folder that fails (dot-agentd not answering) leaves the names out of that
  prompt and the turn goes on.
- The memory pass (`memory_update.py`): a model often does not think to write
  what it learns about the person, so once no turn has run for 5 minutes after
  a turn (or after a start), the engine takes the conversation files whose time
  is after the newest it took last, and of each only the messages it has not
  taken yet (a file is written again whole after every turn but only grows at
  its end, so a long day's chat is read once), and has the `summary` model
  rewrite MEMORY.md from them and the current MEMORY.md, in one request with no tools
  (`templates/agent/memory_update.md`: atomic facts with their day, a changed
  fact replacing the old one, nothing copied from what a web page or a command
  said). Files that do not fit one request go in several, oldest first, a long
  one cut between its messages, each request building on the MEMORY.md the
  last wrote. A pass runs beside nothing (a turn that starts does not wait for
  it); a sleep or a stop cancels it, and the next quiet spell takes it up. An
  answer that is cut, empty or unpriced writes nothing, and neither does one
  whose MEMORY.md the Dot changed while the request ran: the next pass takes
  the files again. A failed pass is tried again only after the next turn. Its
  spend has a ledger of its own, capped like a task's (`max_cost_per_task_usd`),
  and `memory.updated` (section 5.4) reports it. Measured on LongMemEval's
  questions that need what the person likes: 65% without MEMORY.md, 83% with
  it, the same as the best of the memory systems tried (Hindsight), at about a
  tenth of its cost ($0.025 a pass over 115K tokens with glm-5.3-flash, as
  the product ran it; 90.4% of 115 mixed questions); Mastra's and LangMem's methods made 80%, an agent doing the
  pass with file tools 75% at five times the cost (`tests/bench/README.md`).
- Workspace memory: `/home/dot/workspace` and `/home/dot/memory`, reached
  through the file tools.
- Skills: how the Dot does a kind of task, one folder each with a SKILL.md, the
  Agent Skills layout Claude Code and upstream nanobot read (a frontmatter whose
  `name` is the folder's and whose `description` says in one line when it applies,
  then the steps). Built-in ones ship with the engine, beside its package
  (`invisible_engine_dots/skills/`, on the runtime disk at
  `/opt/invisible-dots/engine/skills/`); the first, `invisible-playwright`, says how
  to use the browser identities: which one to use, opening and closing one,
  and when a plain download is simpler than a browser; how to drive a page
  (finding a page, the order a page cannot tell from a person, when to say a
  task is impossible) is the browser server's instructions, which the system
  prompt carries (section 8.3). The Dot writes its own under `/home/dot/skills/<name>/SKILL.md` with
  the file tools as it learns, and one of its own replaces a built-in one of the
  same name. The system prompt names every skill with its description and the path
  of its file, read again each turn (`nanobot/dots/skills.py`), and says to read the
  file before a task it covers and how to write one: only the names and the
  descriptions are in every request. A file that does not parse is left out and
  logged. `GET /skills` (section 5.3) shows the same list to the host.

### 8.7 Crash recovery

The engine can die at any point (a crash, a kill, a power cut) and systemd
starts it again. What it guarantees:

- One process owns the Dot's database (section 4.2).
- Every commit point is one transaction that includes the outbox rows
  describing it; section 8.8 lists them.
- An intent left without a result is a call the engine stopped during. When a
  unit is entered (a start, and the beginning of every turn), such a call is
  never run again: it gets the result "This call was interrupted before its
  result was recorded. It may have taken effect, and it may still be running.
  Check the current state before calling it again." (plus, for an approved
  call, that the approval was used), and `tool.called` with `interrupted: true`
  and the permission and decision of its time. A command dies with the engine
  that started it (section 5.2), so "may still be running" covers what the
  command detached; "may have taken effect" covers everything it did before it
  was killed.
- So a call runs at most once, and the model is told whenever its outcome is
  unknown. `tool.called` is written exactly once per call that ran or was
  refused (a call waiting for approval, or one that never started, reports
  nothing). `agent.state` is at-least-once.
- A unit can end between a response and the results of its calls (a failed
  write, a failure, a cancel, a stop). The transaction that ends it answers
  every call of the newest assistant message that has no result, by what the
  database holds for the call (section 8.8). A thread never keeps a call
  without its result, which the provider would refuse on every later turn.
- Stopping: `POST /prepare-sleep` and SIGTERM abandon a model request in
  flight and give a tool in flight up to 20 seconds to finish and commit its
  result, then close the open browsers: at most 4 s on SIGTERM, which leaves about
  6 of systemd's `TimeoutStopSec=30` to checkpoint the database, and up to a
  browser's own 30 s close on prepare-sleep: only the host's 60 s bounds it, and
  the 20 s of grace, the 5 s of cancel wait and the 30 s close fit inside, with 5 s
  to spare for the flush (`PREPARE_SLEEP_TIMEOUT_MS` of packages/shared, with the sum
  checked by a test of the engine). A tool cut at
  the grace keeps its intent, and the next entry of its unit reports it as
  interrupted. Measured in the engine smoke before the browsers existed, with a
  task's `sleep 70` still running at SIGTERM and the event stream connected: the
  process exited 20.4 s after the signal, 9.6 s inside the limit (the 20 s
  grace, then the checkpoint, the exec sessions and aiohttp's cleanup in
  0.4 s); with no browser open the close takes no time.
- A task that was running when the engine stopped is started again with a note
  that the previous attempt was interrupted, and fails once it has been started
  three times (`stopped: the task was interrupted 3 times`). A start the engine
  abandoned on purpose (a sleep, a stop) is given back and does not count.
- An answer the chat owes is given: a `user.message` whose text the transcript
  holds and that no answer has covered is answered by a turn of its own at the
  next start.

### 8.8 The runtime on the nanobot fork

The engine (`invisible_engine_dots/`) carries the contract of sections 5.3 and
5.4 and the runtime of this section on nanobot's tool-calling runner, in
`nanobot/dots/`. `python -I -B -m nanobot` serves the Dot; `--version`
answers and any other argument is refused. The process reads its environment
once, in `main.py`: `INVISIBLE_DOTS_AGENT_SOCKET`,
`INVISIBLE_DOTS_AGENTD_SOCKET`, `INVISIBLE_DOTS_AGENTD_BIN`,
`INVISIBLE_DOTS_WORKSPACE`, `INVISIBLE_DOTS_ENGINE_STATE`,
`INVISIBLE_DOTS_NETWORK_CHECK` (the host the network check reaches),
`INVISIBLE_DOTS_MCP_COMMAND` (the browser server's command; the unit names it by its path in dot's `~/.local/bin`),
`INVISIBLE_DOTS_MODEL_USER` (the user of the model's commands, whom the API
socket refuses), and for tests and the smoke `INVISIBLE_DOTS_OPENROUTER_URL`.
Before it serves it checks that no other engine owns the state.

- Work. One class, `TurnRunner` (`turns.py`), starts every model turn and
  drives nanobot's `AgentRunner` (`nanobot/agent/runner.py`); the `Engine`
  (`engine.py`) decides which turn runs and what its end means. The chat is the
  session `chat`; a task is the session `task:<task_id>`. Accepted
  `user.message` and automation rows wait in `dots_inbound`; when no chat turn
  runs, a chat turn starts with all of them, in the order accepted, as its
  opening messages; while it runs, rows accepted since are injected into it
  through the runner's injection callback and committed as user messages. The
  answer a chat owes (section 8.7) is one rule: when no chat turn runs, no
  accepted row waits, a row is in the transcript and no open approval holds
  the chat, a chat turn runs with no opening message. A `task.created` is
  queued in `dots_tasks` and run one at a time, priority first then arrival;
  a chat turn and a task turn may overlap. `system.event task.cancelled` ends
  the task, cancels its turn and closes its open calls; no task event follows
  `cancelled`. No work starts before the host pushed both the config and the
  key, nor while a prepare-sleep holds it (a `POST /secrets` or a new inbound
  event lifts it). One asyncio loop runs everything.
- Where the state lives. One SQLite file, `<state>/engine.sqlite`
  (`/home/dotengine/state`, 0700), opened in WAL mode with
  `synchronous=FULL` and the exclusive locking mode. It holds the Dot's tables
  (`dots_outbox`, `dots_inbound`, `dots_tasks`, `dots_tool_intents`,
  `dots_tool_decisions`, `dots_approvals`, `dots_spend`, `dots_browser_identities`, `dots_kv`) and the transcripts
  (`sessions`, `messages`): SQLite makes a transaction atomic per file only,
  and this is what lets an event commit with the transcript row it describes.
  `DotStore` (`store.py`) is the one place a write transaction begins and
  ends.
- Commit points, each one transaction with the outbox rows describing it: an
  inbound event with its effect (a queued task, a recorded decision, a
  cancel); a task's start with `task.started`; the opening of a turn (the
  calls the previous unit left open are closed, then the opening messages are
  appended); every message the runner adds, one at a time and before it goes
  on (`AgentRunner._commit` hands it to the commit callback of `TurnRunner`):
  the assistant message with its tool calls, each tool result as soon as its
  call returns, the final answer, an injected user message; a gate decision
  (a park, or a denial); a call's intent with `agent.state EXECUTING` (from
  the turn hook, just before the tool runs); the end of a failed turn; the
  agent state transitions. `DotStore.append_messages` calls
  `record_transcript_append` (`transcript_outbox.py`) in the transaction that
  stores a message: a user message that carries an inbound id marks that input
  as in the transcript; the final assistant message of the chat emits
  `message.assistant` and applies every input the transcript holds (the
  `in_reply_to` is the newest `user.message`); the final assistant message of
  a running task completes it with `task.completed`, the text as the summary;
  any other assistant message of a running task that has tool calls and text
  beside them emits `task.progress` (section 5.4);
  a tool result emits `tool.called`, its duration measured from the call's
  intent and its `target` read from it (section 5.4), which it removes. A turn that fails fails its task in its own
  transaction; a chat turn that fails answers "I could not answer: ...".
- Closing open calls (`close_open_calls`, `gate.py`), at every start, at the
  beginning of every turn and at the end of a cancelled or failed one. For
  each call of the newest assistant message that has no result, one result,
  by what the database holds: an intent (the call started) gives the
  interrupted text of section 8.7 and `tool.called` with `interrupted: true,
  ok: false, duration_ms: 0`, and the decision `ask` when it was the approved
  call; a park decision gives the approval message again and no event; a deny
  decision gives "The Dot's policy denied this call." and `tool.called` with
  `deny`; a skip decision gives the skipped message and no event; nothing
  gives "Not executed: the unit ended before this call ran." and no event.
- The model's computer. `AgentdComputer` (`computer.py`) is the one door to
  the Dot's computer, and it speaks only to dot-agentd. Every command the model
  runs goes through `ExecTool._spawn`, the one spawn of `exec` and of the
  background jobs: a local child of the engine in its own session that runs
  `dot-agentd relay -- /bin/bash -lc <command>` with `PATH` as its only
  variable (the command's environment is its login shell's, as `dot`); the
  relay lives exactly as long as the remote command, and killing it (a
  timeout, a cancel, `terminate`, the engine's death) makes dot-agentd kill
  the remote process group. A background job is an `exec` that outlived its
  `yield_time_ms`; `exec_session` and `list_exec_sessions` act on it. With
  `tty: true` (always a background job: a terminal program is interactive) the
  relay gets `--tty` and `TERM` (the engine's, else `xterm-256color`) and
  dot-agentd runs the command on an 80x24 pseudo-terminal, so what it writes is
  one stream and its input is echoed back; `close_stdin` is ^D and the
  character with code 3 is ^C. The model reads the text of the screen, not the
  byte stream: `terminal_text` (`exec_session.py`) drops escape sequences,
  turns `\r\n` into a newline, lets a lone `\r`, a backspace and erase-in-line
  overwrite, and holds back an escape sequence cut by the end of one poll until
  the next. A program that paints the whole screen (vim, htop) is not
  rendered. There is no terminal for the person: a person's keystrokes are not
  tool calls and would bypass the approval system (section 10). The file
  tools read and write through the `GET /v1/files`, `PUT /v1/files` and
  `GET /v1/files/list` routes of `agentd.sock` (relative paths resolve against
  `/home/dot/workspace`), keeping nanobot's line windows, read-before-write
  checks, fuzzy edit matching and diff summaries. `find_files` and `grep` run
  `find`, `stat` and `grep` on the computer, as `dot`, by argv with no shell,
  to find the files that can match, and read only those. Nothing of the model's
  runs as `dotengine`, and what `dot` may touch is decided by the operating
  system: the engine adds no path policy of its own.
- The config. `PUT /config` is validated (`DotRuntimeConfig`, the same checks as
  the zod schema), stored in `dots_kv` and projected in process
  (`projection.py`): the OpenRouter model id, the tools offered (those of the
  table whose permission is `allow` or `ask`), `max_steps_per_task` as the
  step limit, and the Dot's section of
  the system prompt (its name and instructions, then nanobot's tool
  contract, a short note on its computer, the memory notes, MEMORY.md, where the past conversations are,
  and the day).
  There is no config file, no installer and no sudo rule. The same config
  again changes nothing, and the same key again builds no provider
  (`provider.py`: a new provider only when the key, the model or the base URL
  changes, and a running turn keeps the provider it began with), so the host's
  pushes at every READY and `agent.started` disturb no running turn.
- `agent.state` follows the turn hook: a run starting is `THINKING`, a tool
  running `EXECUTING`, the last run ending `DONE` then `IDLE` (or
  `WAITING_APPROVAL` while an approval waits); every start of the process
  records `IDLE` again.
- After a crash (`Engine.start`). The first event is `agent.started`. Every
  call left with an intent and no result is closed as interrupted, once. An
  approval still `running` is over (its call is one of those interrupted, with
  `decision: "ask"`); a turn that was telling a session a decision (`granted`,
  `told`) is told again; the approved call still runs at most once. A task left
  running is resumed with its description and the note "[The previous attempt
  at this task was interrupted by a restart. ...]", unless an approval of its
  session is open (then the decision moves it), and fails once it has been
  started three times; a run a prepare-sleep abandoned does not count. A chat
  turn whose answer is owed runs by the rule above.
- Policy (`gate.py`). Every tool call is decided at one boundary,
  `_admit_tool_call` in `nanobot/agent/tools/execution.py`, after the call was
  validated and its arguments cast and before anything runs; the gate is a
  required argument of the runner (`AgentRunSpec.gate`), the contract it
  answers is in `nanobot/agent/tools/gate_types.py`, and the calls of a
  response run one at a time, each decided before it runs, so a park stops
  the calls after it; `ToolRegistry` has no way to run a tool, so no call
  reaches one another way. The decision
  is made from the map the host pushed (section 7), read at the moment of the
  call, so a push between two calls of one turn applies to the second: a tool
  with no permission, or a permission missing from the map, is denied, and
  with no config or no database every call is (the gate fails closed). `deny`
  returns the reason to the model as the call's result, with no hint to try
  another way; `tool.called` reports the call with `decision: "deny"` and
  `ok: false` (the decision of a call inside a turn is kept in
  `dots_tool_decisions` until its result is written). A provider's tool call id
  names a call only inside its own response (models behind OpenRouter number
  their calls from zero in every response), so the intent, the decision and the
  approval of a call are keyed by the session and the id, and an approval is made
  per ask: the same call asked again while its approval is pending (same session,
  id, tool and arguments) is the one approval, a later call that only shares the
  id is a new one.
- Tools offered. One table (`nanobot/dots/permissions.py`, section 8.3) lists
  the tools a Dot may use, the permission each exercises and how to build it;
  the registry holds exactly those, and each turn works on a view of it that
  holds the offered ones, so a denied tool is not even seen, and the gate
  decides every call by the same table. The table also says which arguments
  of a call an `approval.requested` may carry (all of them, but for the proxy
  of `browser_identity_create`).
  The browser's server, `invisible-playwright-mcp`, runs only through the
  `BrowserManager`, on registries no turn sees. The servers the person
  declares (`mcp_servers`) are `McpServers`' (`nanobot/dots/mcp_servers.py`,
  section 8.3): it registers each connected server's tools on the Dot's
  registry as `McpServerTool`s, which call the client's wrapper of the
  server's own registry at call time, and the permission table maps a tool
  named `mcp_<server>_<tool>` to `mcp.<server>` (`tool_permission`). The
  projection keeps the servers whose permission is not `deny`
  (`EngineSettings.mcp_servers`); a turn first awaits `McpServers.ready()`,
  then offers the table's tools and those servers' tools, and the prompt
  carries what each said at `initialize` or why it is not connected. The fork's
  MCP client keeps a server's instructions, says why a connection failed, and
  takes a stdio server's standard error (`UPSTREAM.md`).
- Browser identities. `BrowserManager` (`nanobot/dots/browser.py`) owns the
  identities (their rows in `dots_browser_identities`, their directories under
  `/home/dot/browsers` and their servers' homes under `/var/lib/invisible-dots/mcp`,
  made and removed as dot through the Computer) and one
  `invisible-playwright-mcp` process per open identity, started as dot through
  `dot-agentd relay` with the environment of section 6 and nanobot's MCP client
  on a registry of its own. Launch, close and delete run one at a time; calls on
  one identity run one at a time. At `max_open` a launch closes the least
  recently used identity first. A
  browser action on an identity that is not open fails with `not_open` and
  never launches it. A browser that the server reports gone while its process
  lives (Firefox crashed, its window was closed) is not reopened and the call is
  not repeated, as the library itself took out on purpose: a repeated click lands
  on the blank page of a restarted browser, and the model is never told. It is
  a crash like a process that ended (the client reports that instead of
  reconnecting, because a restarted process has lost its browser): the identity
  is closed and its server stopped, `browser.identity.closed` is emitted once and
  the call fails with `crashed`, whose message says the browser is gone and that
  `browser_identity_launch` opens it again as the same person, on a blank page
  (the model cannot call `browser_open`; the launch is its way, and the one
  decision of whether a browser starts). A frame that finds the browser gone
  closes the identity the same way. "Gone" is the library's own sentence (its
  `NOT_OPEN` and `GONE`, which `server_capture.py` reads from the installed
  package's constants) as the
  whole error of the call, not a phrase inside one: a failed click or select
  echoes text the page controls, and a page that writes the sentence closes nothing. An open is known the same way:
  `browser_open`'s answer starts with the library's `OPENED`, recorded beside the two. The manager hears of the end
  when it happens, from the client's transport, so a process that dies while idle
  is closed at once, frees its slot of `max_open`, and the next action says
  `not_open`; a file never claims an open browser for a process that is gone. What a page
  tool returns reaches the model as the server wrote it. A close calls
  `browser_close` first, so Firefox flushes its profile, then ends the process.
  Every `browser.identity.*` event commits with the row change it describes.
  The model's identity and page tools (`browser_tools.py`) and the routes of
  section 5.3 are the callers; `max_open` and `max_identities` (3 and 20) are
  set when the manager is made and nothing changes them. A page tool is the
  MCP server's tool of the same name (`SERVER_TOOLS`), called with the
  arguments the model gave it.
- Images. A tool's image is shown to the model and kept out of the stored
  transcript (`images.py`): the tool message holds its text and
  `[screenshot, WxH, not stored]`, the images of the turn go to a per-turn
  buffer that keeps the newest three, and the runner asks that buffer for the
  messages of each model request, which adds them in one user message after
  the last tool message. That message is made for the request and never stored.
  nanobot's MCP client returns the image blocks of a server only when it is
  made for them (the browser's is), and every other caller still gets text.
- Approvals. `ask` inside a turn stores the call with its full arguments in
  `dots_approvals` (`pending`), emits `approval.requested` and records the
  decision `park`, in one transaction; the model gets a result saying the call
  waits for the user and has not run, the later calls of its response are
  recorded as `skipped` (they run nothing, report nothing and say so), and the
  runner ends the turn (`stop_reason` `parked`: no further model request).
  Nothing waits in memory. A retried turn reuses the approval of the same
  tool call id and asks nothing new. A task whose run parked a call is neither
  failed nor resumed while an approval of its session is open, and
  `agent.state` ends on `WAITING_APPROVAL`; `GET /state` names the oldest
  pending approval. `approval.received` is applied in the transaction that
  accepts it (`approved` or `rejected`, with the note); a decision for an
  unknown or already decided approval is logged and ignored. The engine then
  tells the session that made the call, in a turn of its own (the chat's
  included): an approved call is to be made again with exactly its arguments
  (written as JSON with no spaces), a rejected one did not run, with the note.
  The approval is `granted` (or `told`) before that turn starts and `done`
  when it ends. The one call an `ask` lets through is the approved one made
  again in a turn of the same session: same tool, the same arguments (compared
  with keys sorted), once; it moves the approval to `running`, runs like any
  call of the turn, and its `tool.called` says `ask` and ends the approval.
  Different arguments are asked about anew.
- Automations. nanobot's `CronService` runs inside the engine, its jobs in
  `<state>/cron/jobs.json`, and the `cron` tool (permission `automations`,
  `ask` by default) adds and removes them. A firing is recorded as a durable
  inbound row, `automation.fired`, once per firing, and the chat answers it as
  an input: the opening message reads `[Automation "<name>" fired] <message>`
  and the answer is a `message.assistant` without `in_reply_to`. The jobs are
  the Dot's own: it lists, adds and removes them with the tool, and the person
  asks it to in the chat; the host has no route that lists or changes them, and
  hears only when the earliest is next due (`automation.next_run`). `GET /tools`
  shows the permission table with what the model is offered now.
- Automations while the computer is off. The jobs live in the guest and the
  computer powers off when idle, so a job does not fire while it is off: the
  host starts the computer shortly before the earliest run (section 9.5), told
  when by `automation.next_run` (section 5.4), which the engine sends whenever
  the cron service arms its timer and the earliest next run changed. A run that
  came due while no engine ran is made once, when the engine starts. The next
  run of a job is stored in `jobs.json` and is what the service starts from: a
  time in the past is kept (the service counts a next run from now only for an
  enabled job that has none), the first tick finds the job due, runs it once
  and counts its next run from that moment. A one-time job (`at`) therefore runs
  late and is then over, and a recurring one runs once for the occurrences it
  missed, never once for each of them. A firing is recorded under the id
  `cron:<job id>:<the time it was due>` before the service saves that the job ran,
  and the engine ignores an id it already holds, so a `kill -9` between the two
  finds the job due again and the engine recognizes its firing: it runs once.
  On a stop the cron timer ends before the engine does, so no firing falls on a
  stopped engine, which records nothing while the job moves on as if it had run.
- Prepare-sleep and SIGTERM. The engine stops taking new work; a turn with no
  tool running is cancelled at once; a turn with a tool running gets up to 20
  seconds, in which the tool's result commits and the next iteration abandons
  the turn, and is cancelled at the deadline (its intent stays, and the next
  start reports it interrupted); the attempt of a cut task is given back; the
  open browsers are closed (up to 4 seconds in all on SIGTERM and up to 30 on
  prepare-sleep, with no turn left to call one; a close that outlasts the wait
  keeps running as its own task, and a browser still open when the process
  exits is ended with it); the
  WAL is checkpointed. The API (`server.py`) answers the host's `prepare-sleep`
  to its end even when the host hangs up.
- Removed from nanobot (everything since the import is in
  `invisible_engine_dots/UPSTREAM.md`): the app shells, the channels, the bus
  and the commands, the agent loop and its hooks, the other approval and guard
  mechanisms (the workspace path policy, the command guard, the sandbox, the
  SSRF guard), subagents, nanobot's skill machinery (the Dot's skills are its
  own, section 8.6), the web tools, image and document reading, the usage
  telemetry, the configuration files, every provider but OpenRouter, and the
  options nothing of the Dot sets (reasoning effort, concurrent tool batches,
  the spill of a long result to a file, the event sink, the MCP reconnect).

## 9. Control plane

### 9.1 Database (PostgreSQL)

PostgreSQL is the database on every host. By default it is PGlite (PostgreSQL
compiled to WebAssembly, `@electric-sql/pglite`) running inside the server
process with its data in `~/.invisible-dots/db`, so nothing has to be
installed. With `DATABASE_URL` set, the same migrations and the same queries
run against an external PostgreSQL 16 or newer through `pg`. The repositories
talk to one small interface (`query` for one statement, `exec` for a script
of several such as a migration file, `transaction`, `close`, and `kind`) with
two adapters; no SQL differs between them, and the test suite runs against
both. int8 comes back as a number (a value above 2^53 is an error, never
rounded) and bytea as `Uint8Array`, on both.

PGlite has one connection and does not lock its data directory, so one server
runs per `INVISIBLE_DOTS_HOME` (`server.lock`, section 3.2), transactions run
one at a time, and nothing else opens the database: `invisible-dots doctor`
asks the running server instead. Each migration file runs in its own
transaction, which first takes a transaction-scoped advisory lock, so two
servers migrating one external database apply every file once.

One database serves one control plane. `server.lock` only guards one
`INVISIBLE_DOTS_HOME`, and two servers with different homes on one external
database would each reconcile, dispatch and stop the other's Dots (one finds
no disk for the other's VMs and marks them ERROR). So the server also holds a
session-level advisory lock on its database for its whole life
(`Database.holdInstanceLock()`) and refuses to start without it; the lock goes
with the session, so a server that died leaves nothing to clean up.

Event ids are visible in id order: every insert into `events` takes a
transaction-scoped advisory lock before its `bigserial` id is drawn, held
until its transaction commits. Without it, on PostgreSQL a transaction that
drew id 10 could commit after one that drew 11, and a client that resumed
`GET /api/stream` after 11 would never see 10. A transaction that inserts an
event and changes other rows inserts the event first, so the lock is never
taken while holding a row lock another event writer waits for.

A host event is stored in the transaction of the change it tells of, and
published after COMMIT: the Dot or its computer changing state (`dot.created`
with its rows, `computer.state` and `computer.started` with the process and the
images, `computer.stopped` with the stopped state and the Dot's status,
`dot.deleted` with the deletion, `dot.updated` with the saved config, ERROR with
`dot.updated`), a task (`task.created`, `task.cancelled`, and the `task.failed` of a task
whose delivery the host gives up), an answer (`approval.resolved`, and
the `dot.updated` of "always allow"), and what a channel reports or the person
does to it (`channel.status`, `channel.changed`, `channel.peer.paired`). A
control plane killed between two writes therefore leaves the state it was in
before, which recovery knows how to finish (a computer found off that was not
recorded as stopped is recorded now, with its `computer.stopped`), and never a
state nobody was told of: the web's views follow the events, so a state without
its event would stay wrong in them for good. `commit-points.test.ts` of the
scheduler and of the channel hub kill the process at the last write of a stop, a
deletion, a creation, a save, a status, a pause, a removal and a pairing, and
check that neither the state nor the event is there.

Tables: `dots`, `computers`, `tasks`, `task_runs`, `events`, `approvals`,
`inbound_events`, `secrets`, `channel_bindings`, `channel_peers`,
`channel_pairings`, `channel_prompts`, `schema_migrations`. Migrations are plain
SQL files applied in order at start.

- `dots(id text pk, name text unique, config jsonb, status text, error text null, config_version int default 1, created_at, updated_at)`: `config_version` grows with every save of `config` (`updateConfig` and `setPermission`) and with nothing else, while `updated_at` also moves with every status change; the PATCH precondition is on the version
- `computers(dot_id pk fk, vm_name, guest_port int null, pid int null, state text, golden_image text, runtime_image text, token_enc bytea, event_cursor bigint default 0, last_active_at, next_automation_at timestamptz null, stop_reason text null, last_error, updated_at)`: `guest_port` and `pid` are null while no QEMU runs, and `guest_port` is not unique (a crashed VM's row may name a port since reused); both are copies of `qemu.json` (section 3.2), which wins on reconciliation; `next_automation_at` is the guest's last `automation.next_run` report (migration `0008_computer_next_automation`), null while none is due or nothing was reported, and it is the guest's report: nothing else of the row moves with it; `stop_reason` (`idle`, `user` or `exited`, same migration) is why the computer is STOPPING or STOPPED and is null in every other state (section 9.5)
- `tasks(id text pk, dot_id fk, description, priority int, status, created_at, scheduled_at, started_at, finished_at, summary, error, spent_usd double precision default 0)`: `spent_usd` is the highest `spent_usd` the guest reported on the task's events (section 5.4), recorded by the host in the transaction that stores each event, so a late or repeated event never lowers it and a cancelled task the guest keeps working on still counts; a task whose guest never reported spend stays 0
- `task_runs(id pk, task_id fk, started_at, delivered_at, finished_at, outcome)`: `delivered_at` is set when the guest accepted the run's `task.created`
- `events(id bigserial pk, dot_id, type, data jsonb, source 'host'|'guest', guest_seq bigint, created_at)`, unique `(dot_id, guest_seq)`, and unique `(dot_id, data->origin->>binding_id, data->origin->>external_id)` for a `user.message` with an origin: a channel message is stored once, by the channel's own id, in the transaction that stores it, so a redelivery after any failure finds the first one and the Dot gets it once (section 9.8)
- `approvals(id text pk, dot_id, task_id, tool, permission, arguments jsonb, reason, status 'pending'|'approved'|'rejected'|'expired', note, created_at, resolved_at)`: an approval whose task reached a terminal state before anyone decided is `expired`, in the same statement that ends the task, and an `approval.requested` for a task that is already terminal is stored as `expired`, never `pending`
- `inbound_events(seq bigserial pk, id text unique, dot_id fk, type, data jsonb, ts, task_id, run_id, created_at, sent_at, delivered_at, dropped_at, drop_reason, failures int, last_error, retry_at)`: the outbox of host to guest events (section 9.2)
- `secrets(scope text, name text, value_enc bytea, updated_at, pk(scope, name))`: `scope` is `global` or a dot id; no foreign key can cover that, so deleting a Dot deletes the secrets scoped to it in the same statement (`DotsRepository.delete`)

- `channel_bindings(id text pk, dot_id fk cascade, kind 'telegram'|'whatsapp', enabled bool, settings jsonb, status, status_detail, account, event_cursor bigint, created_at)`, unique `(dot_id, kind)`: one Dot's link to one channel kind (section 9.8), and unique `account` among the `telegram` bindings whose account is known: one bot serves one Dot (a WhatsApp number is learned at the scan and may be linked on several Dots, each a device of the phone); `settings` is `{approvals, notify_tasks, show_arguments}` and never a credential; `account` is the channel's public name for the account (a bot's username); `event_cursor` is the id of the last event of the Dot the hub dealt with
- `channel_peers(binding_id fk cascade, peer_id, chat_id, role 'owner'|'user', label, created_at, pk(binding_id, peer_id))`: the people allowed to talk through the binding, by the channel's stable id, with the chat they paired from
- `channel_pairings(binding_id fk cascade, code_hash, expires_at, consumed_at, pk(binding_id, code_hash))`: one-time pairing codes, stored hashed
- Where a channel message came from is in its `user.message` event (section 5.4), the one owner of that fact; there is no table of handled messages. An index on `events` by `(dot_id, data->>'message_id')` for `user.message` lets an answer find the message it answers
- `channel_prompts(binding_id fk cascade, approval_id fk approvals cascade, chat_id, ref, created_at, pk(binding_id, approval_id, chat_id))`: the approval prompts a channel sent, one message per chat; `ref` is the channel's handle for the message (a Telegram message id), what an edit needs. A row is deleted once its prompt was edited to the outcome

Secrets are encrypted with AES-256-GCM under `master.key`. The OpenRouter key
is looked up as `(<dot_id>, openrouter_api_key)` first, then
`(global, openrouter_api_key)`.

### 9.2 Durable queue

The dispatcher claims work with
`SELECT ... FROM tasks WHERE status = 'PENDING' AND (scheduled_at IS NULL OR scheduled_at <= now()) ... FOR UPDATE SKIP LOCKED`,
one task per Dot at a time (a Dot with a `RUNNING` or `WAITING_APPROVAL` task
is skipped). One dispatcher runs per database (section 9.1); the row locks
make a claim and the rest of its transaction one unit, and are not what would
keep two dispatchers from claiming two tasks of one Dot.

Everything the control plane tells a guest goes through one durable outbox,
`inbound_events`, written in the same transaction that decided it: a claim
stores its task's `task.created` (and opens a run), a resolved approval its
`approval.received`, a message its `user.message`, a cancel its
`system.event`. Nothing is kept only in memory, so a failed wake or a control
plane restart loses nothing a person saw accepted. One deliverer
(`apps/scheduler/src/inbound.ts`) sends a Dot's undelivered rows in order,
waking the Dot first when it sleeps, and stops at the first failure so a later
event never overtakes an earlier one:

- A row is delivered when the guest answers 202. Every READY transition
  sends the Dot's rows again, and a periodic pass retries rows whose retry
  time came.
- Whether a `task.created` may still go out is decided in the statement that
  marks its send begun: a task that stopped being active meanwhile (a cancel
  that won the race with a wake) is dropped there and never sent. A cancel of
  a task whose send never began drops that `task.created` in its own
  transaction; otherwise the guest may hold the task, so the cancel stores a
  `system.event` behind it.
- A send whose outcome is unknown (a timeout, a reset connection) may have
  reached the guest: it is sent again with the same id, which the guest
  ignores if it has it, and it never counts as a failure. Only failures
  with a known outcome count: the guest refused the event (it is dropped),
  or nothing listened. After 3 such failures, or one refusal, a `task.created`
  gives its task up as FAILED, logged as `task.failed` in the same transaction
  (a task cancelled meanwhile stays cancelled); a message or a decision is never
  given up and waits for the next READY.

### 9.3 Lifecycles

VM states: `PROVISIONING, STARTING, RUNNING, STOPPING, STOPPED, ERROR, DELETING`.

Dot states: `CREATING, READY, IDLE, RUNNING, WAITING_APPROVAL, ERROR`. A Dot whose
computer sleeps is IDLE and its computer STOPPED: there is no idle state of a VM.

Task states: `PENDING, RUNNING, WAITING_APPROVAL, COMPLETED, FAILED, CANCELLED`.

A Dot is READY when all of these hold:
the QEMU process is running, `GET /v1/health` answers through the port forward with
`agentd: "ok"` and the agent `status: "ok"`, the OpenRouter key has been pushed
(`openrouter_configured: true`), and the guest's own checks pass (filesystem
writable, network reachable, browser layer installed) as reported in the
health answer.

The READY procedure runs under the Dot's lock, like every operation that
changes a computer's state, and is the one place that starts a Dot's event
pump; it first stops a pump of an earlier start, which would read a guest
port that is gone. The key and the config are read from the database when
they are pushed. A key or a config stored while the procedure runs bumps the
Dot's generation, and the procedure pushes again until it completes on an
unchanged generation, so a tightened permission or a rotated key is never
lost in that window; pushes to a READY guest run one at a time per Dot, so the
last one sent is the newest. Every stop, reboot and delete takes the Dot out
of READY before anything else, so a delivery that skipped the lock because
the Dot was READY can only meet a stop that has not begun.

### 9.4 Create

`POST /api/dots` -> insert `dots` (CREATING) -> generate a token ->
`qemu-img create -f qcow2 -F qcow2 -b <golden> disk.qcow2 <disk>` -> write
`seed.iso` -> pick a guest port -> spawn QEMU and write `qemu.json` (section
3.4) -> wait for the forward -> wait for health -> push the secret -> `PUT
/config` -> open the event stream -> READY.

### 9.5 Sleep and wake

When a Dot has no PENDING task that is due, no RUNNING or WAITING_APPROVAL
task, nothing undelivered in its outbox and no automation due within the wake
lead time (below), its agent state is IDLE, and
nothing happened for `idle_timeout`: `POST /v1/agent/prepare-sleep` ->
`POST /v1/system/poweroff` -> QEMU exits (killed after 60 s, section 3.4) ->
STOPPED. The idle stop checks all of it again under the Dot's lock, after
taking the Dot out of READY, and is called off when work arrived meanwhile.
Disk, identities and memory stay. A new task or message for a STOPPED Dot
starts the VM, waits for READY and then delivers it; so does a scheduled task
when its `scheduled_at` comes. A STOPPED Dot whose due work waits behind a task
its guest has not finished (it was stopped mid-task) is started too, so its
guest finishes that task and the next one can be claimed.

A Dot's automations (section 8.8) run in its guest, which is off while the
Dot sleeps, so the host starts the computer for them. The guest reports, with
`automation.next_run` (section 5.4), when its earliest enabled automation is due,
and the host keeps it in `computers.next_automation_at`. The scheduler's pass
(every `dispatchIntervalMs`, 5 s) starts every STOPPED computer that the person did not stop (below) and whose Dot is not
in ERROR or CREATING and whose next automation is due within the
wake lead time (`lifecycle.automationWakeLeadMs`, 90 s by default: a start
reaches READY with some to spare) or is already past, a run missed while the
host or the computer was down, which the guest makes as it starts. The same
condition is part of "has work" for the idle sleep, in the idle check and
again under the Dot's lock, so a computer is not put to sleep when a run is
due within the lead time, and with an automation every minute it stays up.
The start is the ordinary one (the key and the config are pushed), and the run
itself is the guest's: the host decides only when the computer starts.

An explicit stop by the person wins over the automations. Why a computer is off
is recorded with it (`computers.stop_reason`: `idle` for the sleep above,
`user` for the person's stop through `POST /computer/stop`, the CLI or the
web, `exited` for a VM that stopped by itself), kept while the computer is
STOPPING or STOPPED and cleared by any start. A computer the person stopped is
not started for its automations, missed or due, until the person starts it
again: they are paused while it is stopped, and the CLI (`status`, `computer
stop`) and the web (the stop confirmation, and the note below) say so. A message or a task for it
still starts it, as it does for any stopped Dot, and from that start on it
sleeps and wakes for its automations like any other. The person's stop of a
computer that is already asleep is recorded too. A stop that the control plane
was interrupted in is finished for the reason it was asked for, without the idle
check again: the shutdown had begun, and the guest may already have taken
prepare-sleep. Work that came due meanwhile starts the computer again from the
next pass, as for any stopped Dot.

"Has work" is one definition, `Lifecycle.keepsAwake`: a task or inbound work for
the Dot, or an automation due within the lead time (a past one included). The
idle check, the idle stop under the lock and the restart after an unexpected
exit all read it.

A VM that stops
without being asked (the guest powered itself off, QEMU crashed) is recorded
as STOPPED, and started again at once when `keepsAwake` says the Dot still has
work.

`next_automation_at` arrives only from a guest that ran. A Dot that was asleep
when migration `0008` was applied has none stored, so it is not woken for its
automations (and misses their runs) until it starts for another reason: a
message, a task, or the person. Its guest then reports its next run at that
start, and the automations are woken for from there on. The host does not boot
every sleeping Dot once at an upgrade to ask.

### 9.6 API

All routes require `Authorization: Bearer <api token>` (from
`~/.invisible-dots/config/api.token`, created at first start). The server
binds `127.0.0.1:8787` by default (`INVISIBLE_DOTS_LISTEN`). Every reader of
the token (the server, the command, the web server) reads it through one
function, `readApiToken()` in `packages/shared/src/api-token.ts`:
`INVISIBLE_DOTS_TOKEN` when set, otherwise the first line of `api.token`,
trimmed, and at least 16 characters.

```text
POST   /api/dots                     body: { config: <yaml string> | <object> }
GET    /api/dots
GET    /api/dots/:id
PATCH  /api/dots/:id                 body: { config, expected_config_version? }   (pushed to the guest if running; with `expected_config_version`, the `config_version` of the Dot as read, a Dot whose config changed since is a 409 `dot_changed` and nothing is saved)
DELETE /api/dots/:id                 destroys the VM and its disk, then deletes the Dot, its rows and its own secrets

POST   /api/dots/:id/messages        body: { text }
GET    /api/dots/:id/messages        ?limit=&order=asc|desc&before=<event id>   conversation, from the event log (a user message carries `origin` when it came through a channel); oldest first by default, at most 500 a page; `order=desc` is the newest first and `before` (the `event_id` of the oldest message of the previous page, desc only) goes on, older, from there
POST   /api/dots/:id/tasks           body: { description, priority?, scheduled_at? }
GET    /api/dots/:id/tasks           ?limit=&before=<task id>   the newest created first, at most 200 a page; `before` (the id of the last task of the previous page) goes on, older
GET    /api/tasks                    ?status=COMPLETED|FAILED|CANCELLED&finished_after=<ISO time>   { tasks }: the tasks of every Dot that ended in that state after that time, the latest end first, at most 200
GET    /api/tasks/:id
POST   /api/tasks/:id/cancel

GET    /api/dots/:id/computer
POST   /api/dots/:id/computer/start
POST   /api/dots/:id/computer/stop
POST   /api/dots/:id/computer/reboot
GET    /api/dots/:id/computer/screenshot

GET    /api/dots/:id/browser-identities
POST   /api/dots/:id/browser-identities
GET    /api/dots/:id/browser-identities/:identityId
DELETE /api/dots/:id/browser-identities/:identityId
GET    /api/dots/:id/browser-identities/:identityId/frame     image/jpeg, only while the identity is open (409 not_open, 503 busy, 502 frame_failed or crashed: the engine's own answers pass through)
POST   /api/dots/:id/browser-identities/:identityId/close     204; the browser ends, the profile stays

GET    /api/dots/:id/channels        { channels: [{ kind, enabled, status, status_detail, account, settings, peers, created_at }], available: [kind] }; never a token; `available` is what this server runs (WhatsApp only when it was started with it, section 9.8)
GET    /api/channels                 { channels: [{ dot_id, kind, enabled, status, ... }] }: every channel of every Dot, each with its Dot's id; never a token
PUT    /api/dots/:id/channels/telegram  body: { token }   links the Dot to the bot (201), or gives the linked bot a new token (200); the token is checked with Telegram, stored encrypted, never returned
PATCH  /api/dots/:id/channels/:kind  body: { settings?: { approvals?, notify_tasks?, show_arguments? }, enabled? }   enabled false pauses the channel, its people and token stay
POST   /api/dots/:id/channels/whatsapp/link   202 the channel's record, waiting: starts linking WhatsApp (400 when the server does not run it, 409 `already_linked`)
GET    /api/dots/:id/channels/whatsapp/qr   server-sent events of `ChannelLinkFrame` (`waiting`, `code`, then `linked` or `failed`, and the stream ends); never cached, never stored
DELETE /api/dots/:id/channels/:kind  unlink: the channel stops, its token (WhatsApp: the linked device's keys) and its people are deleted
POST   /api/dots/:id/channels/:kind/pairing   201 { code, deep_link, message, expires_at }: a one-time code, valid ten minutes; `message` is what to send the account to pair
DELETE /api/dots/:id/channels/:kind/peers/:peer   revoke a paired person

GET    /api/approvals                ?status=<a,b>&dot_id=<id or name>&limit=&order=asc|desc&before=<id>   `dot_id` keeps the approvals of one Dot, in the database; `status` is one or several of pending|approved|rejected|expired; oldest first by default, `order=desc` is the newest first by the time of the last change (the answer, for an answered one) and `before` (the id of the last row of the previous page, desc only) goes on from there
POST   /api/approvals/:id/approve    body: { note?, always?: true }   `always` also sets the approval's permission to `allow` in the Dot's config in the same transaction (then pushed like a PATCH, `dot.updated` logged); `approval.resolved` carries `always: true`
POST   /api/approvals/:id/reject     body: { note? }

GET    /api/dots/:id/events          ?after=<id>&before=<id>&limit=&types=<a,b>&tools=<a,b>&task_id=&order=asc|desc   `types` are event type names (an unknown one is a 400), `tools` narrows `tool.called` to those tools (`data.tool`) and leaves other types alone, `task_id` keeps the events whose `data.task_id` it is, `order=desc` is the newest first so that a `limit` keeps the newest, and `before` (the id of the oldest event of the previous page, desc only) goes on, older, from there
GET    /api/dots/:id/files/list      ?path=   { path, entries: [{ name, type, size, mtime }] }: a directory under /home/dot (home when omitted)
GET    /api/dots/:id/files           ?path=   the bytes of a file under /home/dot, at most 16 MiB (413 `file_too_large`)
GET    /api/dots/:id/tools           { tools: [{ name, permission, offered, description }], mcp_servers: [{ name, state, error, tools }] }: the engine's tool table and what the model is offered now, and where each declared MCP server is; needs the computer running
GET    /api/dots/:id/mcp-secrets     { dot_id, secrets: [{ server, name, set }] }: every secret the config's MCP servers name, and whether it is set; never a value
PUT    /api/dots/:id/mcp-secrets/:server/:name   body: { value }   sets it (404 for a secret the config does not name, 400 for a value that breaks MCP_SECRET_RULE) and pushes the secrets to a running guest, which starts the server again with it
DELETE /api/dots/:id/mcp-secrets/:server/:name   clears it
GET    /api/dots/:id/skills          { skills: [{ name, description, source, path, content }] }: the Dot's skills (section 8.6); needs the computer running
GET    /api/dots/:id/usage           ?since=<ISO 8601 timestamp>   { dot_id, since, spent_usd }
GET    /api/stream                   SSE: every event, ?dot_id= to filter
PUT    /api/secrets/openrouter       body: { value, dot_id? }
GET    /api/health
GET    /api/doctor                   { ok, checks: [{ id, label, status: ok|missing|failed, detail, fix? }] }: the host report of section 11.1, run on the machine the server runs on
```

`GET /api/health` answers `{ status: "ok", database: "ok", version,
openrouter_configured, database_kind, data_dir, logs_dir }`; `openrouter_configured`
is whether a global OpenRouter key is stored, which `invisible-dots doctor`
reports, and the last three say where the state lives (`pglite` or `pg`,
`INVISIBLE_DOTS_HOME` as the server resolved it, and its `logs/`), so the web
client's host settings page can tell the person without their knowing the
environment variable.

`GET /api/dots/:id/events` returns at most `MAX_EVENT_PAGE` (1000, in
`packages/shared`) events a call: the store clamps to it, the route refuses a
larger `limit` with a 400, and a client that pages through the log asks for
exactly that many, so a shorter page is the last one.

`GET /api/doctor` answers the report of section 11.1 as the server's own host
sees it, the same rows in the same order as `invisible-dots doctor --json`
(`{ ok, checks }`, `ok` true only when every check is). It runs QEMU's
accelerator probe, so it takes a moment and it is not polled.

`GET /api/dots/:id/usage` answers the model spend the Dot's guest reported, in
USD, since `since` (the first event when omitted; a malformed `since` is a 400).
The event log is its one source: it sums `spent_usd` over the events that end a
unit of spend, a task's `task.completed` and `task.failed` (each carries the
whole task) and the chat's `message.assistant` (each carries what the chat spent
since its last answer), by the
time the host stored them. `task.progress` is left out because its value is the
running total of a task that ends with one of those events. Work that never
reported an end (a cancelled task) is not in the
total; the task's own `spent_usd` still shows what was heard of it. Like
`/events`, it reads the history of a deleted Dot by id.

`GET /api/dots/:id/events` filters in the database: `types` is a comma-separated
list of type names, `tools` a comma-separated list of tool names that narrows the
`tool.called` events (the other types pass), `task_id` matches `data->>'task_id'` (the one place the
contract puts the task, so the host's `task.created` and `task.cancelled` and
the guest's `task.*`, `tool.called` and `approval.requested` of a task, and the
host's `approval.resolved` of one, all match), and all combine with `after` and `limit`; `order=desc` reads from the newest
event back (the limit then counts the newest that the filters keep, and the page is
newest first), and `before` (an event id, desc only) goes on from there: the events
older than it, which is how the Activity page pages through a long log. A chat turn's events carry
no task. Migration `0006_events_task.sql` adds the expression index the task
filter reads. A type name no event has (`tool.calls`) is a 400, so a typo does not
look like a quiet Dot.

`GET /api/dots/:id/tools` and `GET /api/dots/:id/skills` pass through to the engine's
routes of section 5.3: the tool table and the skills are the engine's, and the control
plane keeps no copy of either. They need the computer running (`409 computer_stopped`),
and the engine's own refusals pass through with their code and status.

`GET /api/dots/:id/files/list` and `GET /api/dots/:id/files` read the Dot's
computer through dot-agentd's `GET /v1/files/list` and `GET /v1/files`, and
only under `/home/dot`: `path` is absolute, relative to `/home/dot` or `~`, and
the control plane normalizes it (`checkHomePath` in `packages/shared`) so the
guest always gets an absolute one; a path outside home, or with any `..` segment,
is a `400 invalid_path` without a call to the guest. That check is lexical and
only the early answer; the rule is dot-agentd's: its TCP listener (the host's
door) resolves every path to its real location with the symbolic links followed
and refuses one that is not under home, `403 outside_home`, which passes through
(a link under home to `/proc/<pid>/environ`, where the browser server runs as `dot`
with the proxy password in its environment, shows nothing; the session file the
server saves the proxy in is not under home at all, section 4.2). The same goes for the
`PUT` and the listing of that listener; a link that stays in home works, one that
leaves it lists as `other`. The engine's socket is not confined. A read is one buffered answer of at most 16 MiB; a larger
file is a `413 file_too_large` and the host stops reading it as soon as it passes
the limit. The bytes are the Dot's own (a model wrote them, perhaps after reading
hostile text) and the web server answers from the page's origin, so the type is
never one a browser runs: images are served as `image/png`, `image/jpeg`,
`image/gif` or `image/webp` inline, source and markup (`.md`, `.json`, `.html`,
`.svg`, ...) as `text/plain` inline, everything else as a download, always with
`nosniff`, `Content-Security-Policy: default-src 'none'; sandbox` and `no-store`
(the web proxy passes those headers on). The guest's own refusals pass through
with their code (`404 not_found`, `400 is_a_directory`, `400 not_a_directory`).

Browser identity and file routes need the Dot's computer running: on a stopped
Dot they answer `409 { error: "computer_stopped" }`.

Errors are `{ error: <code>, message }` with a 4xx or 5xx status.

### 9.7 Web client

`apps/web` is a Next.js server on `127.0.0.1:3000`. `invisible-dots server`
starts it: the build `npm run build --workspace @invisible-dots/web` leaves
(Next's standalone server and the browser files beside it, assembled by
`apps/web/scripts/standalone.mjs`) is run with `node` as a child process of the
server, on `INVISIBLE_DOTS_WEB_LISTEN` (default `127.0.0.2:3000`), with
`INVISIBLE_DOTS_URL` set to the control plane's address; the setting is read
before anything starts, so a malformed value or port 0 (the person has to be
told where to go) fails the command at once. The child gets an
allowlisted environment, not the server's: the data directory (so it reads
`api.token` itself on every request), `INVISIBLE_DOTS_TOKEN` only when the
server was given the token that way, and `INVISIBLE_DOTS_WEB_ALLOWED_HOSTS`.
It also gets the server's pid (`INVISIBLE_DOTS_WEB_PARENT_PID`) and exits when
that process is gone (`apps/web/src/instrumentation.ts`), so a `kill -9` of the
server does not leave an orphan holding the port: a stop signal ends the child
through the server, anything else through the child itself.
The web client is a companion, not a dependency: when it is not built, its
port is taken or it exits, the server logs why and the control plane and the
command line go on; `server --no-web` does not start it. A stop signal closes
the web client first, then the control plane, and a Ctrl+C while the web
client is still starting ends that start. It answers `/api/...` with
the control plane's own paths, so the browser uses the SDK unchanged, and
adds the API token on the way, so the browser never sees it. It holds that
token, and it has no login: it listens on `127.0.0.2:3000`
(`INVISIBLE_DOTS_WEB_LISTEN`), a loopback address no guest reaches. QEMU's user
network maps `10.0.2.2` to the host's `127.0.0.1` only (section 3.6), so a Dot's
VM reaches the API on `127.0.0.1:8787`, which needs the token, and never the web
client. The Host, Origin and `Sec-Fetch-Site` checks stay, as a defence against
DNS rebinding and cross-site pages: the Host must be a loopback name (any
`127.x.y.z`, `localhost`, `::1`) or listed in `INVISIBLE_DOTS_WEB_ALLOWED_HOSTS`.

The pages are React with Tailwind CSS 4. `src/app/tokens.css` is the one place
that holds a color, a radius or a typeface (a light and a dark set, each pair
checked for WCAG AA contrast by a test), `globals.css` maps it into Tailwind,
and the primitives in `src/components/ui/` are shadcn/ui source, copied in
(`THIRD_PARTY_NOTICES.md`). Every page sits in one frame: the rail
(the Dots with a ring around each avatar that says what it is doing, the Inbox
with what needs the person, the state of the API and of the live stream, the theme)
and, for a Dot, its header and tab bar. One live stream serves all of
it; `lib/attention.ts` is the single owner of what needs the person, and the
rail badges, the avatar ring, the tab title and the favicon all read it. There
is no other stylesheet: every screen is utilities over the tokens. The browser tests (`apps/web/e2e`, Playwright) start the
real control plane in-process over the fake VM layer and the built web client
against it (`e2e/harness.ts`), so a test drives what a Dot's computer does.

Home (`/`) is a card per Dot: its avatar ring and name, the state with the
recorded reason beside an ERROR, the model, what it spent today, its last
activity (the newest chat, task, tool, approval or browser event, one
`order=desc&limit=1` read and then the stream), the approvals that wait, Open chat and the computer's power menu. Each card's spend pill is
scoped to its own Dot, so a message of one Dot re-reads only that Dot's usage.
Search appears above six Dots, and with no Dot the page invites the first, and,
while this computer is not ready for a Dot, shows the setup checklist under the
invitation: each check of `GET /api/doctor` and `GET /api/health` that is not
ready, with the command that fixes it and a button that copies it (setup needs
an elevated terminal and an image build takes long, so they stay commands the
person runs), and the key field when no key is stored. The checks run again
when the person returns to the window while something is missing, and the
checklist stays, turned green, once the last thing is done. A ready host shows
none of it.

Settings (`/settings`, in the rail) are the host's, not a Dot's: the same checks
(`useHostChecks` is the one list the checklist, this page and the create form's
preflight draw), the OpenRouter key (a write-only field over
`PUT /api/secrets/openrouter`; whether one is stored comes from the health
answer, which the shell shares and asks again after a save, so the rail agrees
at once; the answer says how many running Dots got it), the theme and About:
the version, the database kind, the data
directory and the logs directory, which `GET /api/health` reports for the
purpose (`database_kind`, `data_dir`, `logs_dir`), and `invisible-dots logs
<dot>` for a Dot's own logs.

Create a Dot (`/new`) is a form in three steps (Identity, Brain, Computer and
safety) with sliders inside `CONFIG_BOUNDS`, the idle timeout, the Careful,
Balanced and Autonomous permission presets, the cost cap and the optional
summary model; or the same config as YAML, where the form refuses to take back
YAML that sets what it has no control for instead of dropping it. The shared
config schema is the only judge: `lib/dot-form.ts` maps its issues onto the
controls, and a name another Dot has is refused at once. A preflight panel shows
what `GET /api/health` reports (the control plane, its database, the OpenRouter
key) and, below it, the host report of `GET /api/doctor` (QEMU, the accelerator,
disk, the images), each failing row with the command that fixes it; the doctor's
own key row is left out, so the key is said once. Submitting is `POST /api/dots`, and then the Dot's chat opens.

A Dot's settings (`/dots/<id>/settings`) are the same config, edited in place:
one draft of the whole `DotConfig`, as a form (General, Model, Permissions and
tools, Computer, Limits) or as the same YAML, never a second
model of it. `lib/config-fields.ts` is the one table of what can change (where
each field lives, its words, when a change reaches the Dot) and gives what the
page needs from it: the list of changes, the notice a save ends with, and the
rebase below. Nothing is written until the person has seen the review, which
lists each changed field from what it is to what it will be; the save is a
`PATCH` conditional on the `config_version` the edit began from, so a config
changed meanwhile (another tab, an "Always allow") is refused with 409
`dot_changed` and never undone. When the host's config moves on under an edit
that is under way, the edits are kept on top of the new config
(`lib/config-draft.ts`) and the page says so; a field only the other change
touched keeps what that change says. The permission editor has one row per
permission of `PERMISSIONS`, with its words and risk, a three-way allow, ask or
deny control, the default said, and the tools of the Dot's own table (`GET
/api/dots/<id>/tools`, so a tool the engine adds shows with no change here)
with whether the model is offered each: those are as the Dot has its config
now, so a changed row says its tools show the change once it is saved. A
permission set to what its default is is saved as no entry. A stopped computer
has no table: the page says to start it, and the permissions can be set
meanwhile. A change reaches a running Dot from its next turn (`PUT /config`);
the computer's size (processors, memory, disk) applies the next time the
computer starts, and a disk can grow but never shrink. The Danger zone deletes
the Dot after its name has been typed.

The Dot header's error banner gives the reason and "Open settings", and one way
back: Reboot while the computer is up (the host reboots only a running
computer), or Start the computer when the computer itself is in ERROR. Both
use the power menu's one action, which asks before a stop and, while a task runs, before a reboot.

The Tasks page (`/dots/<id>/tasks`) shows a Dot's tasks in four sections:
Running (the newest `task.progress` line of each task, what it has spent from
the task row's `spent_usd`, how long it has run, Cancel after a question),
Scheduled and Queue (in the order the dispatcher takes them: priority, then
age, then id, which a test pins to the dispatcher's `ORDER BY`), and History (filtered by how the task ended, twenty at a time). A task
has its own address, `/dots/<id>/tasks/<taskId>`, which opens a drawer over the
list with its state, its result as markdown or the reason it failed, and its
story. The task route knows a task by its id alone, so a task of another Dot
opened under this Dot's address is shown as missing. The story and the progress lines come from the Dot's event log, which
the page reads from its start, asking only for the event types of a task's
story (`readEventLog` of the SDK, `packages/sdk/src/event-log.ts`, is the one
function that pages through the route's `types` filter) only once a task is running
or open, and then keeps current from the live stream. The newest progress line of a running task is also under the name in
the Dot header. A task that waits for an answer shows its approval as a card on its own card and in its
drawer, answerable there (see the Inbox below).

The chat (`/dots/<id>/chat`) is the conversation: the person's messages as
bubbles (one that came through Telegram or WhatsApp says "via Telegram", from
the `origin` of the message), the Dot's as markdown (no raw HTML, links open in a new tab without a
referrer, an image is shown as a link to it, a fenced block has a copy button).
Between them it shows what the Dot did to answer, read from the same event
log: each `tool.called` that names no task as one quiet line (the words of
`TOOL_LABELS` in `packages/shared/src/labels.ts`, which a test keeps equal
to the engine's tool table, then the call's `target`, and how it ended when that was not well; more
than three in a row fold into one line that opens), and each `approval.requested` that names no task, where it
was asked, as the approval card while it waits (answerable there) and as a receipt
line once answered ("Allowed for good" when the answer was "always", with the
person's note). A call and an approval are read into a step one way for the
chat, a task's story and the Activity page, with one set of words for how a
call ended and one format for how long it took (`lib/steps.ts`). The messages route and the log are two
views of one log, so a step is placed between two messages by event id
(`lib/chat-thread.ts`). A message shows as soon as it is sent and is replaced by
the logged one, which `POST .../messages` names by its `event_id`; one that was
`queued` says the computer is waking up until the agent reports. While the agent
thinks or runs a tool a row says so, with the last step. The box grows with the
text, Enter sends and Shift+Enter adds a line, and an unsent draft is kept per Dot
in this browser. The computer panel is always beside the thread (from 1024 px; a
strip above it below that), and both reach the bottom of the window: the page column
is as tall as the window, a Dot's header and tabs stay and the tab's body fills the
rest. The panel shows the desktop, an open browser being a window on it, as
the pictures the host reads from the guest every few seconds while the page is
visible, with a LIVE badge, a warning when a frame is more than 15 s old, and the
words "The Dot has control", because nothing the person does there reaches the
computer.

The Inbox (`/inbox`, in the rail) is where everything that needs the person is,
from every Dot. Its address holds its whole state: `?tab=history`, `?dot=<id or
name>` and `?permission=<name>` (the old `/approvals` and `/dots/<id>/approvals`
redirect to it). "Needs you" lists the waiting approvals, the one that has waited
longest first, then the Dots in ERROR and the tasks that failed in the last 24
hours (each dismissable; the dismissals are kept in this browser only, so a
cleared browser shows them again). The shell reads them for every Dot at once
(`GET /api/tasks?status=FAILED&finished_after=`, a day back) and again on
`task.failed`, and says when they could not be read.
`lib/attention.ts` counts the three, and the rail's Inbox badge, the tab title and
the favicon all read that one count. The approval card (S7) says what the Dot
wants to do from the engine's tool table (`TOOL_LABELS`), the
permission and its risk (`PERMISSION_INFO`, `permissionPhrase`), the Dot's reason, and the call's
arguments in the form that reads best: a command, a diff for `write_file`,
`edit_file` and `apply_patch`, an address, a schedule, with the raw arguments
under Details (a proxy's password is never shown). It is destructive for a
command, the deletion of a browser identity and a change to a file outside the
workspace. The answers are Allow once, Always allow and Deny with an optional
note. Always allow asks first, naming the permission, what it can do and the tools
it covers (`GET /api/dots/<id>/tools`, when the computer answers), and then
`POST /api/approvals/<id>/approve` with `always: true`, which changes the Dot's
config (section 9.6). The host answers 409 `already_resolved` to the second
answer; the card says the approval was answered somewhere else. An answered card
stays in place as a receipt until the person leaves the page. Keys, while the
focus is in the list of the cards (WCAG 2.1.4: a single key is never the whole
page's): `j` and `k` move between the cards, `a` allows the selected one once and
`d` denies it, and a card the focus enters is the one selected; a destructive
card is not allowed by a key, `a` moves the focus to its Allow once button,
whose press is the confirmation. History lists every approval that is no
longer waiting, the last answered first: it asks `GET /api/approvals` for the
answered statuses with `order=desc` and `limit=50`, and "Show older answers" asks
for the next page with `before` the last id it holds, so the newest answer is
listed however many approvals the Dots have asked for. A live refresh reads the
newest page again and keeps the older rows it reaches (when more was answered in
between than a page holds, the older rows are dropped and read again on request).
A channel that needs the person (its login was refused: a revoked Telegram token, a WhatsApp device removed on the phone; one the person paused does not count) is a
card under "Channels to link again" with what the host says and a link to the Channels page, counts in the Inbox's number, the title and the favicon, and marks
the Dot in the rail and its Channels tab. The shell reads every Dot's channels at once (`GET /api/channels`) and again on `channel.status` and `channel.changed` (the host announces a pause, a resume and a removal, which no status says, so the marks follow them without a reload); channels
that cannot be read are said, not hidden.

The Computer page (`/dots/<id>/computer`) has three views, named in the address
(`?view=screen|files|usage`, Screen when it says nothing, and so for an address of the
Browser view that was). Screen and Files read the guest and need the computer running:
when it is not, they say why and offer Start, and a route's own 409 `computer_stopped`
gets the same answer. Screen is the desktop as the chat's panel shows it (one
`FrameView` draws both), with "The Dot has control"; the Dot's browsers have no view of
their own, an open one is a window of that desktop, and the Dot makes, opens and closes
them with its tools. Files is a read-only walk through
`/home/dot` (`GET /files/list`, `GET /files`): the folder and the open file are in
the address, a text file is shown as text and an image as a picture, and
everything else, and any file over 1 MiB (text) or 8 MiB (image), is a download
only. What counts as text or an image is `fileType` of `packages/shared`, the one
table the API serves a file by too (markup and svg are text, so a file the Dot
wrote is never run); a file named text that holds a NUL byte is not shown. Usage
reads while the computer is off: what it was given, what it uses (`GET /computer`
embeds the guest's `system` while it runs), the images, why the last start failed,
the model spend today and in total, an Automations card, and Start, Reboot and Stop.
Stop always asks and says that the automations do not run while the computer is stopped
(Reboot asks only while a task runs). The Automations card reads the host's record of the computer (`GET
/computer`: `stop_reason` and `next_automation_at`), which holds both while the computer is
off: "Paused: you stopped this computer" when the person's stop paused them, otherwise when
the next one is due (and that a computer asleep starts shortly before), or that none is due;
it follows `computer.*` events and `automation.next_run`.

The Skills page (`/dots/<id>/skills`, a tab between Computer and Activity) lists the
Dot's skills (`GET /skills`, section 8.6), read only: each with its name, its
description and whether it is built in or written by the Dot, and the open one (in the
address, `?skill=<name>`) shown as Markdown by the chat's renderer, its frontmatter left
out and its path above it. It reads the Dot's computer, so a computer that is not
running is said with Start, and the list is read again when a turn ends, which may have
written a skill.

The Channels page (`/dots/<id>/channels`) is one card per channel the server runs (`available` in `GET /api/dots/:id/channels`): Telegram always,
WhatsApp only when the server was started with `INVISIBLE_DOTS_WHATSAPP=1`. Telegram not connected asks for the bot's token (a password field, sent once over
`PUT .../channels/telegram`, emptied at once and never read back); connected, the card shows the bot, pairs a chat (`POST .../pairing`: a link that opens the
chat with the code ready, its QR code, the words to type, and the ten minutes counting down; the panel closes when `channel.peer.paired` arrives), lists the
people paired with a Revoke each, and has the three switches of the channel's settings (approvals here, tell me when a task ends, show what the Dot wants to
run), each saved as it is flipped, a Pause and a Disconnect that says the token and the people go. A refused token shows "Telegram needs a new token" with
the field to replace it, the people staying paired. WhatsApp first says that the client is unofficial and can get the number banned, then links by scanning:
the page follows `GET .../whatsapp/qr` (the frames of `ChannelLinkFrame`, reduced to one view by `lib/channel-link.ts`), draws each code itself as an SVG
from the QR modules (`qrcode`, dark on light in either theme), and ends linked with the number, or failed with the host's reason and "Link again"; a link
already going on when the page opens is followed. A number counts as linked when the host holds its account, not by the word `connecting` (a server start,
a Resume or a credential refresh report it again for a number that stays linked): only a login the host says has to be redone, or a link with no account yet,
goes through the scan. Cancel removes the channel the page's own start made, and only pauses one that holds a linked number or people (Link again on a
number that needed it), so nothing is deleted without the question that Unlink asks. The page follows `channel.status`, `channel.changed` and
`channel.peer.paired` live. The browser tests run the real Telegram and WhatsApp adapters against the hub's own fakes (`FakeBotApi`, `FakeWhatsAppConnector`).

The Activity page (`/dots/<id>/activity`; the old `/timeline` address redirects
to it) is the whole event log of the Dot as readable lines, for the person who
wants to know exactly what happened. `lib/events/view.ts` describes every type
the log can hold, written against the data the contract gives that type (a type
or field added to `packages/shared/src/events.ts` does not compile until it is
described, and a test fails for a type with no family): a tone, a title, one
line of detail (cut at 280 characters; under "Data" the event is shown as
stored), and, for a message that came through a channel, "via Telegram". A
`tool.called` line names the tool in words, what it acted on (`target`), how it
ended (ok, failed, denied, interrupted) and the policy decision; `agent.started`
says "The engine started (the key was sent again)". The families (chat, tasks,
tools, approvals, browser, computer with the agent, memory, channels, the Dot's
own config) are chips: the ones chosen become the `types` of the request, so a
family not chosen is never read, and a live event is kept only if it is of a
chosen type. The page reads the newest 200 events first (`order=desc`) and
"Load older events" goes on with `before`, the id of the oldest one held, so the
cost does not grow with the age of the Dot, and says where the log starts. The
search is over the lines read so far (title, detail, type, channel), never a
request of its own, and says so; the order switch only turns the list over. The
export saves the events on screen, after the search, as JSON Lines (one stored
event per line, oldest first) named for the Dot and the range of ids.

### 9.8 Messaging channels

A person can talk to a Dot from a chat (Telegram, WhatsApp). This is the control
plane's business only: the Dot never sees a channel, no guest route or event
type names one, and the Dot has no tool that sends a message anywhere.
`packages/channels` holds the **channel hub**, built in `startServer` right after
the Scheduler, started after `scheduler.start()` and closed before it. It runs in
the server process because the database is single-process (section 9.1) and the
credentials live in it. It uses only what the Scheduler offers: `sendMessage`
(with an origin), `resolveApproval`, `requireDot` and the event log.

An adapter (`Channel`) is transport only: `run(sink, signal)` connects and
delivers until aborted, `sendText`, `sendApproval` and `editApproval`, optionally `typing`. A `ChannelType` makes the
adapter for a binding and names the secrets a binding of its kind keeps (and which
of them are credentials a log line could hold, `scrubNames`). A kind that is
linked by scanning a code on a phone (`scanned`: WhatsApp) is linked with `link`
and never given credentials; the others with `add`. The hub owns every policy:

- **Who may talk.** Only a person paired with a one-time code, by the channel's
  stable id (a Telegram numeric user id, a WhatsApp phone number, never a mutable
  name). The code is eight
  symbols (40 bits), valid ten minutes, used once, stored as a SHA-256 hash with
  the binding id, and pairs the sender as an `owner` together with their chat.
  Anyone else, a chat that is not a private one, an empty message: dropped
  before anything is written, so a stranger costs no row and no model call. A
  paired person is held to a token bucket (10 messages at once, then 20 per
  minute, told once) and to 8000 characters per message.
- **Inbound.** A message becomes `Scheduler.sendMessage(dot, text, {channel,
  binding_id, chat_id, external_id})`; the guest receives `{text}` only. The
  channel's own message id is part of the `user.message` event, which a unique
  index allows once per Dot, binding and channel id, so the message and the proof
  that it was handed over commit together. `sink.inbound` resolves only after the
  control plane has answered, so an adapter commits its offset after the hub is
  done with the message. A redelivered message, after a failure at any point or
  across a restart, finds the first one: the Dot gets it once, and the repeat is
  answered with the first message.
- **Outbound.** One `events.stream({dotId}, {after: event_cursor})` per binding.
  `message.assistant` goes to the chat of the `user.message` its `in_reply_to`
  names, when that message came through this binding and its person is still
  paired; an answer that answers nothing (an automation's) goes to every owner's
  chat; an answer to a message from the web or another channel is not mirrored.
  `task.completed`, `task.failed` and an answer that answers nothing go to the
  owners unless `notify_tasks` is off.
  `agent.state` THINKING shows typing in the chat of the last message while the
  Dot has not answered it. Text is split at the adapter's `maxText` on paragraph,
  line and word boundaries. The cursor moves after a send succeeded (events that
  need no send are written in batches), so a restart resumes where it stopped;
  a crash between a send and the cursor write sends that message again. A send
  that fails is retried with backoff (a channel's `retry_after` is honoured); one
  the channel refuses for good (the person blocked the bot) is dropped.
- **Approvals.** When the Dot asks (`approval.requested`) and the binding's
  `approvals` setting is on, every owner's chat gets a prompt: what the Dot wants
  to do and the permission with its risk, in the words the web client's approval
  card uses (`packages/shared/src/labels.ts`), the reason and the
  arguments, each cut to 300 characters (the
  arguments can hold private data, and a chat is read by a third party; with
  `show_arguments` off the prompt leaves them out), with an
  Approve and a Reject button. Only a paired owner, in their private chat, can
  answer; the button's id proves nothing, so the hub also checks that the
  approval belongs to the binding's own Dot and that approvals are still asked
  in chats. The answer is `Scheduler.resolveApproval`, the one way an approval
  is answered, so a second press, or a press after the web answered, is the
  scheduler's 409 and the person is told it was answered already. The person
  always gets a short notice for the press. Every answer, whoever gave it,
  arrives as `approval.resolved` and edits the prompts to the outcome with the
  buttons taken away; `channel_prompts` remembers where each prompt is. The
  prompts are brought up to date when the channel starts, when a person pairs
  and when `approvals` is switched on: a prompt whose approval was settled
  meanwhile (answered elsewhere, or its task ended: "No longer needed") is
  edited, and a pending approval with no prompt in an owner's chat is sent one.
  Delivery is at least once like every send: a crash between sending a prompt and
  recording it sends it again. An approval over a chat is as strong as the
  person's Telegram account; switching `approvals` off keeps the answer in the
  app.
- **No link previews.** Nothing a Dot names is fetched on its behalf, by this
  process or by a messaging service: the Dot's only way to the web is its own
  browser (section 8.3). An approval prompt shows the URL a call is about to open,
  query included, so a preview would send that URL to Telegram's crawler (or, with
  Baileys, request it from this machine) before anybody approved it. Every Telegram message and edit says `link_preview_options.is_disabled`,
  and every WhatsApp text and edit `linkPreview: null`; the adapters' tests assert
  it against the fake Bot API (which records a link it would have fetched) and the
  library's own content builder.
- **Answers in words.** A channel without buttons (`approvalByText`: WhatsApp)
  ends its prompt with `Reply "yes ap-xxxxxx" to approve or "no ap-xxxxxx" to
  reject`, where the token is the last six characters of the approval's id. The
  hub, not the adapter, reads a message that is exactly that, from a paired owner
  only (a stranger's message is dropped before anything is read, so a stranger is
  never answered), and resolves it with the same checks and the same
  `Scheduler.resolveApproval` as a button; the person is told "Approved.",
  "Rejected.", "It was answered already.", "That request does not exist." or that
  two requests share the code. Anything else, including a bare `yes`, is an
  ordinary message to the Dot: an answer given by a misread sentence would be an
  approval nobody meant.
- **Failure.** An adapter that fails is started again after an exponential backoff
  (1 s up to 60 s, with jitter) on a fresh instance; `ChannelNeedsRelinkError`
  (a revoked token, a logged-out device) stops it until the person relinks.
  Every change of status is a `channel.status` host event, once; the reason is
  cut to 300 characters and has the binding's credentials replaced, whatever
  the adapter wrote. A new binding starts after the Dot's latest event: history
  is not replayed into the chat. When the Dot is deleted its bindings go with it
  (foreign keys) and the hub stops the adapter on `dot.deleted`.
- **Credentials.** Stored as secrets scoped to the Dot, under the names the
  channel type declares, encrypted like the OpenRouter key, never returned,
  never pushed to the guest, deleted with the binding and with the Dot. A channel
  type may check credentials before anything is stored (`check`): Telegram asks
  `getMe`, so a wrong token is a 400 `invalid_credentials` (the message never
  holds the token), an unreachable Telegram a 502 `channel_unreachable`, and a
  bot another Dot already uses a 409 `account_in_use` (a bot serves one Dot: two
  pollers on one token take turns failing). Giving a linked channel a new token
  (`PUT`) starts it again with the people kept; it is the way back from
  `needs_relink`.

#### Telegram

`packages/channels/src/telegram/` is the adapter, on grammY (the Bot API client,
MIT). It is transport only, like every adapter.

- **Long polling**, because the control plane listens on a local address behind
  NAT and polling needs only outbound HTTPS. Telegram keeps an update that was
  not confirmed for 24 hours: a PC that is off for longer loses what was sent
  meanwhile. A webhook the bot had is deleted on connect (the bot is the Dot's
  own). Only `message` and `callback_query` updates are asked for.
- **An update is confirmed to Telegram** (the `offset` of the next poll) only after
  the hub dealt with it. When the hub could not record a message the adapter
  fails, the hub starts it again, and Telegram offers the update once more; the
  hub recognises one it already gave the Dot by its id, `<bot id>:<update id>`
  (update ids of two bots overlap, and a Dot's bot can be replaced). No offset is
  stored: a restart is the same as a failure.
- **Pairing.** `/start <code>` in a private chat is a pairing attempt; the deep
  link `https://t.me/<bot>?start=<code>` sends exactly that. A bare `/start` and
  everything a stranger sends get no answer. Only private chats are served.
  Authorization is the sender's numeric user id, never a username.
- **Approval buttons.** `callback_data` is `ap1:y:<approval id>` or
  `ap1:n:<approval id>` (47 bytes for `appr_<uuid>`): versioned, checked to fit
  Telegram's 64 bytes when the prompt is made (an id that does not fit is
  refused for good) and again when parsed, and parsed strictly, so data from
  another version or a forged shape is answered "This button is out of date"
  and goes no further. A press is confirmed to Telegram only after the hub dealt
  with it, like a message. The press is always answered (`answerCallbackQuery`)
  with the hub's notice, best effort: Telegram refuses an answer that is too
  old. An edit of a prompt that is gone or already says the same counts as done.
- **Messages.** Plain text, no formatting; a long answer is split at 4000
  characters. A message without text (a photo, a voice note) is answered "not
  supported yet" to a paired person and dropped. Typing shows while the Dot
  thinks.
- **Failures are told to the hub in words.** A 401 is a revoked token
  (`needs_relink`); a 409 on polling says another process polls the same bot; a
  403, 400 or 404 on send is final (the person blocked the bot), a 429 carries its
  `retry_after`, anything else is retried. The token is in every request URL, so
  no message the adapter makes carries a URL, and the hub replaces the binding's
  token in whatever it stores or logs. Retries and backoff are the hub's alone.
- **Not private.** Telegram bot chats are not end-to-end encrypted: Telegram can
  read what a person and the Dot write there. The CLI says so when a bot is linked.

From the CLI, `invisible-dots channel add telegram --dot <dot>` (token asked for in
a terminal, where what is pasted is not echoed, or read from stdin, never from arguments), `channel list [--dot]`,
`channel pair <kind> --dot <dot>` (prints the deep link and the words to send) and
`channel remove <kind> --dot <dot>`.

#### WhatsApp (opt-in, unofficial)

`packages/channels/src/whatsapp-baileys/` is the adapter, on Baileys
(WhiskeySockets, MIT), a client of the WhatsApp Web protocol. **It is not an
official way to use WhatsApp.** It links the Dot as a device of a personal account,
which WhatsApp's terms do not allow for automation, and WhatsApp can answer by
restricting or banning the account. The library is a release candidate pinned to
one exact version (`7.0.0-rc14`; a test keeps `package.json` and the lock file at
the same exact version) because the protocol moves under it: when WhatsApp stops
accepting that release, WhatsApp stops working until the pin is moved. Use a number
of its own (a spare SIM or eSIM), never the one a person lives on. The official
Cloud API (a business account and a public webhook) is a later adapter on the same
hub.

- **Licenses and the opt-in install.** Baileys is MIT, but it depends on
  `libsignal`, which is GPL-3.0, and the default `npm install` holds nothing GPL. No
  workspace declares Baileys (not as a regular, dev, optional or peer dependency),
  so the root `package-lock.json` holds none of it and `npm ci` installs no GPL
  package (`tests/repo/default-install-licenses.test.ts` scans the lock file's
  licenses). The client lives apart in `optional/whatsapp/`: its own
  `package.json` (Baileys at one exact version, a release candidate) and
  `package-lock.json` (the integrity hash of every package), outside the
  workspaces. One command installs it, `npm run whatsapp:install` from the
  repository root: `npm ci --prefix optional/whatsapp --ignore-scripts`, a clean
  install of that lock file without install scripts. `client.ts` is the one file
  that names the library: it looks for it in that folder when a connection opens
  (`createRequire` from the folder, then one `import()` of the file's URL), loads it
  only if it is there and is the pinned release, and otherwise throws
  `WhatsAppClientMissingError` (not installed) or `WhatsAppClientVersionError` (the
  installed `node_modules/baileys` is not the exact version
  `optional/whatsapp/package.json` declares, which stays the one owner of the pin:
  a pull that moves it leaves the old release installed until the install is made
  again). Both messages name the command and the variable that turn WhatsApp on.
  The error is the channel's status detail, the server logs it at start when
  `INVISIBLE_DOTS_WHATSAPP=1` is set and `whatsappClientProblem` finds one (the
  same check the loader makes), and the "it is off" answer of linking carries the
  same words (`WHATSAPP_ENABLE_HELP`). Nothing imports the
  library by name, not even as types: the adapter writes down what it uses of it
  (`WhatsAppClient`, with the library's credentials and key data as type
  parameters) and compiles without it; `npm run typecheck:whatsapp` (a CI job,
  with the client installed) proves the real module has that shape, that the
  options of the socket the adapter builds (`socketConfig`, typed
  `WhatsAppSocketConfig`) are each an option of the library with a type it takes
  and none is a name it lacks, that the adapter's auth state is one the library
  accepts, and that the key groups are the library's own. (The methods of
  `WhatsAppClient` are compared in both directions, so those two are asserted
  separately, one way.) `npm run test:whatsapp` runs the tests that need
  the real library (`packages/channels/test-optin/`, left out of the default
  suite). The command bundle has no import of it, so no build of ours embeds GPL
  code. `THIRD_PARTY_NOTICES.md` says what that means for whoever distributes an
  installation that has `optional/whatsapp/node_modules`.
- **Off by default.** The server runs WhatsApp only when started with
  `INVISIBLE_DOTS_WHATSAPP=1` (`defaultChannelTypes` in `apps/api/src/start.ts`).
  Otherwise the type does not exist: `GET .../channels` lists only the kinds it
  runs (`available`), and linking answers 400 with how to turn it on. Baileys is
  loaded by `client.ts` when a connection opens, so a server that never
  links WhatsApp never loads it, and no file but `client.ts` names it (a test reads
  the sources).
- **One port.** `port.ts` is what the channel needs of a connection (messages in,
  text out, a code to scan, why it ended); `baileys.ts` implements it over
  the network and `FakeWhatsAppConnector` for tests, because WhatsApp cannot be
  faked. Everything WhatsApp-specific that is a decision is in `whatsapp.ts` and
  tested against the fake; the glue is tested for what it decides alone (how a
  message is read, how a close is understood) and for surviving a socket that
  cannot connect. The real network is not reached by any test.
- **Linking by a code.** `POST .../whatsapp/link` creates the binding without
  credentials and starts the adapter, which opens a connection that is not
  linked; WhatsApp sends a code every few seconds, shown on the phone under
  Settings, Linked devices, Link a device. `GET .../whatsapp/qr` streams the codes
  and the end as `ChannelLinkFrame`. The code is a way into the account for as long
  as it is shown, so it lives in memory only (`LinkSessions`): not in the
  database, not in an event, not in a log, not in a status, and the stream is
  `no-store`. A watcher that joins late gets the code on show now. The scan ends
  with `linked` and the number; a code that ran out before the scan, a device WhatsApp
  rejects or one removed on the phone ends with `failed` and `needs_relink`
  (`ChannelNeedsRelinkError`); a connection that is lost is retried by the hub with
  backoff. Linking again after a failure deletes every key of the old device first.
  WhatsApp asks for a new connection when a link finishes (status 515); the adapter
  opens it at once, and gives up after three in a row.
- **The keys are secrets.** The linked device's identity and Signal keys are an
  account takeover if they leak, so they are not the plaintext JSON files of
  Baileys' own helper: `AuthStore` implements Baileys' `AuthenticationState` over
  the encrypted `secrets` of the Dot, one secret for the credentials and one per
  group of keys (eleven; a `Record` over the library's own list of groups makes a
  group added by an upgrade a compile error), under the same AES-256-GCM and the
  same row-bound associated data as the OpenRouter key. A change is written (the
  credentials and the groups that changed, in one transaction, in order) before it
  is acknowledged to Baileys, so a crash leaves the state as it was or as it is
  now, never a step apart; a failed write is kept and tried again with the next.
  A closed store refuses every write, so a delete by the hub is final, and the
  write itself holds the binding row, so a session still open when the channel or
  its Dot is deleted cannot write its keys back afterwards (the write is refused
  as `ChannelGoneError`). They are never sent to the guest, and deleted with the
  channel and with the Dot.
- **Who is who.** WhatsApp addresses a person by phone (`<number>@s.whatsapp.net`)
  or by LID (`<id>@lid`), and may switch. The peer is the phone number when it is
  known from the address, from its twin address in the same message, or from what
  the account learned earlier (a local lookup that sends nothing to WhatsApp), and
  `lid:<id>` otherwise, so one person is one peer whichever address is used; the
  chat to answer is the matching address. The one edge: someone paired while only
  their LID was known, whose number is learned later, appears under the number and
  pairs again. Device and agent suffixes are dropped.
- **Reply-only.** Nothing is sent to a chat that did not write first: the hub sends
  only to paired people, and a person pairs by writing the code. A stranger is never
  answered, told they are refused, or sent a read receipt (the unread message of a
  chat is marked read just before the Dot answers that chat, from a bounded memory),
  so no stranger learns that the number is alive. Each send is preceded by a typing
  indicator and a pause of 0.4 to 1.5 seconds. The account does not announce itself
  online. No groups (WhatsApp is told to ignore every address that is not one
  person's, so those messages are neither decrypted nor seen), no broadcast, no
  channel posts, no messages the account wrote itself, no attachments (a paired
  person is told "not supported yet", as on Telegram). There is no way to send to a
  number that has not written.
- **Pairing.** `pair <code>` as a whole message; the link
  `https://wa.me/<number>?text=pair%20<code>` opens the chat with exactly that
  ready to send. The number is the account the adapter reported when it connected.
- **Approvals.** In words, as described above: the prompt is a message with the
  reply to send, and when the approval is settled the prompt is edited to the
  outcome (WhatsApp limits how long a sent message can be edited, about fifteen
  minutes, so the prompt of an old approval may keep its question; a late answer is
  told it was answered already).
- **At most once on the way in.** WhatsApp confirms a message to its sender when
  it arrives, not when the hub dealt with it, so unlike Telegram a message the hub
  could not record cannot be offered again. The adapter then drops the connection,
  the channel shows `error`, the hub reconnects, and the person writes again.
  Messages come one at a time, in order.
- **Not private, and not stable.** WhatsApp and the account's other devices see
  what the Dot writes; the account's owner sees the Dot as a linked device. Baileys
  follows a protocol WhatsApp does not publish: a release of it can stop working
  without notice, and nothing here can prevent a ban.

From the CLI, `invisible-dots channel link whatsapp --dot <dot>` prints the risk,
then each code as a QR for the terminal until the number is linked, then
`channel pair whatsapp --dot <dot>` prints the link and the words that pair.

## 10. Out of scope for this version

Snapshots and rollback, remote desktop
and interactive terminal, artifacts, backups, quotas, network policies,
multiple hosts, organisations and RBAC, macOS hosts. The tables and states
above leave room for them; nothing here pretends to implement them.

Scheduled and recurring jobs are in scope: they are the Dot's automations
(sections 8.8 and 9.5), which run in its guest and, with the computer off,
start it.

## 11. Getting a host ready

The same commands on every host:

```text
invisible-dots setup --all   everything below in one run, in order, that can be run again (section 11.4)
invisible-dots setup         get QEMU and its accelerator ready (may ask for administrator rights once)
invisible-dots doctor        check everything, print one line per check and the command that fixes a failure
invisible-dots image build   build the golden image and the runtime ISO (section 3.3)
invisible-dots server        run the control plane and the web client in the foreground (section 9.7)
```

`invisible-dots server` is the one entry point of the control plane; no
other program starts it. It stops cleanly (closes the database, releases
`server.lock`) on Ctrl+C, a service manager's SIGTERM, a closed terminal
(SIGHUP, which Node also raises on Windows when the console window closes)
and Ctrl+Break on Windows (SIGBREAK): the same handler for all four.

The OpenRouter key is then stored with `invisible-dots secret openrouter`,
the same line on every host and in every shell: in a terminal it asks for the
key and reads one line, and piped it reads standard input. The key is never an
argument, so it never lands in a shell history or a process list.

### 11.1 doctor

Checks, in this order, each with `ok` / `missing` / `failed` and a fix line:
Node version; QEMU found (and its version, 8.2 or newer); `qemu-img` found;
the accelerator usable (Linux: `/dev/kvm` opens read-write; Windows: the
`HypervisorPlatform` optional feature is enabled, read without administrator
rights through `Get-CimInstance Win32_OptionalFeature`), confirmed by actually
running QEMU with `-nodefaults -no-user-config -machine q35 -accel <kvm|whpx>
-cpu host,-vmx,-svm -display none -no-reboot -boot reboot-timeout=0` and seeing it exit
with code 0; the data directory, `INVISIBLE_DOTS_HOME`, a path QEMU can be
given (plain ASCII, no comma, section 3.2) with enough free space;
the golden image and runtime ISO present and matching their manifests; the
web client built (the files `invisible-dots server` serves, section 9.7; the
fix is its build command; a row of `invisible-dots doctor` and `setup` only: the
report of `GET /api/doctor` is read in the web client, which is built by then); the OpenRouter key stored. `doctor` never changes anything and creates nothing.
Exit code 0 only when every check is `ok`. On a host invisible_dots does not
run on, the accelerator rows say so, and the report still prints.

- The probe runs guest code instead of holding the machine before its first
  instruction: the empty machine's firmware finds nothing to boot,
  `reboot-timeout=0` makes it reset at once, and `-no-reboot` turns the reset
  into QEMU exiting with code 0. So exit code 0 means the accelerator opened
  AND ran the CPU model the Dots use; there is no monitor, the same as for a
  Dot. Measured with QEMU 8.2.2 and KVM: exit 0 after 0.2 s, and the firmware's
  debug port reads "No bootable device. Retrying in 0 seconds." then
  "Rebooting."; without either flag QEMU never exits. A probe still running
  after 30 s is killed and reported as a virtual CPU that does not run, with
  QEMU's first line of error output. Not measured with WHPX yet.
- The probe uses the Dots' machine type, not `-machine none`: QEMU 11.1 with
  WHPX aborts on `-machine none` (`X86_MACHINE` assertion, measured).
- The probe has the last word: when the host-side check says `missing` but
  QEMU starts with the accelerator, the accelerator row is `ok` and `setup`
  enables nothing. Measured on Windows 11: WHPX initialised while the
  `HypervisorPlatform` feature read as disabled (Virtual Machine Platform on).
- The OpenRouter key is read from the running server's `GET /api/health`,
  because only the server may open the embedded database (section 9.1). While
  the server is down that row is `failed`, with the command that starts it.
  Inside the server (`GET /api/doctor`) the row asks the Scheduler directly.
- One code runs the report in both places: `runDoctor` in
  `apps/vm-manager/src/doctor.ts`, over the real machine's
  `hostDoctorDeps()` and the images' rows of `apps/api/src/doctor.ts`; the CLI
  only renders it (`apps/cli/src/doctor/render.ts`). The wire types
  (`DoctorCheck`, `DoctorAnswer`) are in `packages/shared/src/api.ts`.

### 11.2 setup

`setup` runs `doctor`, then fixes only what is missing:

- **Windows**: downloads the official QEMU installer for the version pinned in
  `virtualization/qemu/windows.json` (URL and SHA-256) into a temporary
  directory as the normal user, verifies the hash, then asks for elevation
  ONCE (`Start-Process -Verb RunAs` on a generated PowerShell script) to run,
  in that single elevated session: `dism /online /enable-feature
  /featurename:HypervisorPlatform /all /norestart` when the feature is off, and
  the QEMU installer silently (its arguments, `/S`, come from the pin) when
  QEMU is missing. Nothing the elevated session runs or writes is in a place
  the normal user can change, because a program running as that user could
  swap an installer between its hash check and its start, plant a DLL next to
  it, or turn the result file into a link to anywhere. So the session creates
  a new directory directly under ProgramData whose ACL, set in the same call
  that creates it, lets only Administrators and SYSTEM write (the person may
  read), and refuses to go on if it existed or is not empty; it copies the
  installer there, hashes the COPY and runs the copy from that directory; it
  finds dism through the system directory Windows reports, never through an
  environment variable the user can set; and it writes the exit codes to a
  result file in that directory, which the normal session reads and then
  removes with the directory. Exit code 3010 from dism means a restart is
  required: `setup` says so and stops with exit code 5. The person restarts
  and runs `invisible-dots doctor`. The installer's Authenticode certificate is
  outside its validity period, so the pinned hash is the only trust anchor.
- **Linux**: prints and runs `sudo apt-get install -y qemu-system-x86
  qemu-utils` on apt-based systems (and prints the equivalent `dnf` / `pacman`
  line elsewhere instead of guessing), then checks `/dev/kvm`; if it is not
  accessible it prints `sudo usermod -aG kvm $USER` and that a new login is
  needed. `setup` refuses to run as root: it would check `/dev/kvm` as root and
  name root in that line, not the person who runs the server. It calls `sudo`
  itself for the one step that needs it, as Windows elevates its one step.
- The minimum of section 3.1 is 8.2 because Ubuntu 24.04's own
  `qemu-system-x86` is 8.2.2, so `setup` on the most common LTS installs a QEMU
  that `doctor` accepts; 8.2.2 was measured against the argv of section 3.4
  and the probe of section 11.1 (with KVM). Debian 13 ships 10.0.

The project never redistributes QEMU binaries: Windows gets the official
installer, Linux gets the distribution's package.

### 11.3 Licensing

The root LICENSE (MIT) covers this repository, except everything under
`invisible_engine_dots/`, which is under `invisible_engine_dots/LICENSE` (MIT) and the
nested notices next to the code they cover; `THIRD_PARTY_NOTICES.md` at the
root carries that license, the notices of the earlier TypeScript engine whose
text the history still holds (Open Multi-Agent, MIT), and names every nested
notice, and `invisible_engine_dots/UPSTREAM.md` records the version and commit
the fork comes from. The engine's source goes
onto the runtime disk with the fork's `LICENSE` and `UPSTREAM.md`
(`/opt/invisible-dots/engine/`). No list is written by hand, so it cannot
drift from the lockfile. QEMU (GPL-2.0) is installed
from the official Windows installer or the distribution's package and is only
ever run as a separate program; it is never linked into, bundled with or
shipped by this project. The guest operating system (the Ubuntu cloud image),
`uv`, the browser engine, `invisible-playwright-mcp` with its Python
packages, and the Python packages the engine's lock
(`guest/image-builder/builder/engine-requirements.lock`) names are
downloaded from their publishers when the golden image is built, each under
its own license, as the wheels the publishers released. The golden image is
published as built by CI (the release `golden-<inputs digest>`, made by
`.github/workflows/golden-image.yml`; `image build` downloads it when its
inputs are the checkout's, `guest/image-builder/src/prebuilt.ts`, and builds the
image itself otherwise); the sources of its Ubuntu packages are in Ubuntu's
archive, and whoever copies it takes on the license terms of the components
inside it.

The default `npm install` holds nothing under the GPL (section 9.8, WhatsApp); that is a
statement about the npm lock file and no more. The few LGPL packages of the lock file
are the prebuilt image libraries (`@img/sharp-*`) that Next.js may install; the notices
name them. The VM image is a different thing: it carries the Ubuntu guest operating
system and the apt packages the golden image installs on it (`apt_packages` of
`guest/image-builder/pins.json`: Xvfb, XFCE and their libraries, over the Linux kernel,
bash and the rest of Ubuntu's base), most of it GPL or LGPL software under its own
licenses and source offers, downloaded from Ubuntu's archive on the machine that builds
the image, which is CI when the image is the published release of the paragraph above. Whoever copies a golden image to another
machine takes those licenses with it (the paragraph above).

### 11.4 setup --all

`invisible-dots setup --all` is what the quick start used to have the person
type after `npm ci` and the build of the command line, as one command
(`apps/cli/src/setup/all.ts`). Every step is the code of the command that
owns it, run as a function, and skips what is already done, so the same
command is also how a run that stopped is continued. In order:

1. **The guest daemon.** `go build` of `guest/dot-agentd` for linux/amd64 with
   no cgo (`agentdBuildCommand()` in the image builder, which also names where
   the runtime disk takes the binary from). It comes first because it needs
   nothing but Go: a missing Go stops the run here, with the install command of
   each host in one line (`GO_INSTALL_HINT` in `setup/build.ts`: winget on
   Windows, snap on Linux; one text, so that no platform check is added to
   section 1.1), before anything is changed. It is not skipped: Go's build
   cache makes an unchanged daemon take seconds, and the image builder turns the
   same bytes into "already built".
2. **QEMU and its accelerator.** `prepareHost()` of `setup/setup.ts`, the code
   `setup` itself runs (section 11.2), so the one elevated step (UAC on
   Windows, `sudo apt-get` on Linux) stays one step and `setup` as a command
   prints what it printed before. It comes before the long builds so that a
   restart or a new login it asks for costs nothing already done. Where it asks
   for a restart (exit code 5) or for `usermod -aG kvm`, `setup --all` says to run
   itself again and stops with `setup`'s exit code.
3. **The web client**, unless `locateWebBuild()` finds it complete: node runs
   `apps/web/scripts/build.mjs` (the script `npm run build --workspace
   @invisible-dots/web` runs; node starts it directly because npm is a `.cmd`
   file on Windows and the CLI never starts a program through a shell), its output
   on the person's terminal. Next's telemetry is off in `apps/web/next.config.ts`
   itself, so this build and any other send none.
4. **The guest images**, `image build` as it is (the runtime disk first, then
   the golden image).

A step that fails ends the run with exit code 1 and the reason, and nothing
after it is run; the message ends with the command to run again. At the end it
prints how to start the server and the address of the web client
(`INVISIBLE_DOTS_WEB_LISTEN` or its default), which has no login: the web
server adds the API token itself (section 9.7). It does not
start the server itself: `server` runs in the foreground until Ctrl+C. Ctrl+C
asks `image build` to stop (it kills its builder VM) and ends the run between
steps; a second Ctrl+C exits at once.

Not in it, on purpose: installing Node, Git and Go (the Windows installers and
snap ask for administrator rights of their own, and `setup --all` keeps to
one), the clone, `npm ci` and the build of the command line (the command is
their product), and the OpenRouter key (the web client's Home page takes it
once the server runs, or `invisible-dots secret openrouter`).
