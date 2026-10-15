/**
 * The files of this package that end up inside a guest: the builder's
 * cloud-init and provisioner, and the runtime ISO's install hook, VM proxy
 * setup, desktop script and systemd units. They are kept as plain files so they can be read,
 * diffed and checked with shell tools, and read from disk at build time.
 */
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The package directory (guest/image-builder). A bundled CLI no longer sits
 * next to these files, so it passes the directory it ships them in as
 * `assetRoot` instead.
 */
export function defaultAssetRoot(): string {
  return fileURLToPath(new URL("..", import.meta.url));
}

export const BUILDER_USER_DATA = "builder/user-data.yaml";
export const BUILDER_PROVISION = "builder/provision.sh";
/** The hashed lock of the engine's Python environment (python-lock.ts); the runtime disk carries a copy. */
export const BUILDER_ENGINE_LOCK = "builder/engine-requirements.lock";
/** Builds the engine's Python environment inside the builder VM; the same script builds it in a Linux container. */
export const BUILDER_ENGINE_BUILD = "builder/build-engine-env.sh";
export const RUNTIME_INSTALL = "runtime/install.sh";
export const RUNTIME_DESKTOP = "runtime/dot-desktop.sh";
export const RUNTIME_DOT_INSTALL = "runtime/dot-install.sh";
/** Writes the VM proxy's tunnel settings, routes and firewall; install.sh runs it when the Dot has a proxy. */
export const RUNTIME_VMPROXY = "runtime/vmproxy.py";
/**
 * The Dot's browser and where it lives (the MCP server's environment and the engine): the runtime disk carries it for
 * install.sh, which brings every Dot's browser to the newest release at its starts, and the builder seed for
 * provision.sh, which installs the golden image's with it. The browser smoke runs it too.
 */
export const RUNTIME_BROWSER = "runtime/dot-browser.sh";
/** The browsers that never enter a Dot (owner's rule): dot-browser.sh refuses them among what it installs, reading them beside it. */
export const RUNTIME_OTHER_BROWSERS = "runtime/other-browsers.txt";
/** The guest units, in the order install.sh starts them. */
export const GUEST_UNITS = ["dot-desktop.service", "dot-agentd.service", "invisible-dots-agent.service"] as const;

export function unitAsset(name: (typeof GUEST_UNITS)[number]): string {
  return `units/${name}`;
}

/** Every guest file, for checks that apply to all of them. */
export const GUEST_ASSETS: readonly string[] = [BUILDER_USER_DATA, BUILDER_PROVISION, BUILDER_ENGINE_LOCK, BUILDER_ENGINE_BUILD, RUNTIME_INSTALL, RUNTIME_DESKTOP, RUNTIME_DOT_INSTALL, RUNTIME_VMPROXY, RUNTIME_BROWSER, RUNTIME_OTHER_BROWSERS, ...GUEST_UNITS.map(unitAsset)];

/**
 * Reads a guest file and refuses one a Windows checkout turned into CRLF:
 * bash reads "#!/usr/bin/env bash\r" as a missing interpreter and systemd
 * misreads the unit, and both happen only inside the guest, long after the
 * build looked fine. Same check on every host.
 */
export async function readGuestAsset(assetRoot: string, relativePath: string): Promise<Buffer> {
  const path = join(assetRoot, relativePath);
  const bytes = await readFile(path);
  if (bytes.includes(0x0d)) {
    throw new Error(`${path} has CR line endings; guest files must be LF (check core.autocrlf and .gitattributes)`);
  }
  return bytes;
}
