/**
 * Builds `runtime-<version>.iso` (architecture section 3.3), volume label
 * IDOTS-RT, attached read-only to every Dot and mounted at
 * /opt/invisible-dots:
 *
 *   /install.sh                  the hook each Dot's seed runs on every boot
 *   /vmproxy.py                  install.sh's setup of the Dot's VM proxy (tunnel, routes, firewall)
 *   /VERSION                     this runtime's version
 *   /bin/dot-agentd              the computer daemon (linux/amd64)
 *   /bin/dot-desktop             ExecStart of dot-desktop.service
 *   /bin/dot-install             the package installer dot may run with sudo
 *   /engine/nanobot/...          the engine's source: its .py files and templates
 *   /engine/skills/<name>/SKILL.md   the built-in skills the prompt names and the Dot reads
 *   /engine/LICENSE, /engine/UPSTREAM.md   the engine's license and where it was forked from
 *   /units/*.service             the guest systemd units
 *
 * The engine's source is ours, so it travels here and not in the golden image
 * (architecture 3.3): a change to it is a new runtime disk. The golden image's
 * venv names /opt/invisible-dots/engine in a .pth file.
 *
 * The image has no Rock Ridge, so Linux shows every file on it as readable
 * and executable by everyone: the scripts and the daemon run without any
 * permission bits having to survive a Windows host.
 */
