#!/usr/bin/env bash
# The runtime ISO's install hook. cloud-init runs it as root on every boot
# (a per-boot script written by the seed), after the ISO is mounted at
# /opt/invisible-dots. It sets up the Dot's way out, brings in the browser a
# previous start staged, installs the guest units and starts them, then stages
# a newer browser in the background.
#
# The units are COPIED into /etc/systemd/system rather than linked: a linked
# unit lives on the ISO, which is not mounted yet when systemd loads units at
# early boot, so it would be "not found" on every boot after the first. They
# are not enabled: this script starts them, on every boot, after what has to
# come first. Enabled, systemd would start them at multi-user.target, and
# cloud-init's final stage, which runs this script, comes after that target
# (cloud-final.service: After=multi-user.target), so on every boot after the
# first the Dot would go out before its proxy is set and its engine would read
# a browser about to be switched. This script is also the first point of the
# boot that has the seed's config.json (written by the same final stage).
set -euo pipefail

runtime="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
units=(dot-desktop.service dot-agentd.service invisible-dots-agent.service)

log() { printf 'invisible-dots-runtime: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
id dot >/dev/null 2>&1 || die "user dot does not exist (is this a golden image?)"
id dotagentd >/dev/null 2>&1 || die "user dotagentd does not exist (a golden image from before dot-agentd had its own user): build a new golden image"
id dotengine >/dev/null 2>&1 || die "user dotengine does not exist (a golden image from before the engine had its own user)"
[ -x /opt/invisible-dots-engine/bin/python ] || die "the golden image has no engine environment (a golden image from before the nanobot engine): build a new golden image"
version="$(cat "$runtime/VERSION" 2>/dev/null || echo unknown)"
log "installing runtime $version from $runtime"

# The two sockets (architecture 4.2), each in a directory its server owns and
# only the other side may enter, setgid so the socket gets that side's group:
# /run/invisible-dots/agentd.sock, dot-agentd's (dotagentd), reached by the
# engine (group dotengine); /run/invisible-dots-agent/agent.sock, the engine's
# (dotengine), reached by dot-agentd (group dotagentd). dot, whose processes
# are the model's, is in neither group: it cannot enter either directory, so
# it cannot talk to the engine, and nothing of its can take the place of the
# socket the host pushes the key to.
# tmpfiles recreates both on every boot before the units start.
tmpfiles=/etc/tmpfiles.d/invisible-dots.conf
printf 'd /run/invisible-dots 2750 dotagentd dotengine -\nd /run/invisible-dots-agent 2750 dotengine dotagentd -\n' > "$tmpfiles.new"
mv -f "$tmpfiles.new" "$tmpfiles"
systemd-tmpfiles --create "$tmpfiles"

# The workspace is shared with the engine, which reads the Dot's memory notes
# and works in it: group dot, setgid, group-writable. The engine's own state
# (its database and its cron jobs) is closed to everyone else.
install -d -o dot -g dot -m 2775 /home/dot/workspace
install -d -o dot -g dot -m 0755 /home/dot/downloads /home/dot/documents /home/dot/memory
install -d -o dot -g dot -m 0700 /home/dot/browsers
# The home of each browser identity's MCP server (architecture 4.2), outside /home/dot on purpose: the server
# saves the proxy of its browser, password included, in a session file under its home, and the host's file
# routes read /home/dot and nothing else. dot owns it: the server runs as dot.
install -d -o root -g root -m 0755 /var/lib/invisible-dots
install -d -o dot -g dot -m 0700 /var/lib/invisible-dots/mcp
install -d -o dotengine -g dotengine -m 0700 /home/dotengine
install -d -o dotengine -g dotengine -m 0700 /home/dotengine/state

# The Dot's VM proxy (config.json "proxy", root-only, written by cloud-init from the seed): when it is set, the
# whole VM goes out through it. hev-socks5-tunnel carries TCP, UDP and DNS into the SOCKS5 proxy over tun0, and a
# small nftables table lets nothing else leave: if the tunnel is down, nothing goes out at all. Without a proxy the
# VM goes out directly, as before. The units below start after this, so the Dot's first request already uses it.
proxy_dir=/run/dot-vmproxy
if [ -n "$(python3 -c 'import json;print(json.load(open("/etc/invisible-dots/config.json")).get("proxy") or "")' 2>/dev/null)" ]; then
  install -d -o root -g root -m 0700 "$proxy_dir"
  # vmproxy.py (on this disk) writes the tunnel's settings, its routes and the firewall; when it cannot (the value is
  # not socks5://[user:password@]host:port, its host does not resolve, the VM has no default route), it says why
  # and writes nothing, and the firewall below lets nothing out.
  if ! reason=$(python3 "$runtime/vmproxy.py" /etc/invisible-dots/config.json "$proxy_dir" 2>&1); then
    log "error: the Dot's proxy cannot be set up: $reason; nothing goes out until it is fixed"
    printf 'table inet dot_vmproxy {\n chain out {\n  type filter hook output priority 0; policy drop;\n  oifname "lo" accept\n  ct state established,related accept\n  ip daddr 10.0.2.0/24 accept\n }\n}\n' > "$proxy_dir/allow.nft"
  fi
  sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  nft delete table inet dot_vmproxy 2>/dev/null || true
  nft -f "$proxy_dir/allow.nft"
  if [ -f "$proxy_dir/hev.yml" ]; then
    systemctl stop dot-vmproxy.service 2>/dev/null || true
    systemd-run --quiet --unit=dot-vmproxy --property=Restart=always --property=RestartSec=2 \
      /usr/local/bin/hev-socks5-tunnel "$proxy_dir/hev.yml"
    log "the VM goes out through its proxy"
  fi
fi

# Missing software: dot may run `sudo dot-install <package>...` (bin/dot-install, which takes package names and
# nothing else) and no other command as root. The rule is checked before it is put in place.
install -m 0755 -o root -g root "$runtime/bin/dot-install" /usr/local/sbin/dot-install
printf 'dot ALL=(root) NOPASSWD: /usr/local/sbin/dot-install\n' > /etc/sudoers.d/dot-install.new
chmod 0440 /etc/sudoers.d/dot-install.new
visudo -cqf /etc/sudoers.d/dot-install.new && mv -f /etc/sudoers.d/dot-install.new /etc/sudoers.d/dot-install

# A /run/user/<uid> for the desktop session without anyone logging in.
loginctl enable-linger dot || log "warning: could not enable lingering for dot; the desktop runs without XDG_RUNTIME_DIR"

# The Dot's browser (browser/dot-browser on this disk): the release an earlier start staged becomes the Dot's browser
# now, while nothing of it runs, and the engine started below reads what it serves. A switch is one rename: one that
# fails leaves the Dot the browser it had, and says why.
"$runtime/browser/dot-browser" switch || log "error: the staged browser could not be switched to; the Dot keeps the browser it had"

# A runtime before this one enabled the units: they would still start ahead of this script.
for unit in "${units[@]}"; do rm -f "/etc/systemd/system/multi-user.target.wants/$unit"; done

changed=()
for unit in "${units[@]}"; do
  src="$runtime/units/$unit"
  dst="/etc/systemd/system/$unit"
  [ -f "$src" ] || die "the runtime ISO has no $unit"
  if ! cmp -s "$src" "$dst"; then
    install -m 0644 "$src" "$dst.new"
    mv -f "$dst.new" "$dst"
    changed+=("$unit")
  fi
done

systemctl daemon-reload
for unit in "${units[@]}"; do
  if [[ " ${changed[*]-} " == *" $unit "* ]] && systemctl is-active --quiet "$unit"; then
    log "restarting $unit (its unit file changed)"
    systemctl restart "$unit"
  else
    # A no-op for a unit that is already running.
    systemctl start "$unit"
  fi
done
log "runtime $version installed; units: ${units[*]}"

# A newer browser, when one is published, is built beside the Dot's in the background, through the Dot's own way out
# (its proxy, when it has one, is set above): a start never waits for it, and the next start switches to it.
systemd-run --quiet --no-block --collect --unit=dot-browser-stage "$runtime/browser/dot-browser" stage
