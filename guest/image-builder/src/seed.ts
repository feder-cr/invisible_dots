/**
 * The builder VM's seed disk. It is one ISO labelled `cidata`: cloud-init's
 * NoCloud datasource reads user-data and meta-data from it, and the
 * provisioner mounts it again to reach its own files, so the builder needs
 * this one read-only disk (a virtio disk, as every ISO of this project is
 * attached: the vm-manager's isoDriveArg) and no second payload disk.
 */
import type { IsoEntry } from "@invisible-dots/iso";
import { downloadFileName, type GuestPins } from "./pins.js";
import type { BrowserRelease } from "./browser-release.js";

/** The engine's lock and the script that builds its Python environment from it, on the builder seed. */
export const SEED_ENGINE_LOCK = "engine-requirements.lock";
export const SEED_ENGINE_BUILD = "build-engine-env.sh";
/** The runtime disk's script that installs the Dot's browser, on the builder seed (provision.sh runs it). */
export const SEED_BROWSER = "dot-browser.sh";
/** The browsers dot-browser.sh refuses, beside it on the seed, where it reads them. */
export const SEED_OTHER_BROWSERS = "other-browsers.txt";

export interface BuilderSeedInput {
  version: string;
  pins: GuestPins;
  userData: Uint8Array;
  provision: Uint8Array;
  /** The release of the Dot's browser to install (browser-release.ts). */
  browser: BrowserRelease;
  /** Host path of the verified uv tarball, streamed into the image. */
  uvTarball: string;
  /** The verified hev-socks5-tunnel binary (pins.tunnel). */
  tunnelBinary: string;
  /** builder/engine-requirements.lock and builder/build-engine-env.sh, as read. */
  engineLock: Uint8Array;
  engineBuild: Uint8Array;
  /** runtime/dot-browser.sh and runtime/other-browsers.txt, as read. */
  browserScript: Uint8Array;
  otherBrowsers: Uint8Array;
}

/**
 * pins.env is sourced by provision.sh. Every value was restricted to
 * characters that need no quoting when the pins were parsed, so single
 * quotes are only a second guard; the check below keeps it that way if a
 * caller builds GuestPins by hand.
 */
export function pinsEnv(pins: GuestPins, browser: BrowserRelease): string {
  const values: Array<[string, string]> = [
    ["UV_VERSION", pins.uv.version],
    ["UV_TARBALL", downloadFileName(pins.uv)],
    ["TUNNEL_VERSION", pins.tunnel.version],
    ["TUNNEL_BINARY", downloadFileName(pins.tunnel)],
    ["MCP_VERSION", browser.mcp],
    ["PLAYWRIGHT_VERSION", browser.playwright],
    ["CORE_VERSION", browser.core],
    ["ENGINE_LOCK", SEED_ENGINE_LOCK],
    ["ENGINE_BUILD", SEED_ENGINE_BUILD],
    ["BROWSER", SEED_BROWSER],
    ["APT_SNAPSHOT", pins.apt_snapshot],
    ["APT_PACKAGES", pins.apt_packages.join(" ")],
  ];
  return values
    .map(([key, value]) => {
      if (!/^[A-Za-z0-9.+_ -]*$/.test(value)) throw new Error(`pins.env: ${key} holds characters that are not allowed: ${value}`);
      return `${key}='${value}'\n`;
    })
    .join("");
}

export function builderMetaData(version: string): string {
  // A new instance-id per build: cloud-init then treats every build as a first boot.
  return `instance-id: idots-golden-${version}\nlocal-hostname: idots-golden-builder\n`;
}

export function builderSeedEntries(input: BuilderSeedInput): IsoEntry[] {
  return [
    { path: "user-data", data: input.userData },
    { path: "meta-data", data: builderMetaData(input.version) },
    { path: "provision.sh", data: input.provision },
    { path: "pins.env", data: pinsEnv(input.pins, input.browser) },
    { path: downloadFileName(input.pins.uv), file: input.uvTarball },
    { path: downloadFileName(input.pins.tunnel), file: input.tunnelBinary },
    { path: SEED_ENGINE_LOCK, data: input.engineLock },
    { path: SEED_ENGINE_BUILD, data: input.engineBuild },
    { path: SEED_BROWSER, data: input.browserScript },
    { path: SEED_OTHER_BROWSERS, data: input.otherBrowsers },
  ];
}