import { createHash } from "node:crypto";
import { open, readdir, rm, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { writeIso, type IsoEntry } from "@invisible-dots/iso";
import { hostPaths, type HostPaths } from "@invisible-dots/shared";
import { RUNTIME_ISO_LABEL } from "@invisible-dots/vm-manager";
import {
  defaultAssetRoot,
  GUEST_UNITS,
  readGuestAsset,
  RUNTIME_BROWSER,
  RUNTIME_DESKTOP,
  RUNTIME_DOT_INSTALL,
  RUNTIME_INSTALL,
  RUNTIME_OTHER_BROWSERS,
  RUNTIME_VMPROXY,
  unitAsset,
} from "./assets.js";
import { sha256File } from "./download.js";
import { acquireLock } from "./lock.js";
import type { RuntimeFile, RuntimeManifest } from "./manifest.js";
import { publishImage, resolveImageVersion } from "./publish.js";
import { inputsDigest } from "./versions.js";

export interface RuntimeInputs {
  /** guest/dot-agentd/bin/dot-agentd, built for linux/amd64 */
  agentdBinary: string;
  /** invisible_engine_dots/: the engine's source tree (nanobot/, LICENSE, UPSTREAM.md) */
  engineRoot: string;
}

/** Where `go build` puts dot-agentd in this repository, and where the engine's source is. */
export function defaultRuntimeInputs(repoRoot: string = fileURLToPath(new URL("../../..", import.meta.url))): RuntimeInputs {
  return {
    engineRoot: join(repoRoot, "invisible_engine_dots"),
    agentdBinary: join(repoRoot, "guest", "dot-agentd", "bin", "dot-agentd"),
  };
}

/** A program to run, with the environment variables it needs on top of the caller's own. */
export interface BuildCommand {
  command: string;
  args: string[];
  env: Record<string, string>;
}

/**
 * The one build of dot-agentd, the same wherever it runs (this function, CI, the smoke, the READMEs): a static
 * linux/amd64 executable whatever the host is (`assertLinuxAmd64Elf` refuses anything else), with the same bytes from
 * the same source and toolchain (go.mod's `toolchain`) in any checkout: `-trimpath` leaves out the checkout's path,
 * `-buildvcs=false` the commit and whether the tree had changes, which Go otherwise stamps into a binary built in a
 * git checkout, so that every commit, and every edit of any file, would make another runtime disk; `-s -w` leave out
 * the symbol table and the debug information.
 */
const AGENTD_BUILD_ENV = { CGO_ENABLED: "0", GOOS: "linux", GOARCH: "amd64" } as const;
const AGENTD_BUILD_FLAGS = ["-trimpath", "-buildvcs=false", "-ldflags=-s -w"] as const;

/** The same build as a shell line, run in guest/dot-agentd: what the documentation and the workflows quote. */
export const AGENTD_BUILD_SHELL = 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -ldflags="-s -w" -o bin/dot-agentd ./cmd/dot-agentd';

/**
 * The command that builds dot-agentd into `output`, by default `defaultRuntimeInputs(repoRoot).agentdBinary`, the
 * file the runtime disk takes. `go -C` enters the module itself, so the caller's working directory does not matter.
 */
export function agentdBuildCommand(repoRoot: string, output: string = defaultRuntimeInputs(repoRoot).agentdBinary): BuildCommand {
  return {
    command: "go",
    args: ["-C", join(repoRoot, "guest", "dot-agentd"), "build", ...AGENTD_BUILD_FLAGS, "-o", output, "./cmd/dot-agentd"],
    env: { ...AGENTD_BUILD_ENV },
  };
}

export interface RuntimeBuildOptions {
  inputs?: RuntimeInputs;
  paths?: HostPaths;
  version?: string;
  assetRoot?: string;
  log?: (line: string) => void;
  now?: () => Date;
}

export interface RuntimeBuildResult {
  version: string;
  iso: string;
  manifest: string;
  created: boolean;
}

/**
 * Refuses anything but a 64-bit little-endian x86-64 ELF executable. A
 * dot-agentd built for the host (a Windows .exe, a macOS binary) would be
 * packed without complaint and fail only inside every Dot.
 */
export async function assertLinuxAmd64Elf(path: string): Promise<void> {
  const handle = await open(path, "r");
  const header = Buffer.alloc(20);
  try {
    await handle.read(header, 0, header.length, 0);
  } finally {
    await handle.close();
  }
  const elf = header[0] === 0x7f && header.toString("latin1", 1, 4) === "ELF";
  const is64 = header[4] === 2;
  const little = header[5] === 1;
  const machine = header.readUInt16LE(18);
  if (!elf || !is64 || !little || machine !== 0x3e) {
    throw new Error(
      `${path} is not a linux/amd64 executable; build it in guest/dot-agentd with ${AGENTD_BUILD_SHELL}`,
    );
  }
}

export interface StagedFile {
  path: string;
  entry: IsoEntry;
  sha256: string;
  size: number;
}

function stageBytes(path: string, bytes: Buffer): StagedFile {
  return { path, entry: { path, data: bytes }, sha256: createHash("sha256").update(bytes).digest("hex"), size: bytes.byteLength };
}

async function stageFile(path: string, hostFile: string): Promise<StagedFile> {
  const info = await stat(hostFile).catch(() => undefined);
  if (!info?.isFile()) throw new Error(`${hostFile} does not exist`);
  return { path, entry: { path, file: hostFile }, sha256: await sha256File(hostFile), size: info.size };
}

/**
 * What the engine's package ships (the wheel's include list in its
 * pyproject.toml): every .py file and the .md templates. The tests and
 * __pycache__ are not part of it.
 */
async function engineSourcePaths(root: string, relative: string, out: string[]): Promise<void> {
  const entries = await readdir(join(root, relative), { withFileTypes: true });
  for (const entry of entries) {
    const path = `${relative}/${entry.name}`;
    if (entry.isDirectory()) {
      if (entry.name !== "__pycache__") await engineSourcePaths(root, path, out);
    } else if (entry.isFile()) {
      if (entry.name.endsWith(".py") || (entry.name.endsWith(".md") && path.startsWith("nanobot/templates/"))) out.push(path);
    } else {
      throw new Error(`${join(root, path)} is neither a file nor a directory; the engine's source must hold only plain files`);
    }
  }
}

/** The built-in skills: `skills/<name>/SKILL.md`, one file each (the wheel's include list says the same). */
async function skillPaths(root: string): Promise<string[]> {
  const entries = await readdir(join(root, "skills"), { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
  const paths: string[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) throw new Error(`${join(root, "skills", entry.name)} is not a skill's folder; skills/ holds one folder per skill`);
    const file = await stat(join(root, "skills", entry.name, "SKILL.md")).catch(() => undefined);
    if (!file?.isFile()) throw new Error(`the skill ${join(root, "skills", entry.name)} has no SKILL.md`);
    paths.push(`skills/${entry.name}/SKILL.md`);
  }
  return paths.sort();
}

/** The engine's files at `engine/` on the disk: its package, its built-in skills, its license and where it was forked from. */
async function engineFiles(engineRoot: string): Promise<StagedFile[]> {
  const paths: string[] = [];
  await engineSourcePaths(engineRoot, "nanobot", paths).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") throw new Error(`the engine's source ${join(engineRoot, "nanobot")} does not exist (invisible_engine_dots/ in this repository)`);
    throw error;
  });
  if (!paths.includes("nanobot/__init__.py")) throw new Error(`${engineRoot} is not the engine's source: it has no nanobot/__init__.py`);
  paths.push(...(await skillPaths(engineRoot)));
  const files: StagedFile[] = [];
  for (const path of paths) files.push(await stageFile(`engine/${path}`, join(engineRoot, path)));
  files.push(await stageFile("engine/LICENSE", join(engineRoot, "LICENSE")));
  files.push(await stageFile("engine/UPSTREAM.md", join(engineRoot, "UPSTREAM.md")));
  return files;
}

