#!/usr/bin/env bash
# Runs as root inside the builder VM, from the builder's seed disk (label
# cidata), which also carries pins.env and the pinned downloads. Installs
# everything the golden image carries (architecture section 3.3), then wipes
# the instance state so every Dot boots as a fresh cloud-init instance, and
# powers off.
#
# The serial console is the host's only view of the build. Three kinds of
# lines go there and nowhere else, so each appears once:
#   idots-build: <step>                  progress, shown by `invisible-dots image build`
#   IDOTS-BUILD-COMPONENT: <name>=<v>    what was actually installed, copied into the manifest
#   IDOTS-BUILD-RESULT: ok | failed ...  the verdict the host waits for
set -Eeuo pipefail

payload="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$payload/pins.env"

console() {
  printf '%s\n' "$*" >/dev/ttyS0 2>/dev/null || printf '%s\n' "$*"
}
step() { console "idots-build: $*"; }
component() { console "IDOTS-BUILD-COMPONENT: $1=$2"; }
on_error() {
  console "IDOTS-BUILD-RESULT: failed at line $1: $2"
  systemctl --no-block poweroff
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

step "installing packages from the Ubuntu archive as of $APT_SNAPSHOT: $APT_PACKAGES"
# The cloud image may still be running its own apt jobs at first boot: wait for the lock.
apt_wait=(-o DPkg::Lock::Timeout=600)
# The packages and every dependency come from the archive as it was at the pinned moment (snapshot.ubuntu.com,
# which apt reaches for the archive this image is configured with), not as it is on the day of the build: the same
# pins make the same image. --error-on=any: a list that cannot be fetched fails the build instead of leaving apt
# with whatever lists the cloud image had.
apt_snapshot=(--snapshot "$APT_SNAPSHOT")
apt-get "${apt_wait[@]}" "${apt_snapshot[@]}" --error-on=any update
# shellcheck disable=SC2086
# unsafe-io: no fsync per package, the builder VM is thrown away if the build fails anyway.
apt-get "${apt_wait[@]}" "${apt_snapshot[@]}" -o Dpkg::Options::=--force-unsafe-io install -y --no-install-recommends $APT_PACKAGES

step "removing what a Dot never uses"
# Services of the cloud image that would run in every Dot for nothing: snaps, automatic upgrades (apt in the
# background of each Dot), crash reports, the LXD stubs, Ubuntu Pro, release upgrades, an SSH server nobody logs
# into, and pollinate, which at the first boot of every machine (so of every Dot) tells Canonical's entropy server
# the system's version, its cloud and its processor. Nothing in a Dot reports on it. Purged one by one without
# --auto-remove, so nothing else goes with them.
for package in snapd unattended-upgrades apport apport-core-dump-handler lxd-installer lxd-agent-loader \
  ubuntu-pro-client ubuntu-release-upgrader-core openssh-server pollinate; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
    apt-get "${apt_wait[@]}" purge -y "$package"
  fi
done
rm -rf /snap /var/snap /var/lib/snapd
# apt's own timers refresh the package lists twice a day in the background of every Dot and hold its lock; the
# packages of a Dot change with a new golden image, and `dot-install` refreshes the lists itself when it runs.
systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service

step "installing uv $UV_VERSION"
uv_tmp="$(mktemp -d)"
tar -xzf "$payload/$UV_TARBALL" -C "$uv_tmp"
install -m 0755 "$uv_tmp"/uv-x86_64-unknown-linux-gnu/uv "$uv_tmp"/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/
rm -rf "$uv_tmp"
/usr/local/bin/uv --version

step "installing hev-socks5-tunnel $TUNNEL_VERSION (the VM proxy's tunnel)"
# Root's and run by root only, from the runtime's install.sh, when the Dot has a VM proxy.
install -m 0755 "$payload/$TUNNEL_BINARY" /usr/local/bin/hev-socks5-tunnel

id dot >/dev/null 2>&1 || useradd --create-home --shell /bin/bash dot
# The computer daemon's user comes from the builder seed's user list like the engine's (architecture 4.1): an
# image without it would fail at every boot, so it fails the build.
id dotagentd >/dev/null 2>&1 || { console "the builder seed made no user dotagentd"; false; }

step "installing invisible-playwright-mcp $MCP_VERSION (invisible-playwright $PLAYWRIGHT_VERSION, invisible-core $CORE_VERSION), fetching the browser engine"
# The release is the newest on the index when the host started the build (browser-release.ts): the three versions
# that make it up are installed exactly, and uv resolves what they need. The seed carries the runtime disk's
# dot-browser, the one owner of where the Dot's browser lives (section 3.3), which every Dot runs at its starts to
# bring its browser to the newest release; it builds the environment as dot, refuses any other browser among what it
# installed, and fetches the engine with the invisible-playwright of that environment, so the cached engine is the
# one the server's seal expects, in ~dot/.cache/invisible-playwright.
as_dot() { sudo -u dot -H env PATH="/home/dot/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
bash "$payload/$BROWSER" install "$MCP_VERSION" "$PLAYWRIGHT_VERSION" "$CORE_VERSION"
mcp_env="$(dirname "$(dirname "$(readlink -f /home/dot/.local/bin/invisible-playwright-mcp)")")"
# What the environment holds, read from it: the manifest records what was installed, not what was asked for.
installed_version() { as_dot "$mcp_env/bin/python" -c 'import sys, importlib.metadata as m; print(m.version(sys.argv[1]))' "$1"; }
# The engine the image carries is read from the library that decides it (the seal of invisible_core: tag,
# Firefox version, BuildID), the same facts `invisible-playwright version` prints in its engine line.
engine_version="$(as_dot "$mcp_env/bin/python" -c 'from invisible_core import BINARY_VERSION, FIREFOX_UPSTREAM_VERSION; from invisible_core.constants import BUILD_ID; print(f"{BINARY_VERSION}  Firefox {FIREFOX_UPSTREAM_VERSION}  build {BUILD_ID}")')"
[ -n "$engine_version" ] || { console "invisible_core named no engine"; false; }

step "installing the engine's Python environment"
# The engine's third-party dependencies come from the hashed lock on the seed,
# wheels only, so no build script of any of them runs as root. The engine's own
# source is not here: it comes on the runtime disk and joins this environment
# through the .pth file the script writes (section 3.3).
engine_venv=/opt/invisible-dots-engine
bash "$payload/$ENGINE_BUILD" "$payload/$ENGINE_LOCK" "$engine_venv" /opt/invisible-dots/engine
engine_python="$("$engine_venv/bin/python" -V)"

step "preparing the dot home"
# The workspace is shared with the engine (user dotengine, in group dot).
install -d -o dot -g dot -m 2775 /home/dot/workspace
install -d -o dot -g dot -m 0755 /home/dot/downloads /home/dot/documents /home/dot/memory
install -d -o dotengine -g dotengine -m 0700 /home/dotengine
install -d -o dot -g dot -m 0700 /home/dot/browsers
# The home of each browser identity's MCP server (architecture 4.2). It is outside /home/dot on purpose: the
# server saves the proxy of its browser, password included, in a session file under its home, and the
# host's file routes read /home/dot and nothing else. dot owns it: the server runs as dot.
install -d -o root -g root -m 0755 /var/lib/invisible-dots
install -d -o dot -g dot -m 0700 /var/lib/invisible-dots/mcp

step "recording installed versions"
# shellcheck source=/dev/null
. /etc/os-release
component ubuntu "$VERSION_ID"
component kernel "$(uname -r)"
component uv "$(/usr/local/bin/uv --version)"
component hev-socks5-tunnel "$TUNNEL_VERSION"
component invisible-playwright-mcp "$(installed_version invisible-playwright-mcp)"
component invisible-playwright "$(installed_version invisible-playwright)"
component invisible-core "$(installed_version invisible-core)"
component browser-engine "$engine_version"
component engine-python "$engine_python"

step "cleaning up"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /etc/ssh/ssh_host_*
# The builder seed grants dot nothing, but the cloud image's own defaults
# may have written sudo rules: a Dot's seed appends its single poweroff rule
# to this file, so whatever is left here would still apply in every Dot.
rm -f /etc/sudoers.d/90-cloud-init-users
# --machine-id leaves /etc/machine-id "uninitialized", which is the
# truncation systemd expects: each Dot generates its own id on first boot.
cloud-init clean --logs --machine-id --seed
# Zeroed free blocks keep the converted qcow2 small.
fstrim -av || true
sync

trap - ERR
console "IDOTS-BUILD-RESULT: ok"
systemctl --no-block poweroff
