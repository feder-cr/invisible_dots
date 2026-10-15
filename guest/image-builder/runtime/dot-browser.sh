#!/usr/bin/env bash
# dot-browser: the Dot's browser (architecture sections 3.3 and 6), invisible-playwright-mcp, and the one owner of where
# it lives in the guest. The Dot's browser is this server and nothing else (owner's rule), and it is the newest release:
# no version of it is written in the repository.
#
#   dot-browser install <mcp> <playwright> <core>   build that release and make it the Dot's browser (provision.sh)
#   dot-browser newest [<requirement>...]          the newest release as uv resolves invisible-playwright-mcp (with
#                                                  the requirements given, if any): "<mcp> <playwright> <core>"
#   dot-browser stage                              build the newest release beside the Dot's browser, when it is not
#                                                  that already; it becomes the Dot's browser at the next switch
#   dot-browser switch                             make the staged release the Dot's browser, and remove every other
#
# Each release is an environment of its own, browser/<mcp>-<playwright>-<core> under ~dot/.local/share/invisible-dots
# (a venv cannot move), with the browser engine its invisible-core seals, fetched into ~dot/.cache/invisible-playwright.
# The Dot's browser is the environment ~dot/.local/bin/invisible-playwright-mcp links to: the engine's unit names that
# link, starts it as dot, and reads what it serves through it when it starts. The runtime disk's install.sh runs
# `switch` at every boot before it starts the Dot's units, so the browser changes only while nothing of it runs, and
# `stage` after them, in the background, through the Dot's own way out (its proxy, when it has one): a newer release
# costs a start nothing, and the Dot uses it from the next one. Without the network a stage fails and the Dot keeps
# its browser.
#
# Run as root (provision.sh, install.sh); everything of the browser is dot's and is done as dot.
set -Eeuo pipefail

usage="usage: dot-browser install <mcp> <playwright> <core> | newest [<requirement>...] | stage | switch"
packages=(invisible-playwright-mcp invisible-playwright invisible-core)
share=/home/dot/.local/share/invisible-dots
releases=$share/browser
staged=$releases/next
# The environment the golden images built before this layout, in place of a release directory.
legacy_env=$share/mcp
command_link=/home/dot/.local/bin/invisible-playwright-mcp
other_browsers="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/other-browsers.txt"

