import { cp, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hostPaths, type HostPaths } from "@invisible-dots/shared";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
// The ISO package's own test reader: it shares no code with the writer.
import { fileBytes, listFiles, parseIso } from "../../../packages/iso/test/iso-reader.js";
import { defaultAssetRoot, GUEST_UNITS } from "../src/assets.js";
import { readManifest, verifyImage, type RuntimeManifest } from "../src/manifest.js";
import { RUNTIME_ISO_LABEL } from "@invisible-dots/vm-manager";
import { AGENTD_BUILD_SHELL, agentdBuildCommand, assertLinuxAmd64Elf, buildRuntimeIso, defaultRuntimeInputs, runtimeFiles, type RuntimeInputs } from "../src/runtime.js";
import { sha256 } from "./http-fixture.js";

/** The first bytes of an ELF executable for `machine` (0x3e is x86-64, 0xb7 arm64). */
function elf(machine: number, body = "go binary"): Buffer {
  const header = Buffer.alloc(64);
  header.set([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1], 0);
  header.writeUInt16LE(2, 16);
  header.writeUInt16LE(machine, 18);
  return Buffer.concat([header, Buffer.from(body)]);
}

/** A stand-in for invisible_engine_dots/: what the runtime disk takes, and what it leaves out. */
async function writeEngineTree(root: string): Promise<void> {
  const files: Record<string, string> = {
    "nanobot/__init__.py": "__version__ = '0.1.0'\n",
    "nanobot/dots/main.py": "def main(): ...\n",
    "nanobot/templates/agent/tool_contract.md": "# contract\n",
    "nanobot/README.md": "not a template: left out\n",
    "nanobot/dots/data.json": "not source: left out\n",
    "nanobot/__pycache__/main.cpython-312.pyc": "bytecode",
    "skills/web-forms/SKILL.md": "---\nname: web-forms\ndescription: Fill a form.\n---\n",
    "skills/web-forms/notes.txt": "beside the skill: left out\n",
    "tests/test_main.py": "def test(): ...\n",
    "pyproject.toml": "[project]\n",
    LICENSE: "MIT\n",
    "UPSTREAM.md": "upstream\n",
  };
  for (const [path, text] of Object.entries(files)) {
    await mkdir(join(root, path, ".."), { recursive: true });
    await writeFile(join(root, path), text);
  }
}

let dir: string;
let paths: HostPaths;
let inputs: RuntimeInputs;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "idots-runtime-"));
  paths = hostPaths({ INVISIBLE_DOTS_HOME: join(dir, "home") });
  inputs = {
    agentdBinary: join(dir, "dot-agentd"),
    engineRoot: join(dir, "engine-src"),
  };
  await writeEngineTree(inputs.engineRoot);
  await writeFile(inputs.agentdBinary, elf(0x3e));
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const at = (iso: string) => new Date(`2026-10-02T${iso}Z`);

describe("agentdBuildCommand", () => {
  it("builds, for linux/amd64 without cgo, exactly the file the runtime disk takes", () => {
    const build = agentdBuildCommand(join("repo", "root"));
    expect(build.command).toBe("go");
    expect(build.env).toEqual({ CGO_ENABLED: "0", GOOS: "linux", GOARCH: "amd64" });
    expect(build.args).toEqual([
      "-C",
      join("repo", "root", "guest", "dot-agentd"),
      "build",
      "-trimpath",
      "-buildvcs=false",
      "-ldflags=-s -w",
      "-o",
      defaultRuntimeInputs(join("repo", "root")).agentdBinary,
      "./cmd/dot-agentd",
    ]);
  });

  it("builds into another file when asked, with the same flags", () => {
    const build = agentdBuildCommand(join("repo", "root"), join("elsewhere", "dot-agentd"));
    expect(build.args).toEqual([...agentdBuildCommand(join("repo", "root")).args.slice(0, -3), "-o", join("elsewhere", "dot-agentd"), "./cmd/dot-agentd"]);
  });

  it("is the build the shell line quotes: its environment, then go build with its flags, run in guest/dot-agentd", () => {
    const build = agentdBuildCommand(join("repo", "root"), "bin/dot-agentd");
    const env = Object.entries(build.env).map(([name, value]) => `${name}=${value}`);
    // The shell line's one quoted word, -ldflags="-s -w", is the single argument -ldflags=-s -w.
    const args = build.args.slice(2).map((arg) => (arg.includes(" ") ? arg.replace(/=(.*)$/, '="$1"') : arg));
    expect(AGENTD_BUILD_SHELL).toBe([...env, "go", ...args].join(" "));
  });
});

