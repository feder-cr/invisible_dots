import { copyFile, readdir, readFile, rm, stat, writeFile, mkdir } from "node:fs/promises";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { hostPaths, type HostPaths } from "@invisible-dots/shared";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { RUNTIME_BROWSER, BUILDER_ENGINE_BUILD, BUILDER_ENGINE_LOCK, RUNTIME_OTHER_BROWSERS, BUILDER_PROVISION, BUILDER_USER_DATA, defaultAssetRoot } from "../src/assets.js";
import type { BrowserRelease } from "../src/browser-release.js";
import { buildGoldenImage, GOLDEN_DEFAULTS, GoldenBuildError, type GoldenBuildOptions } from "../src/golden.js";
import { readManifest, verifyImage, type GoldenManifest } from "../src/manifest.js";
import type { BaseImagePin, GuestPins } from "../src/pins.js";
import { fakeRunner, type VmScript } from "./fake-runner.js";
import { sha256, startFakeHttp, type FakeHttp } from "./http-fixture.js";

const BASE = Buffer.from("QFI\xfb pretend qcow2 cloud image ".repeat(4000), "latin1");
const UV = Buffer.from("uv tarball ".repeat(1000));
const TUNNEL = Buffer.from("tunnel binary ".repeat(1000));
const UV_FILE = "uv-x86_64-unknown-linux-gnu.tar.gz";
const TUNNEL_FILE = "hev-socks5-tunnel-linux-x86_64";
/** The release the builds below install, as browser-release.ts would read it off the index. */
const BROWSER: BrowserRelease = { mcp: "0.72.2", playwright: "0.35.8", core: "47.39.0" };

const OK_CONSOLE = [
  "[    0.000000] Linux version 6.8.0",
  "idots-build: installing packages: xvfb",
  "idots-build: installing uv 0.12.22",
  "IDOTS-BUILD-COMPONENT: uv=uv 0.12.22",
  "IDOTS-BUILD-COMPONENT: browser-engine=151.0",
  "IDOTS-BUILD-RESULT: ok",
  "[  300.1] reboot: Power down",
];

let http: FakeHttp;
let home: string;
let paths: HostPaths;
let base: BaseImagePin;
let pins: GuestPins;
let logs: string[];

beforeEach(async () => {
  http = await startFakeHttp({
    "/noble/base.img": { body: BASE },
    "/noble/SHA256SUMS": { body: `${sha256(BASE)} *base.img\n` },
    [`/uv/${UV_FILE}`]: { body: UV },
    [`/tunnel/${TUNNEL_FILE}`]: { body: TUNNEL },
    [`/uv/${UV_FILE}.sha256`]: { body: `${sha256(UV)} *${UV_FILE}\n` },
  });
  home = mkdtempSync(join(tmpdir(), "idots-golden-"));
  paths = hostPaths({ INVISIBLE_DOTS_HOME: home });
  base = {
    name: "ubuntu-24.04-minimal-cloudimg-amd64",
    release: "24.04",
    serial: "20260926",
    url: http.url("/noble/base.img"),
    sha256sums_url: http.url("/noble/SHA256SUMS"),
    sha256sums_entry: "base.img",
    sha256: sha256(BASE),
    local_name: "noble-minimal-cloudimg-amd64.img",
  };
  pins = {
    uv: { version: "0.12.22", url: http.url(`/uv/${UV_FILE}`), shasums_url: http.url(`/uv/${UV_FILE}.sha256`), shasums_entry: UV_FILE, sha256: sha256(UV) },
    tunnel: { version: "2.18.0", url: http.url(`/tunnel/${TUNNEL_FILE}`), sha256: sha256(TUNNEL) },
    apt_snapshot: "20261010T000000Z",
    apt_packages: ["xvfb", "imagemagick"],
  };
  logs = [];
});

afterEach(async () => {
  await http.close();
  await rm(home, { recursive: true, force: true });
});

function options(script: VmScript, extra: Partial<GoldenBuildOptions> = {}) {
  const runner = fakeRunner(script);
  const opts: GoldenBuildOptions = {
    qemu: { system: "/opt/qemu/qemu-system-x86_64", img: "/opt/qemu/qemu-img" },
    accelerator: "kvm",
    runner,
    paths,
    base,
    pins,
    download: { attempts: 1, retryDelayMs: 0 },
    log: (line) => logs.push(line),
    now: () => new Date("2026-10-02T12:34:56Z"),
    serialPollMs: 5,
    // A prebuilt image is looked for in the release of these inputs on GitHub; these tests build.
    prebuilt: false,
    browser: BROWSER,
    ...extra,
  };
  return { runner, opts };
}

