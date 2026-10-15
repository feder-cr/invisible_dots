/**
 * Builds `golden-<version>.qcow2` (architecture section 3.3) the same way on
 * every host: Node downloads and verifies the inputs, packages/iso writes
 * the seed, and the QEMU the host runs Dots with boots the Ubuntu cloud
 * image once to provision it.
 */
import { createHash } from "node:crypto";
import { chmod, copyFile, mkdir, readFile, rm, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { writeIso } from "@invisible-dots/iso";
import { hostPaths, type HostPaths } from "@invisible-dots/shared";
import { BUILDER_ENGINE_BUILD, BUILDER_ENGINE_LOCK, BUILDER_PROVISION, BUILDER_USER_DATA, defaultAssetRoot, readGuestAsset, RUNTIME_BROWSER, RUNTIME_OTHER_BROWSERS } from "./assets.js";
import { latestBrowserRelease, type BrowserRelease } from "./browser-release.js";
import { fetchVerified, sha256File, type Fetch, type FetchVerifiedOptions } from "./download.js";
import { acquireLock, type Lock } from "./lock.js";
import { manifestPathFor, type GoldenManifest } from "./manifest.js";
import { BASE_IMAGE, downloadFileName, GUEST_PINS, type BaseImagePin, type GuestPins, type PinnedDownload } from "./pins.js";
import { waitForExit, type ProcessRunner } from "./process.js";
import { PREBUILT_RELEASES, pullPrebuiltGolden } from "./prebuilt.js";
import { parseHashedLock } from "./python-lock.js";
import { builderQemuArgs, type Accelerator, type QemuPrograms } from "./qemu.js";
import { SEED_VOLUME_ID } from "@invisible-dots/vm-manager";
import { builderSeedEntries } from "./seed.js";
import { buildVerdict, followSerialLog, installedComponents } from "./serial.js";
import { inputsDigest } from "./versions.js";
import { publishImage, resolveImageVersion } from "./publish.js";

export const GOLDEN_DEFAULTS = {
  /** Each Dot's overlay is larger; cloud-init grows the filesystem when a Dot boots. */
  diskSize: "10G",
  cpus: 2,
  memoryMib: 4096,
  /** apt, the Python environments, the browser engine download and a cold cache on a slow line. */
  timeoutMs: 2 * 60 * 60 * 1000,
} as const;

/** qemu-img convert of a multi-GiB disk; generous because a slow disk is not an error. */
const CONVERT_TIMEOUT_MS = 30 * 60 * 1000;

export interface GoldenBuildOptions {
  /** Absolute paths of qemu-system-x86_64 and qemu-img, from the vm-manager's discovery. */
  qemu: QemuPrograms;
  /** From the vm-manager's accelerator(); there is no software emulation fallback. */
  accelerator: Accelerator;
  runner: ProcessRunner;
  paths?: HostPaths;
  /** Default `<UTC time>-<inputs digest>`; an explicit version is used as given. */
  version?: string;
  /** Size passed to qemu-img resize, e.g. "10G". */
  diskSize?: string;
  cpus?: number;
  memoryMib?: number;
  /** How long the builder VM may run before it is killed. */
  timeoutMs?: number;
  base?: BaseImagePin;
  pins?: GuestPins;
  assetRoot?: string;
  fetch?: Fetch;
  download?: Pick<FetchVerifiedOptions, "attempts" | "retryDelayMs" | "idleTimeoutMs">;
  log?: (line: string) => void;
  now?: () => Date;
  /** How often the serial log is read for progress. */
  serialPollMs?: number;
  /** Aborting kills the builder VM and fails the build. */
  signal?: AbortSignal;
  /**
   * Where the prebuilt golden images are released (prebuilt.ts), `PREBUILT_RELEASES` by default; false builds the
   * image here without looking for one. Only a build of the default version looks: an explicit version is built.
   */
  prebuilt?: string | false;
  /** Write the image as a compressed qcow2 (smaller to publish; QEMU reads it as it is). */
  compress?: boolean;
  /** The release of the Dot's browser the image installs; the newest on the package index by default (browser-release.ts). */
  browser?: BrowserRelease;
}

export interface GoldenBuildResult {
  version: string;
  image: string;
  manifest: string;
  /** False when an image for the same inputs already existed and nothing was built. */
  created: boolean;
}

export class GoldenBuildError extends Error {
  /** The kept work directory with the disk and the serial log, when there is one. */
  readonly workDir: string | undefined;
  constructor(message: string, workDir?: string, options?: { cause?: unknown }) {
    super(workDir ? `${message}\nthe work directory with the serial log is kept at ${workDir}` : message, options);
    this.name = "GoldenBuildError";
    this.workDir = workDir;
  }
}

export async function buildGoldenImage(options: GoldenBuildOptions): Promise<GoldenBuildResult> {
  const log = options.log ?? (() => undefined);
  const paths = options.paths ?? hostPaths();
  const base = options.base ?? BASE_IMAGE;
  const pins = options.pins ?? GUEST_PINS;
  const assetRoot = options.assetRoot ?? defaultAssetRoot();
  const diskSize = options.diskSize ?? GOLDEN_DEFAULTS.diskSize;
  if (!/^[1-9][0-9]*[KMGT]?$/.test(diskSize)) throw new Error(`invalid disk size "${diskSize}": use a number with an optional K, M, G or T suffix`);
  const now = options.now ?? (() => new Date());

  const userData = await readGuestAsset(assetRoot, BUILDER_USER_DATA);
  const provision = await readGuestAsset(assetRoot, BUILDER_PROVISION);
  const engineBuild = await readGuestAsset(assetRoot, BUILDER_ENGINE_BUILD);
  const browserScript = await readGuestAsset(assetRoot, RUNTIME_BROWSER);
  const otherBrowsers = await readGuestAsset(assetRoot, RUNTIME_OTHER_BROWSERS);
  const engineLock = await readGuestAsset(assetRoot, BUILDER_ENGINE_LOCK);
  parseHashedLock(engineLock.toString("utf8"), BUILDER_ENGINE_LOCK);
  // The browser is the newest release of invisible-playwright-mcp, asked of the index now: it is an input, so a new
  // release is a new image, not the image of the last one reused or downloaded under the same name.
  const browser = options.browser ?? (await latestBrowserRelease({ download: { ...options.download, log, ...(options.fetch ? { fetch: options.fetch } : {}) } }));
  log(`the browser: invisible-playwright-mcp ${browser.mcp} (invisible-playwright ${browser.playwright}, invisible-core ${browser.core})`);
  // The disk size is an input: the same pins at another size are another image.
  // The engine's lock is too, so a changed transitive dependency is another image, and
  // so are the scripts that build the engine's environment and the browser. The engine's own
  // source is not: it travels on the runtime disk (section 3.3).
  const digest = inputsDigest([JSON.stringify(base), JSON.stringify(pins), userData, provision, JSON.stringify(browser), diskSize, engineLock, engineBuild, browserScript, otherBrowsers]);

  const { version, image, manifest, existing } = await resolveImageVersion({
    kind: "golden",
    imagesDir: paths.imagesDir,
    digest,
    version: options.version,
    now,
    imagePath: (v) => paths.goldenImagePath(v),
    log,
  });
  if (existing) return { version, image, manifest, created: false };

  const lock = await acquireLock(join(paths.imagesDir, ".golden-build.lock"), "golden image build");
  try {
    if (options.version === undefined && options.prebuilt !== false) {
      const download: FetchVerifiedOptions = { ...options.download, log };
      if (options.fetch) download.fetch = options.fetch;
      const pulled = await pullPrebuiltGolden({
        releases: options.prebuilt ?? PREBUILT_RELEASES,
        digest,
        imagesDir: paths.imagesDir,
        imagePath: (pulledVersion) => paths.goldenImagePath(pulledVersion),
        manifestPath: manifestPathFor,
        download,
        log,
      });
      if (pulled) return { ...pulled, created: true };
    }
    return await buildLocked(
      { ...options, log, paths, base, pins, diskSize, now, lock },
      { version, image, manifest, digest, userData, provision, browser, engineLock, engineBuild, browserScript, otherBrowsers },
    );
  } finally {
    await lock.release();
  }
}

interface Resolved {
  /** The build lock; the builder VM's pid is recorded in it while it runs. */
  lock: Lock;
  log: (line: string) => void;
  paths: HostPaths;
  base: BaseImagePin;
  pins: GuestPins;
  diskSize: string;
  now: () => Date;
}

interface Target {
  version: string;
  image: string;
  manifest: string;
  digest: string;
  userData: Buffer;
  provision: Buffer;
  browser: BrowserRelease;
  engineLock: Buffer;
  engineBuild: Buffer;
  browserScript: Buffer;
  otherBrowsers: Buffer;
}

async function buildLocked(options: GoldenBuildOptions & Resolved, target: Target): Promise<GoldenBuildResult> {
  const { log, paths, base, pins } = options;
  const downloads: FetchVerifiedOptions = { ...options.download, log };
  if (options.fetch) downloads.fetch = options.fetch;

  log(`building golden image ${target.version}`);
  const baseImage = paths.baseImagePath(base.local_name);
  await fetchVerified({ url: base.url, sha256: base.sha256, sumsUrl: base.sha256sums_url, sumsEntry: base.sha256sums_entry }, baseImage, downloads);
  const cacheDir = join(paths.imagesDir, ".cache");
  const fetchPinned = async (pin: PinnedDownload) => {
    const dest = join(cacheDir, downloadFileName(pin));
    await fetchVerified({ url: pin.url, sha256: pin.sha256, sumsUrl: pin.shasums_url, sumsEntry: pin.shasums_entry }, dest, downloads);
    return dest;
  };
  const uvTarball = await fetchPinned(pins.uv);
  const tunnelBinary = await fetchPinned(pins.tunnel);

  // Next to the images, not in the system temp directory: the disk grows to
  // several GiB and the final rename stays on one filesystem.
  const workDir = join(paths.imagesDir, `.golden-${target.version}.work`);
  await rm(workDir, { recursive: true, force: true });
  await mkdir(workDir, { recursive: true });
  try {
    const disk = join(workDir, "disk.qcow2");
    const seed = join(workDir, "seed.iso");
    const serialLog = join(workDir, "serial.log");

    log(`copying the base image and growing it to ${options.diskSize}`);
    await copyFile(baseImage, disk);
    // The copy keeps the cache's read-only bit on Windows; QEMU must write the disk.
    await chmod(disk, 0o644);
    await options.runner.run(options.qemu.img, ["resize", "-q", "-f", "qcow2", disk, options.diskSize], { timeoutMs: CONVERT_TIMEOUT_MS });

    await writeIso(
      seed,
      builderSeedEntries({
        version: target.version,
        pins,
        userData: target.userData,
        provision: target.provision,
        browser: target.browser,
        uvTarball,
        tunnelBinary,
        engineLock: target.engineLock,
        engineBuild: target.engineBuild,
        browserScript: target.browserScript,
        otherBrowsers: target.otherBrowsers,
      }),
      { volumeId: SEED_VOLUME_ID, timestamp: options.now() },
    );

    const consoleText = await runBuilderVm(options, { disk, seed, serialLog }, workDir);
    const verdict = buildVerdict(consoleText);
    if (!verdict.ok) {
      throw new GoldenBuildError(`provisioning failed inside the builder VM: ${verdict.reason}\n${lastLines(consoleText, 30)}`, workDir);
    }
    log("provisioning finished; writing the golden image");

    const partial = `${target.image}.part`;
    await rm(partial, { force: true });
    await options.runner.run(options.qemu.img, ["convert", ...(options.compress ? ["-c"] : []), "-O", "qcow2", disk, partial], { timeoutMs: CONVERT_TIMEOUT_MS });
    const sha256 = await sha256File(partial);
    const size = (await stat(partial)).size;
    const manifest: GoldenManifest = {
      kind: "golden",
      version: target.version,
      file: basename(target.image),
      sha256,
      size_bytes: size,
      virtual_size: options.diskSize,
      built_at: options.now().toISOString(),
      inputs_digest: target.digest,
      base,
      pinned: {
        uv: { version: pins.uv.version, sha256: pins.uv.sha256, url: pins.uv.url },
        tunnel: { version: pins.tunnel.version, sha256: pins.tunnel.sha256, url: pins.tunnel.url },
        "invisible-playwright-mcp": target.browser.mcp,
        "invisible-playwright": target.browser.playwright,
        "invisible-core": target.browser.core,
        apt_snapshot: pins.apt_snapshot,
        apt_packages: [...pins.apt_packages],
      },
      engine: { lock_sha256: createHash("sha256").update(target.engineLock).digest("hex") },
      installed: installedComponents(consoleText),
      builder: { accelerator: options.accelerator },
    };
    await publishImage(partial, target.image, target.manifest, manifest);
    await rm(workDir, { recursive: true, force: true });
    log(`done: ${target.image} (sha256 ${sha256})`);
    return { version: target.version, image: target.image, manifest: target.manifest, created: true };
  } catch (error) {
    if (error instanceof GoldenBuildError) throw error;
    throw new GoldenBuildError((error as Error).message, workDir, { cause: error });
  }
}

/** Boots the builder VM, reports its progress, and returns the whole serial console once it has stopped. */
async function runBuilderVm(
  options: GoldenBuildOptions & Resolved,
  files: { disk: string; seed: string; serialLog: string },
  workDir: string,
): Promise<string> {
  const { log } = options;
  const cpus = options.cpus ?? GOLDEN_DEFAULTS.cpus;
  const memoryMib = options.memoryMib ?? GOLDEN_DEFAULTS.memoryMib;
  const timeoutMs = options.timeoutMs ?? GOLDEN_DEFAULTS.timeoutMs;
  const args = builderQemuArgs({ accelerator: options.accelerator, cpus, memoryMib, ...files });

  log(`booting the builder VM (${options.accelerator}, ${cpus} vCPU, ${memoryMib} MiB, at most ${duration(timeoutMs)}); console in ${files.serialLog}`);
  const follower = followSerialLog(files.serialLog, (step) => log(`guest: ${step}`), options.serialPollMs);
  const child = options.runner.spawn(options.qemu.system, args, { cwd: workDir });
  const exited = waitForExit(child);
  // A build killed outright (SIGKILL, the OOM killer) leaves this QEMU running
  // on Linux; the lock names it, so the next build refuses instead of
  // deleting the work directory under it.
  if (child.pid !== undefined) await options.lock.setChild(child.pid);

  let stopReason: string | undefined;
  const stop = (reason: string) => {
    stopReason ??= reason;
    child.kill("SIGKILL");
  };
  const timer = setTimeout(() => stop(`the builder VM did not power off within ${duration(timeoutMs)}`), timeoutMs);
  const onAbort = () => stop("the build was cancelled");
  if (options.signal?.aborted) onAbort();
  options.signal?.addEventListener("abort", onAbort, { once: true });

  const status = await exited;
  await options.lock.setChild(null);
  clearTimeout(timer);
  options.signal?.removeEventListener("abort", onAbort);
  await follower.stop();
  const consoleText = await readFile(files.serialLog, "latin1").catch(() => "");

  if (stopReason !== undefined) {
    throw new GoldenBuildError(`${stopReason}; last console lines:\n${lastLines(consoleText, 30)}`, workDir);
  }
  if (status.error) {
    throw new GoldenBuildError(`cannot start ${options.qemu.system}: ${status.error.message}; run "invisible-dots doctor"`, workDir, { cause: status.error });
  }
  if (status.code !== 0) {
    const stderr = child.stderrTail().trim();
    throw new GoldenBuildError(
      `${basename(options.qemu.system)} exited with ${status.code === null ? `signal ${status.signal}` : `status ${status.code}`}` +
        `${stderr ? `: ${stderr}` : ""}\nif the accelerator is the problem, "invisible-dots doctor" names the fix`,
      workDir,
    );
  }
  return consoleText;
}

function duration(ms: number): string {
  if (ms < 1000) return `${ms} ms`;
  if (ms < 120_000) return `${Math.round(ms / 1000)} s`;
  return `${Math.round(ms / 60_000)} min`;
}

function lastLines(text: string, count: number): string {
  return text.split(/\r?\n/).filter((line) => line.trim() !== "").slice(-count).join("\n");
}