describe("buildRuntimeIso", () => {
  it("writes the IDOTS-RT disk with the engine, dot-agentd, the hook and the units", async () => {
    const result = await buildRuntimeIso({ inputs, paths, now: () => at("08:00:00") });
    expect(result.created).toBe(true);
    expect(result.version).toMatch(/^20261002080000-[0-9a-f]{12}$/);
    expect(result.iso).toBe(paths.runtimeIsoPath(result.version));
    expect((await stat(result.iso)).mode & 0o222).toBe(0);

    const image = await readFile(result.iso);
    const parsed = parseIso(image);
    // The label the Dot seed mounts (vm-manager seed.ts): the two meet in one constant.
    expect(parsed.primary.volumeId).toBe(RUNTIME_ISO_LABEL);
    expect(parsed.joliet.volumeId).toBe(RUNTIME_ISO_LABEL);
    const files = listFiles(parsed.joliet.root);
    expect([...files.keys()].sort()).toEqual(
      [
        "VERSION",
        "bin/dot-agentd",
        "bin/dot-desktop",
        "bin/dot-install",
        "browser/dot-browser",
        "browser/other-browsers.txt",
        "engine/LICENSE",
        "engine/UPSTREAM.md",
        "engine/nanobot/__init__.py",
        "engine/nanobot/dots/main.py",
        "engine/nanobot/templates/agent/tool_contract.md",
        "engine/skills/web-forms/SKILL.md",
        "install.sh",
        "vmproxy.py",
        ...GUEST_UNITS.map((unit) => `units/${unit}`),
      ].sort(),
    );
    const read = (path: string) => fileBytes(image, files.get(path)!);
    expect(read("VERSION").toString()).toBe(`${result.version}\n`);
    expect(read("bin/dot-agentd")).toEqual(elf(0x3e));
    expect(read("install.sh")).toEqual(await readFile(join(defaultAssetRoot(), "runtime", "install.sh")));
    expect(read("vmproxy.py")).toEqual(await readFile(join(defaultAssetRoot(), "runtime", "vmproxy.py")));
    expect(read("bin/dot-desktop")).toEqual(await readFile(join(defaultAssetRoot(), "runtime", "dot-desktop.sh")));
    // The browser's script with its list beside it, where it reads it: install.sh switches and stages with them.
    expect(read("browser/dot-browser")).toEqual(await readFile(join(defaultAssetRoot(), "runtime", "dot-browser.sh")));
    expect(read("browser/other-browsers.txt")).toEqual(await readFile(join(defaultAssetRoot(), "runtime", "other-browsers.txt")));
    expect(read("units/dot-agentd.service")).toEqual(await readFile(join(defaultAssetRoot(), "units", "dot-agentd.service")));
    // The engine's source as it is.
    expect(read("engine/nanobot/dots/main.py").toString()).toBe("def main(): ...\n");
    expect(read("engine/LICENSE").toString()).toBe("MIT\n");

    const manifest = (await readManifest(result.manifest)) as RuntimeManifest;
    expect(manifest).toMatchObject({ kind: "runtime", version: result.version, file: `runtime-${result.version}.iso`, sha256: sha256(image), size_bytes: image.length });
    expect(manifest.files.find((file) => file.path === "bin/dot-agentd")).toEqual({ path: "bin/dot-agentd", sha256: sha256(elf(0x3e)), size_bytes: elf(0x3e).length });
    expect(result.version.endsWith(manifest.content_digest)).toBe(true);
    expect(await verifyImage(result.iso)).toMatchObject({ ok: true });
  });

  it("does nothing for code it already packed, and makes a newer version for new code", async () => {
    const first = await buildRuntimeIso({ inputs, paths, now: () => at("08:00:00") });
    const again = await buildRuntimeIso({ inputs, paths, now: () => at("09:00:00") });
    expect(again).toEqual({ ...first, created: false });

    await writeFile(inputs.agentdBinary, elf(0x3e, "another go binary"));
    const next = await buildRuntimeIso({ inputs, paths, now: () => at("10:00:00") });
    expect(next.created).toBe(true);
    // The control plane starts VMs with the highest version: the new code must sort last.
    expect([next.version, first.version].sort((a, b) => a.localeCompare(b, "en", { numeric: true })).at(-1)).toBe(next.version);
  });

  it("uses an explicit version as given", async () => {
    const result = await buildRuntimeIso({ inputs, paths, version: "1.2.3" });
    expect(result.iso).toBe(paths.runtimeIsoPath("1.2.3"));
    await expect(buildRuntimeIso({ inputs, paths, version: "../x" })).rejects.toThrow(/invalid image version/);
  });

  it("names the build command for a missing input", async () => {
    await rm(inputs.agentdBinary);
    await expect(buildRuntimeIso({ inputs, paths })).rejects.toThrow(/GOOS=linux GOARCH=amd64 go build/);
  });

  it("makes a new version when only the engine's source changes", async () => {
    const first = await buildRuntimeIso({ inputs, paths, now: () => at("08:00:00") });
    await writeFile(join(inputs.engineRoot, "nanobot", "dots", "main.py"), "def main(): return 0\n");
    const next = await buildRuntimeIso({ inputs, paths, now: () => at("09:00:00") });
    expect(next.created).toBe(true);
    expect(next.version).not.toBe(first.version);
  });

  it("refuses a tree that is not the engine's source", async () => {
    await rm(join(inputs.engineRoot, "nanobot", "__init__.py"));
    await expect(buildRuntimeIso({ inputs, paths })).rejects.toThrow(/is not the engine's source: it has no nanobot\/__init__\.py/);
    await rm(join(inputs.engineRoot, "nanobot"), { recursive: true });
    await expect(buildRuntimeIso({ inputs, paths })).rejects.toThrow(/the engine's source .* does not exist/);
  });

  it("carries the whole engine of this repository within the ISO's limits", async () => {
    const real = { ...inputs, engineRoot: defaultRuntimeInputs().engineRoot };
    const staged = (await runtimeFiles(real)).map((file) => file.path);
    for (const path of [
      "engine/nanobot/__init__.py",
      "engine/nanobot/__main__.py",
      "engine/nanobot/dots/main.py",
      "engine/nanobot/agent/tools/shell.py",
      "engine/nanobot/templates/agent/tool_contract.md",
      // Run by the installed browser server's own interpreter, which reads it from the runtime disk (server_interface.py).
      "engine/nanobot/dots/server_capture.py",
      "engine/skills/invisible-playwright/SKILL.md",
    ]) {
      expect(staged).toContain(path);
    }
    expect(staged.filter((path) => path.startsWith("engine/") && !/\.(py|md)$|LICENSE$/.test(path))).toEqual([]);
    expect(staged.some((path) => path.includes("tests/") || path.includes("__pycache__"))).toBe(false);
    // The ISO's own limits (8 levels, names of 64 characters) hold for every one of them.
    const result = await buildRuntimeIso({ inputs: real, paths, now: () => at("08:00:00") });
    const parsed = parseIso(await readFile(result.iso));
    expect([...listFiles(parsed.joliet.root).keys()]).toContain("engine/nanobot/agent/tools/shell.py");
  });

  it("refuses a guest file with CRLF line endings", async () => {
    const assetRoot = join(dir, "assets");
    await cp(defaultAssetRoot(), assetRoot, { recursive: true, filter: (source) => !source.includes("node_modules") });
    const unit = join(assetRoot, "units", "dot-agentd.service");
    await writeFile(unit, (await readFile(unit, "utf8")).replaceAll("\n", "\r\n"));
    await expect(buildRuntimeIso({ inputs, paths, assetRoot })).rejects.toThrow(/dot-agentd\.service has CR line endings/);
  });
});

describe("assertLinuxAmd64Elf", () => {
  it("accepts linux/amd64 and refuses other builds of dot-agentd", async () => {
    const path = join(dir, "bin");
    await writeFile(path, elf(0x3e));
    await expect(assertLinuxAmd64Elf(path)).resolves.toBeUndefined();
    await writeFile(path, elf(0xb7));
    await expect(assertLinuxAmd64Elf(path)).rejects.toThrow(/not a linux\/amd64 executable/);
    await writeFile(path, Buffer.concat([Buffer.from("MZ"), Buffer.alloc(100)]));
    await expect(assertLinuxAmd64Elf(path)).rejects.toThrow(/not a linux\/amd64 executable/);
    await writeFile(path, "");
    await expect(assertLinuxAmd64Elf(path)).rejects.toThrow(/not a linux\/amd64 executable/);
  });
});
