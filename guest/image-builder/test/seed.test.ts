import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { writeIso } from "@invisible-dots/iso";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { RUNTIME_BROWSER, BUILDER_ENGINE_BUILD, BUILDER_ENGINE_LOCK, RUNTIME_OTHER_BROWSERS, BUILDER_PROVISION, BUILDER_USER_DATA, defaultAssetRoot, readGuestAsset } from "../src/assets.js";
import type { BrowserRelease } from "../src/browser-release.js";
import { GUEST_PINS } from "../src/pins.js";
import { SEED_VOLUME_ID } from "@invisible-dots/vm-manager";
import { builderMetaData, builderSeedEntries, pinsEnv } from "../src/seed.js";

/** The release a build resolved from the index (browser-release.ts). */
const browser: BrowserRelease = { mcp: "0.72.2", playwright: "0.35.8", core: "47.39.0" };

let dir: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "idots-seed-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

describe("pins.env", () => {
  it("carries every value provision.sh reads, single-quoted", async () => {
    const text = pinsEnv(GUEST_PINS, browser);
    expect(text).toContain(`UV_VERSION='${GUEST_PINS.uv.version}'\n`);
    expect(text).toContain("UV_TARBALL='uv-x86_64-unknown-linux-gnu.tar.gz'\n");
    // The release the build resolved, which provision.sh installs exactly.
    expect(text).toContain("MCP_VERSION='0.72.2'\n");
    expect(text).toContain("PLAYWRIGHT_VERSION='0.35.8'\n");
    expect(text).toContain("CORE_VERSION='47.39.0'\n");
    expect(text).toContain("ENGINE_LOCK='engine-requirements.lock'\n");
    expect(text).toContain("ENGINE_BUILD='build-engine-env.sh'\n");
    expect(text).toContain("BROWSER='dot-browser.sh'\n");
    expect(text).toContain(`APT_SNAPSHOT='${GUEST_PINS.apt_snapshot}'\n`);
    expect(text).toContain(`APT_PACKAGES='${GUEST_PINS.apt_packages.join(" ")}'\n`);

    const provision = (await readGuestAsset(defaultAssetRoot(), BUILDER_PROVISION)).toString("utf8");
    for (const variable of text.split("\n").filter(Boolean).map((line) => line.split("=")[0]!)) {
      expect(provision).toContain(`$${variable}`);
    }
  });

  it("refuses a value that could break out of the quotes", () => {
    expect(() => pinsEnv({ ...GUEST_PINS, apt_packages: ["xvfb", "it's"] }, browser)).toThrow(/APT_PACKAGES/);
    expect(() => pinsEnv(GUEST_PINS, { ...browser, mcp: "1.0'; rm" })).toThrow(/MCP_VERSION/);
  });
});

describe("the builder seed", () => {
  it("holds the NoCloud files, the provisioner, its pins, the pinned downloads, the engine's lock with the script that builds its environment, and the script that builds the browser with the browsers it refuses", async () => {
    const uvTarball = join(dir, "uv.tar.gz");
    await writeFile(uvTarball, "uv bytes");
    const tunnelBinary = join(dir, "hev");
    await writeFile(tunnelBinary, "hev bytes");
    const engineLock = await readGuestAsset(defaultAssetRoot(), BUILDER_ENGINE_LOCK);
    const engineBuild = await readGuestAsset(defaultAssetRoot(), BUILDER_ENGINE_BUILD);
    const browserScript = await readGuestAsset(defaultAssetRoot(), RUNTIME_BROWSER);
    const otherBrowsers = await readGuestAsset(defaultAssetRoot(), RUNTIME_OTHER_BROWSERS);
    const userData = await readGuestAsset(defaultAssetRoot(), BUILDER_USER_DATA);
    const provision = await readGuestAsset(defaultAssetRoot(), BUILDER_PROVISION);
    const entries = builderSeedEntries({
      version: "20261002120000-abc",
      pins: GUEST_PINS,
      userData,
      provision,
      browser,
      uvTarball,
      tunnelBinary,
      engineLock,
      engineBuild,
      browserScript,
      otherBrowsers,
    });

    expect(entries.map((entry) => entry.path)).toEqual([
      "user-data",
      "meta-data",
      "provision.sh",
      "pins.env",
      "uv-x86_64-unknown-linux-gnu.tar.gz",
      "hev-socks5-tunnel-linux-x86_64",
      "engine-requirements.lock",
      "build-engine-env.sh",
      "dot-browser.sh",
      "other-browsers.txt",
    ]);
    expect(entries[0]).toEqual({ path: "user-data", data: userData });
    expect(entries[4]).toEqual({ path: entries[4]!.path, file: uvTarball });
    expect(entries[5]).toEqual({ path: "hev-socks5-tunnel-linux-x86_64", file: tunnelBinary });
    expect(entries[6]).toEqual({ path: "engine-requirements.lock", data: engineLock });
    expect(entries[7]).toEqual({ path: "build-engine-env.sh", data: engineBuild });
    // The runtime disk's script: provision.sh installs the golden image's browser with the one every Dot updates its own with.
    expect(entries[8]).toEqual({ path: "dot-browser.sh", data: browserScript });
    // Beside the script on the seed, where it reads the list (dot-browser.sh).
    expect(entries[9]).toEqual({ path: "other-browsers.txt", data: otherBrowsers });

    // The real writer accepts it under the label NoCloud looks for.
    const summary = await writeIso(join(dir, "seed.iso"), entries, { volumeId: SEED_VOLUME_ID });
    expect(summary.files).toBe(10);
    const image = await readFile(join(dir, "seed.iso"));
    // Primary volume descriptor at sector 16: the label at offset 40.
    expect(image.toString("latin1", 16 * 2048 + 40, 16 * 2048 + 46)).toBe("cidata");
  });

  it("gives every build its own instance id, so cloud-init runs as on a first boot", () => {
    expect(builderMetaData("v1")).toBe("instance-id: idots-golden-v1\nlocal-hostname: idots-golden-builder\n");
    expect(builderMetaData("v1")).not.toBe(builderMetaData("v2"));
  });

  it("user-data mounts that same seed by label and runs the provisioner, failing loudly", async () => {
    const userData = (await readGuestAsset(defaultAssetRoot(), BUILDER_USER_DATA)).toString("utf8");
    expect(userData.startsWith("#cloud-config\n")).toBe(true);
    expect(userData).toContain(`mount -o ro LABEL=${SEED_VOLUME_ID} /mnt/idots-build && bash /mnt/idots-build/provision.sh`);
    expect(userData).toContain("IDOTS-BUILD-RESULT: failed");
  });
});