describe("buildGoldenImage", () => {
  it("downloads, provisions and writes a read-only golden image with its manifest", async () => {
    const { runner, opts } = options({ console: OK_CONSOLE, exit: 0 });
    let seedSize = 0;
    runner.onSpawn = async (args) => {
      // The seed is the builder's one read-only ISO drive; the system disk is a virtio drive too, but qcow2.
      const seed = args.find((arg) => arg.startsWith("if=virtio,file=") && arg.endsWith(",format=raw,readonly=on"))!.replace(/^if=virtio,file=/, "").replace(/,format=raw,readonly=on$/, "");
      seedSize = (await stat(seed)).size;
    };
    const result = await buildGoldenImage(opts);

    expect(result.created).toBe(true);
    expect(result.version).toMatch(/^20261002123456-[0-9a-f]{12}$/);
    expect(result.image).toBe(paths.goldenImagePath(result.version));

    // qemu-img grew a copy of the verified base image, then converted the provisioned disk.
    expect(runner.runs.map((r) => [r.command, r.args[0]])).toEqual([
      ["/opt/qemu/qemu-img", "resize"],
      ["/opt/qemu/qemu-img", "convert"],
    ]);
    expect(runner.runs[0]!.args).toEqual(["resize", "-q", "-f", "qcow2", expect.stringMatching(/disk\.qcow2$/), "10G"]);
    expect(runner.spawns).toHaveLength(1);
    expect(runner.spawns[0]!.command).toBe("/opt/qemu/qemu-system-x86_64");
    expect(runner.spawns[0]!.args).toEqual(
      expect.arrayContaining(["-accel", "kvm", "-cpu", "host,-vmx,-svm", "-m", String(GOLDEN_DEFAULTS.memoryMib), "-smp", String(GOLDEN_DEFAULTS.cpus)]),
    );
    // The seed carried the pinned downloads.
    expect(seedSize).toBeGreaterThan(UV.length + TUNNEL.length);

    expect(await readFile(result.image)).toEqual(BASE);
    expect((await stat(result.image)).mode & 0o222).toBe(0);
    const manifest = (await readManifest(result.manifest)) as GoldenManifest;
    expect(manifest).toMatchObject({
      kind: "golden",
      version: result.version,
      file: `golden-${result.version}.qcow2`,
      sha256: sha256(BASE),
      size_bytes: BASE.length,
      virtual_size: "10G",
      built_at: "2026-10-02T12:34:56.000Z",
      base: { sha256: sha256(BASE), serial: "20260926" },
      pinned: {
        uv: { version: "0.12.22", sha256: sha256(UV) },
        "invisible-playwright-mcp": "0.72.2",
        "invisible-playwright": "0.35.8",
        "invisible-core": "47.39.0",
        apt_snapshot: "20261010T000000Z",
        apt_packages: ["xvfb", "imagemagick"],
      },
      // The engine's lock, which the runtime disk's copy must equal.
      engine: { lock_sha256: sha256(await readFile(join(defaultAssetRoot(), BUILDER_ENGINE_LOCK))) },
      installed: { uv: "uv 0.12.22", "browser-engine": "151.0" },
      builder: { accelerator: "kvm" },
    });
    expect(result.version.endsWith(manifest.inputs_digest)).toBe(true);
    expect(await verifyImage(result.image)).toMatchObject({ ok: true });

    // The guest's progress reached the person; the work directory and the lock are gone.
    expect(logs).toEqual(expect.arrayContaining(["guest: installing packages: xvfb", "guest: installing uv 0.12.22"]));
    expect((await readdir(paths.imagesDir)).sort()).toEqual(
      [".cache", "noble-minimal-cloudimg-amd64.img", `golden-${result.version}.json`, `golden-${result.version}.qcow2`].sort(),
    );
    expect((await readdir(join(paths.imagesDir, ".cache"))).sort()).toEqual([TUNNEL_FILE, UV_FILE].sort());
  });

  it("does nothing when an image for the same inputs exists", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    const requests = http.requests.length;
    const { runner, opts } = options({ console: OK_CONSOLE, exit: 0 }, { now: () => new Date("2026-11-01T00:00:00Z") });
    const second = await buildGoldenImage(opts);
    expect(second).toEqual({ ...first, created: false });
    expect(runner.spawns).toHaveLength(0);
    expect(http.requests.length).toBe(requests);
  });

  it("builds a new version when an input changes", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    const second = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }, { diskSize: "12G" }).opts);
    expect(second.created).toBe(true);
    expect(second.version).not.toBe(first.version);
  });

  /** A copy of the guest files the digest reads, for a test that changes one of them. */
  async function assetCopy(): Promise<string> {
    const assetRoot = join(home, "assets");
    for (const relative of [BUILDER_USER_DATA, BUILDER_PROVISION, BUILDER_ENGINE_LOCK, BUILDER_ENGINE_BUILD, RUNTIME_BROWSER, RUNTIME_OTHER_BROWSERS]) {
      await mkdir(join(assetRoot, dirname(relative)), { recursive: true });
      await copyFile(join(defaultAssetRoot(), relative), join(assetRoot, relative));
    }
    return assetRoot;
  }

  it("builds a new version when only the engine's lock changes, and records the new lock", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    const assetRoot = await assetCopy();
    const lockPath = join(assetRoot, BUILDER_ENGINE_LOCK);
    const lock = await readFile(lockPath, "utf8");
    const hash = /--hash=sha256:([0-9a-f]{64})/.exec(lock.slice(lock.indexOf("\naiohttp==")))![1]!;
    await writeFile(lockPath, lock.replace(hash, "0".repeat(64)));

    const second = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }, { assetRoot }).opts);
    expect(second.created).toBe(true);
    expect(second.version).not.toBe(first.version);
    const manifest = (await readManifest(second.manifest)) as GoldenManifest;
    expect(manifest.engine).toEqual({ lock_sha256: sha256(Buffer.from(await readFile(lockPath))) });
  });

  it("builds a new version when only the script that builds the engine's environment changes", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    const assetRoot = await assetCopy();
    const scriptPath = join(assetRoot, BUILDER_ENGINE_BUILD);
    await writeFile(scriptPath, `${await readFile(scriptPath, "utf8")}# changed\n`);

    const second = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }, { assetRoot }).opts);
    expect(second.created).toBe(true);
    expect(second.version).not.toBe(first.version);
  });

  it("builds a new version when only the script that installs the browser changes", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    const assetRoot = await assetCopy();
    const scriptPath = join(assetRoot, RUNTIME_BROWSER);
    await writeFile(scriptPath, `${await readFile(scriptPath, "utf8")}# changed\n`);

    const second = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }, { assetRoot }).opts);
    expect(second.created).toBe(true);
    expect(second.version).not.toBe(first.version);
  });

  it("builds a new version when only the list of browsers the image refuses changes", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    const assetRoot = await assetCopy();
    const listPath = join(assetRoot, RUNTIME_OTHER_BROWSERS);
    await writeFile(listPath, `${await readFile(listPath, "utf8")}servo\n`);

    const second = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }, { assetRoot }).opts);
    expect(second.created).toBe(true);
    expect(second.version).not.toBe(first.version);
  });

  it("refuses an engine lock with a requirement that has no hash, before booting anything", async () => {
    const assetRoot = await assetCopy();
    const lockPath = join(assetRoot, BUILDER_ENGINE_LOCK);
    await writeFile(lockPath, `${await readFile(lockPath, "utf8")}idna==3.20\n`);

    const { runner, opts } = options({ console: OK_CONSOLE, exit: 0 }, { assetRoot });
    await expect(buildGoldenImage(opts)).rejects.toThrow(/engine-requirements\.lock:\d+: expected/);
    expect(runner.spawns).toHaveLength(0);
  });

  it("builds a new image when a new release of the browser is published, and records that release", async () => {
    const first = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts);
    // Everything the same but the newest invisible-playwright on the index: an image of the last release is not reused.
    const next: BrowserRelease = { ...BROWSER, playwright: "0.35.9", core: "47.40.0" };

    const second = await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }, { browser: next }).opts);

    expect(second.created).toBe(true);
    expect(second.version).not.toBe(first.version);
    const manifest = (await readManifest(second.manifest)) as GoldenManifest;
    expect(manifest.pinned).toMatchObject({ "invisible-playwright-mcp": "0.72.2", "invisible-playwright": "0.35.9", "invisible-core": "47.40.0" });
    expect(logs).toContain("the browser: invisible-playwright-mcp 0.72.2 (invisible-playwright 0.35.9, invisible-core 47.40.0)");
  });

  it("fails with the provisioner's reason and keeps the work directory", async () => {
    const { opts } = options({ console: ["idots-build: installing packages", "IDOTS-BUILD-RESULT: failed at line 37: apt-get install"], exit: 0 });
    const error = (await buildGoldenImage(opts).catch((e: unknown) => e)) as GoldenBuildError;
    expect(error).toBeInstanceOf(GoldenBuildError);
    expect(error.message).toMatch(/provisioning failed inside the builder VM: failed at line 37: apt-get install/);
    expect(error.workDir).toBeDefined();
    expect(await readFile(join(error.workDir!, "serial.log"), "utf8")).toContain("IDOTS-BUILD-RESULT: failed");
    expect((await readdir(paths.imagesDir)).filter((name) => name.startsWith("golden-"))).toEqual([]);
    expect(await readdir(paths.imagesDir)).not.toContain(".golden-build.lock");
  });

  it("kills a builder VM that does not power off in time", async () => {
    const { runner, opts } = options({ console: ["idots-build: fetching the browser engine"], exit: "hang" }, { timeoutMs: 200 });
    await expect(buildGoldenImage(opts)).rejects.toThrow(/did not power off within 200 ms; last console lines:\nidots-build: fetching the browser engine/);
    expect(runner.kills).toEqual(["SIGKILL"]);
  });

  it("kills the builder VM when the build is cancelled", async () => {
    const controller = new AbortController();
    const { runner, opts } = options({ console: [], exit: "hang" }, { signal: controller.signal });
    runner.onSpawn = async () => {
      setTimeout(() => controller.abort(), 20);
    };
    await expect(buildGoldenImage(opts)).rejects.toThrow(/the build was cancelled/);
    expect(runner.kills).toEqual(["SIGKILL"]);
  });

  it("reports QEMU's own error and points at doctor when it exits non-zero", async () => {
    const { opts } = options({ console: [], exit: 1, stderr: "qemu-system-x86_64: -accel kvm: Could not access KVM kernel module: Permission denied" });
    await expect(buildGoldenImage(opts)).rejects.toThrow(/exited with status 1: .*Permission denied\n.*invisible-dots doctor/);
  });

  it("refuses to run next to another build of the same directory", async () => {
    await mkdir(paths.imagesDir, { recursive: true });
    // The process that started this test is certainly alive, and it is not this one.
    await writeFile(join(paths.imagesDir, ".golden-build.lock"), `${process.ppid}\n`);
    await expect(buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts)).rejects.toThrow(
      /another golden image build is running .*remove .*\.golden-build\.lock/,
    );
  });

  it("records its builder VM in the lock while it runs, and runs it in the work directory", async () => {
    const lockPath = join(paths.imagesDir, ".golden-build.lock");
    const { opts, runner } = options({ console: OK_CONSOLE, exit: 0 });
    let recorded: { pid?: number; child?: number } = {};
    runner.onSpawn = async () => {
      // The VM "boots" only once the lock names it, as the next build will read it.
      const deadline = Date.now() + 10_000;
      for (;;) {
        // On Windows a read that meets the lock's rename-over fails for a
        // moment (ENOENT or EPERM); the next poll reads the new record.
        recorded = await readFile(lockPath, "utf8").then((text) => JSON.parse(text) as typeof recorded, () => recorded);
        if (recorded.child !== undefined || Date.now() > deadline) break;
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
    };
    expect((await buildGoldenImage(opts)).created).toBe(true);
    expect(recorded).toMatchObject({ pid: process.pid, child: 4242 });
    expect(runner.spawns[0]!.cwd).toMatch(/\.golden-.*\.work$/);
  });

  it("refuses to take over from a build that died while its builder VM still runs", async () => {
    await mkdir(paths.imagesDir, { recursive: true });
    // The build (a pid that does not exist) is gone; its QEMU (this live process) is not.
    await writeFile(join(paths.imagesDir, ".golden-build.lock"), `${JSON.stringify({ pid: 999999999, child: process.ppid })}\n`);
    await expect(buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts)).rejects.toThrow(
      new RegExp(`the process it started \\(pid ${process.ppid}\\) still runs`),
    );
  });

  it("takes over a lock left by a process that no longer exists", async () => {
    await mkdir(paths.imagesDir, { recursive: true });
    await writeFile(join(paths.imagesDir, ".golden-build.lock"), "999999999\n");
    expect((await buildGoldenImage(options({ console: OK_CONSOLE, exit: 0 }).opts)).created).toBe(true);
  });
});