/** The ISO's files except VERSION, which depends on the version this list decides. */
export async function runtimeFiles(inputs: RuntimeInputs, assetRoot: string = defaultAssetRoot()): Promise<StagedFile[]> {
  const agentd = await stat(inputs.agentdBinary).catch(() => undefined);
  if (!agentd?.isFile()) {
    throw new Error(
      `dot-agentd binary ${inputs.agentdBinary} not found: build it first (in guest/dot-agentd: ${AGENTD_BUILD_SHELL})`,
    );
  }
  await assertLinuxAmd64Elf(inputs.agentdBinary);

  const files = [
    stageBytes("install.sh", await readGuestAsset(assetRoot, RUNTIME_INSTALL)),
    stageBytes("vmproxy.py", await readGuestAsset(assetRoot, RUNTIME_VMPROXY)),
    stageBytes("bin/dot-desktop", await readGuestAsset(assetRoot, RUNTIME_DESKTOP)),
    stageBytes("bin/dot-install", await readGuestAsset(assetRoot, RUNTIME_DOT_INSTALL)),
    // The browser's script and, beside it where it reads it, the list of the browsers it refuses.
    stageBytes("browser/dot-browser", await readGuestAsset(assetRoot, RUNTIME_BROWSER)),
    stageBytes("browser/other-browsers.txt", await readGuestAsset(assetRoot, RUNTIME_OTHER_BROWSERS)),
    await stageFile("bin/dot-agentd", inputs.agentdBinary),
    ...(await engineFiles(inputs.engineRoot)),
  ];
  for (const unit of GUEST_UNITS) files.push(stageBytes(`units/${unit}`, await readGuestAsset(assetRoot, unitAsset(unit))));
  return files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

export async function buildRuntimeIso(options: RuntimeBuildOptions = {}): Promise<RuntimeBuildResult> {
  const log = options.log ?? (() => undefined);
  const paths = options.paths ?? hostPaths();
  const now = options.now ?? (() => new Date());
  const files = await runtimeFiles(options.inputs ?? defaultRuntimeInputs(), options.assetRoot ?? defaultAssetRoot());
  const digest = inputsDigest(files.flatMap((file) => [file.path, file.sha256]));

  const target = await resolveImageVersion({
    kind: "runtime",
    imagesDir: paths.imagesDir,
    digest,
    version: options.version,
    now,
    imagePath: (v) => paths.runtimeIsoPath(v),
    log,
  });
  const { version, image: iso, manifest: manifestPath } = target;
  if (target.existing) return { version, iso, manifest: manifestPath, created: false };

  const lock = await acquireLock(join(paths.imagesDir, ".runtime-build.lock"), "runtime ISO build");
  try {
    const versionFile = stageBytes("VERSION", Buffer.from(`${version}\n`, "utf8"));
    const all = [...files, versionFile];
    const builtAt = now();
    log(`writing ${iso}`);
    const partial = `${iso}.part`;
    try {
      await writeIso(
        partial,
        all.map((file) => file.entry),
        // The label the seed mounts it by (the vm-manager's one constant), so the device name never matters.
        { volumeId: RUNTIME_ISO_LABEL, timestamp: builtAt, mode: 0o644 },
      );
      const manifest: RuntimeManifest = {
        kind: "runtime",
        version,
        file: basename(iso),
        sha256: await sha256File(partial),
        size_bytes: (await stat(partial)).size,
        built_at: builtAt.toISOString(),
        content_digest: digest,
        files: all.map((file): RuntimeFile => ({ path: file.path, sha256: file.sha256, size_bytes: file.size })),
      };
      await publishImage(partial, iso, manifestPath, manifest);
      log(`done: ${iso} (sha256 ${manifest.sha256})`);
      return { version, iso, manifest: manifestPath, created: true };
    } catch (error) {
      await rm(partial, { force: true }).catch(() => undefined);
      throw error;
    }
  } finally {
    await lock.release();
  }
}