log() { printf 'dot-browser: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
as_dot() { sudo -u dot -H env PATH="/home/dot/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

# newest [<requirement>...]: what uv installs for invisible-playwright-mcp now, wheels only, for the guest's python.
newest() {
  local resolved
  resolved="$(printf '%s\n' "${packages[0]}" "$@" | as_dot uv pip compile - --quiet --no-cache --no-header --no-annotate \
    --only-binary :all: --python /usr/bin/python3)" || die "uv could not resolve ${packages[0]} (is the index reachable?)"
  local versions=() package version
  for package in "${packages[@]}"; do
    # uv writes each name normalized (PEP 503); normalized here too, so the match does not depend on it.
    version="$(printf '%s\n' "$resolved" | awk -F'==' -v want="$package" \
      '{ name = tolower($1); gsub(/[_.]+/, "-", name); if (name == want) { print $2; exit } }')"
    [ -n "$version" ] || die "uv's resolution of ${packages[0]} has no $package"
    versions+=("$version")
  done
  printf '%s %s %s\n' "${versions[@]}"
}

# The environment of the Dot's browser, from its command's link; empty when it has none.
current_env() {
  [ -L "$command_link" ] || return 0
  dirname "$(dirname "$(readlink -f "$command_link")")"
}

# The release an environment holds, read from it: "<mcp> <playwright> <core>".
release_of() {
  as_dot "$1/bin/python" -c 'import sys, importlib.metadata as m; print(" ".join(m.version(p) for p in sys.argv[1:]))' \
    "${packages[@]}"
}

# build <directory> <mcp> <playwright> <core>: that release's environment, refused when it holds another browser, with
# the browser engine its invisible-core seals. uv resolves what the three need; wheels only, so no build script of any
# package runs, and --no-cache, so dot's home keeps no download cache.
build() {
  local env_dir=$1
  local requirements=("${packages[0]}==$2" "${packages[1]}==$3" "${packages[2]}==$4")
  [ -f "$other_browsers" ] || die "no $other_browsers"
  [ ! -e "$env_dir" ] || die "$env_dir exists already"
  as_dot mkdir -p "$(dirname "$env_dir")"
  as_dot uv venv --quiet --python /usr/bin/python3 "$env_dir"
  as_dot uv pip install --no-cache --python "$env_dir/bin/python" --only-binary :all: "${requirements[@]}"
  # What was installed, not what was asked for: no package of it may be another browser.
  local installed refused="" name
  installed="$(as_dot uv pip freeze --python "$env_dir/bin/python" | sed -n 's/^\([A-Za-z0-9._-]*\)==.*/\1/p' | tr 'A-Z_.' 'a-z--')"
  while read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    refused="$refused$(printf '%s\n' "$installed" | grep -E "^${name}(-.*)?$" || true)"
  done < "$other_browsers"
  [ -z "$refused" ] || die "another browser would enter the Dot (owner's rule): $refused"
  [ -x "$env_dir/bin/invisible-playwright" ] || die "no invisible-playwright in $env_dir/bin"
  [ -x "$env_dir/bin/invisible-playwright-mcp" ] || die "no invisible-playwright-mcp in $env_dir/bin"
  as_dot "$env_dir/bin/invisible-playwright" fetch
}

# use <directory>: that environment's server becomes the Dot's browser, in one rename.
use() {
  as_dot mkdir -p "$(dirname "$command_link")"
  as_dot ln -sfn "$1/bin/invisible-playwright-mcp" "$command_link.new"
  as_dot mv -T "$command_link.new" "$command_link"
  as_dot sh -c 'command -v invisible-playwright-mcp' >/dev/null || die "invisible-playwright-mcp is not on the PATH of dot"
}

# prune <directory>...: every release environment but these is removed, the golden image's former one included.
prune() {
  local dir keep
  for dir in "$releases"/*/ "$legacy_env/"; do
    dir=${dir%/}
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    for keep in "$@"; do [ "$dir" != "$keep" ] || continue 2; done
    as_dot rm -rf -- "$dir"
    log "removed $dir"
  done
}

install_release() {
  local env_dir="$releases/$1-$2-$3"
  build "$env_dir" "$@"
  use "$env_dir"
  prune "$env_dir"
  log "the Dot's browser is invisible-playwright-mcp $1 (invisible-playwright $2, invisible-core $3)"
}

stage() {
  local release current next="" mcp playwright core env_dir
  release="$(newest)"
  read -r mcp playwright core <<< "$release"
  current="$(current_env)"
  [ -L "$staged" ] && next="$(readlink -f "$staged")"
  if [ -n "$current" ] && [ "$(release_of "$current")" = "$release" ]; then
    # Nothing newer: a release staged before is not newer either.
    [ -z "$next" ] || as_dot rm -f "$staged"
    prune "$current"
    log "the Dot's browser is the newest release, invisible-playwright-mcp $mcp"
    return
  fi
  env_dir="$releases/$mcp-$playwright-$core"
  if [ "$next" = "$env_dir" ]; then
    log "invisible-playwright-mcp $mcp is staged already; the Dot uses it from its next start"
    return
  fi
  # What an earlier stage left (a release no longer the newest, a build that failed or stopped halfway) makes room
  # for this one; a build that fails here is removed the same way by the next stage.
  [ -z "$next" ] || as_dot rm -f "$staged"
  prune "$current"
  build "$env_dir" "$mcp" "$playwright" "$core"
  as_dot ln -sfn "$env_dir" "$staged.new"
  as_dot mv -T "$staged.new" "$staged"
  log "staged invisible-playwright-mcp $mcp (invisible-playwright $playwright, invisible-core $core); the Dot uses it from its next start"
}

switch() {
  local next
  [ -L "$staged" ] || return 0
  next="$(readlink -f "$staged")"
  # A stage links its release only once the release is whole, so this holds unless the link was made by hand.
  [ -x "$next/bin/invisible-playwright-mcp" ] || die "the staged release $next has no invisible-playwright-mcp"
  use "$next"
  as_dot rm -f "$staged"
  prune "$next"
  log "the Dot's browser is now $(basename "$next")"
}

[ "$(id -u)" -eq 0 ] || die "run it as root ($usage)"
id dot >/dev/null 2>&1 || die "user dot does not exist"
case "${1:-}" in
  install) [ $# -eq 4 ] || die "$usage"; shift; install_release "$@" ;;
  newest) shift; newest "$@" ;;
  stage) [ $# -eq 1 ] || die "$usage"; stage ;;
  switch) [ $# -eq 1 ] || die "$usage"; switch ;;
  *) die "$usage" ;;
esac
