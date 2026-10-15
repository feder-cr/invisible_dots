// Checks of the files that run inside the guest. A mistake in them shows up
// only inside a booted VM, minutes into a build or on every Dot's boot, so
// the cheap ones are caught here.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { GUEST_PATHS } from "@invisible-dots/shared";
import { describe, expect, it } from "vitest";
import { defaultAssetRoot, GUEST_ASSETS, GUEST_UNITS, RUNTIME_OTHER_BROWSERS, unitAsset } from "../src/assets.js";
import { GUEST_PINS } from "../src/pins.js";

const root = defaultAssetRoot();
const text = (relative: string) => readFileSync(join(root, relative), "utf8");
const scripts = GUEST_ASSETS.filter((path) => path.endsWith(".sh"));

/**
 * Whether a bash that can read this checkout's paths is on PATH. On a
 * Windows host "bash" can be WSL's launcher, which cannot open C:\ paths;
 * probing for that is a capability check, not a platform check.
 */
function bashCanRead(path: string): boolean {
  try {
    execFileSync("bash", ["-n", path], { stdio: "pipe", timeout: 20_000 });
    return true;
  } catch {
    return false;
  }
}
const bashUsable = bashCanRead(join(root, "runtime", "dot-desktop.sh"));

describe("guest files", () => {
  it("lists every guest script", () => {
    expect([...scripts].sort()).toEqual(["builder/build-engine-env.sh", "builder/provision.sh", "runtime/dot-browser.sh", "runtime/dot-desktop.sh", "runtime/dot-install.sh", "runtime/install.sh"]);
  });

  it.each(GUEST_ASSETS)("%s is LF-only ASCII and says nothing about vsock or libvirt", (path) => {
    const content = text(path);
    expect(content).not.toContain("\r");
    expect(/^[\x09\x0a\x20-\x7e]*$/.test(content)).toBe(true);
    expect(content).not.toMatch(/vsock|libvirt|virsh/i);
  });

  it.each(scripts)("%s runs in bash strict mode", (path) => {
    const content = text(path);
    expect(content.startsWith("#!/usr/bin/env bash\n")).toBe(true);
    expect(content).toMatch(/^set -E?euo pipefail$/m);
  });

  it.skipIf(!bashUsable).each(scripts)("%s parses with bash -n", (path) => {
    execFileSync("bash", ["-n", join(root, path)], { stdio: "pipe" });
  });

  it("provision.sh records the engine the library names, as browser-engine, and not a line it parsed out of prose", () => {
    const content = text("builder/provision.sh");
    expect(content).toContain('component browser-engine "$engine_version"');
    expect(content).toContain("from invisible_core import BINARY_VERSION, FIREFOX_UPSTREAM_VERSION");
    expect(content).toContain("from invisible_core.constants import BUILD_ID");
    // The old way: sed over the text `invisible-playwright version` prints, which changes with its wording.
    expect(content).not.toMatch(/version \| sed\b/);
    expect(content).not.toContain('invisible-playwright" version');
  });

  /**
   * The Python program of provision.sh's engine line, run as the guest runs it against a stand-in for invisible_core
   * (the three names it reads there), and compared with the engine line of `invisible-playwright version` (the format
   * of invisible_playwright's cli.py, which printed the line the manifest has always recorded): the manifest keeps its
   * wording, and a change of the names the program reads shows here and not minutes into an image build.
   */
  const engineProgram = (() => {
    const match = /engine_version="\$\(as_dot "[^"]+" -c '([^']+)'\)"/.exec(text("builder/provision.sh"));
    if (!match) throw new Error("provision.sh no longer reads the engine with `python -c '...'`");
    return match[1]!;
  })();
  const python = (() => {
    for (const command of ["python3", "python"]) {
      try {
        execFileSync(command, ["-c", "import sys; assert sys.version_info >= (3, 8)"], { stdio: "pipe", timeout: 20_000 });
        return command;
      } catch {
        // the next name
      }
    }
    return null;
  })();

  it.skipIf(python === null)("the engine program prints what the engine line of `invisible-playwright version` printed", () => {
    const stand = mkdtempSync(join(tmpdir(), "idots-core-"));
    try {
      mkdirSync(join(stand, "invisible_core"));
      writeFileSync(join(stand, "invisible_core", "__init__.py"), "from .constants import BINARY_VERSION, FIREFOX_UPSTREAM_VERSION\n");
      writeFileSync(
        join(stand, "invisible_core", "constants.py"),
        'BINARY_VERSION = "firefox-34"\nFIREFOX_UPSTREAM_VERSION = "151.0"\nBUILD_ID = "20260920230044"\n',
      );
      const printed = execFileSync(python!, ["-c", engineProgram], { env: { ...process.env, PYTHONPATH: stand }, encoding: "utf8" });
      // cli.py: print(f"engine               {s.tag}  Firefox {s.upstream_version}  build {s.build_id}"), minus its label.
      expect(printed.trim()).toBe("firefox-34  Firefox 151.0  build 20260920230044");
    } finally {
      rmSync(stand, { recursive: true, force: true });
    }
  });
});

describe("the sudo grants (architecture section 4.1)", () => {
  it("the builder seed gives dot, dotagentd and dotengine no sudo rule, and the provisioner removes any the image had", () => {
    const builder = text("builder/user-data.yaml");
    expect(builder).toContain("  - name: dot\n");
    expect(builder).toContain("  - name: dotagentd\n");
    expect(builder).toContain("  - name: dotengine\n");
    expect(builder.match(/^\s*sudo:.*$/gm)).toEqual(["    sudo: false", "    sudo: false", "    sudo: false"]);
    // provision.sh runs as root and reaches dot through root's own sudo -u.
    expect(text("builder/provision.sh")).toContain("rm -f /etc/sudoers.d/90-cloud-init-users");
  });
});

/**
 * dot-install as sudo runs it, with `id` answering root and `apt-get` a stand-in that records its arguments: what
 * reaches apt, or that nothing does.
 */
describe.skipIf(!bashUsable)("dot-install, the one command dot may run as root", () => {
  function dotInstall(...names: string[]): { status: number; stderr: string; apt: string[] } {
    const stubs = mkdtempSync(join(tmpdir(), "idots-dot-install-"));
    try {
      const calls = join(stubs, "apt-calls");
      writeFileSync(join(stubs, "id"), "#!/bin/sh\necho 0\n", { mode: 0o755 });
      writeFileSync(join(stubs, "apt-get"), `#!/bin/sh\necho "$*" >> '${calls.replace(/\\/g, "/")}'\n`, { mode: 0o755 });
      // Windows spells the variable Path, and an environment holding both spellings is ambiguous.
      const pathKey = Object.keys(process.env).find((key) => key.toUpperCase() === "PATH") ?? "PATH";
      const run = spawnSync("bash", [join(root, "runtime", "dot-install.sh"), ...names], {
        env: { ...process.env, [pathKey]: `${stubs}${delimiter}${process.env[pathKey] ?? ""}` },
        encoding: "utf8",
        timeout: 20_000,
      });
      const apt = existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n") : [];
      return { status: run.status ?? -1, stderr: run.stderr, apt };
    } finally {
      rmSync(stubs, { recursive: true, force: true });
    }
  }
  const lock = "-o DPkg::Lock::Timeout=300";

  it("installs package names, those that end in + included", () => {
    expect(dotInstall("nodejs", "libgtk-3-0t64", "python3.12", "g++", "ncbi-blast+")).toEqual({
      status: 0,
      stderr: "",
      apt: [`${lock} update -qq`, `${lock} install -y nodejs libgtk-3-0t64 python3.12 g++ ncbi-blast+`],
    });
  });

  it("passes a trailing + on, which apt reads as install", () => {
    expect(dotInstall("foo+").apt).toEqual([`${lock} update -qq`, `${lock} install -y foo+`]);
  });

  it.each([
    ["a trailing -, which apt reads as remove", "coreutils-"],
    ["an option", "-o"],
    ["a long option", "--allow-remove-essential"],
    ["a version", "foo=1.0"],
    ["a release", "foo/noble"],
    ["an architecture", "foo:i386"],
    ["upper case", "Foo"],
    ["one character", "a"],
    ["an empty word", ""],
  ])("refuses %s, and nothing reaches apt", (_what, name) => {
    const run = dotInstall("nodejs", name);
    expect(run.status).toBe(2);
    expect(run.stderr).toContain(`"${name}" is not a package name`);
    expect(run.apt).toEqual([]);
  });
});

describe("the Dot's browser", () => {
  const provision = text("builder/provision.sh");
  const build = text("runtime/dot-browser.sh");
  const install = text("runtime/install.sh");

  it("is the release the build resolved, installed exactly by the runtime disk's own script, which the seed carries", () => {
    expect(provision).toContain('bash "$payload/$BROWSER" install "$MCP_VERSION" "$PLAYWRIGHT_VERSION" "$CORE_VERSION"\n');
    // What provision.sh records is read from the environment the server's link names.
    expect(provision).toContain('mcp_env="$(dirname "$(dirname "$(readlink -f /home/dot/.local/bin/invisible-playwright-mcp)")")"\n');
    expect(build).toContain('local requirements=("${packages[0]}==$2" "${packages[1]}==$3" "${packages[2]}==$4")');
    expect(build).toContain('as_dot uv venv --quiet --python /usr/bin/python3 "$env_dir"');
    // Wheels only, the release given.
    expect(build).toContain('as_dot uv pip install --no-cache --python "$env_dir/bin/python" --only-binary :all: "${requirements[@]}"');
    expect(build).not.toMatch(/uv tool install/);
    expect(build).toContain('as_dot "$env_dir/bin/invisible-playwright" fetch');
  });

  it("keeps each release in an environment of its own and switches the server's link in one rename", () => {
    expect(build).toContain("releases=$share/browser\n");
    expect(build).toContain('local env_dir="$releases/$1-$2-$3"');
    expect(build).toContain('env_dir="$releases/$mcp-$playwright-$core"');
    expect(build).toContain('as_dot ln -sfn "$1/bin/invisible-playwright-mcp" "$command_link.new"\n  as_dot mv -T "$command_link.new" "$command_link"');
    // A release is staged only once it is whole: the link to it is the last step of a stage.
    expect(build).toMatch(/build "\$env_dir" "\$mcp" "\$playwright" "\$core"\n  as_dot ln -sfn "\$env_dir" "\$staged\.new"\n  as_dot mv -T "\$staged\.new" "\$staged"/);
    // The newest is uv's own resolution of the server, not a version written anywhere.
    expect(build).toContain("as_dot uv pip compile - --quiet --no-cache --no-header --no-annotate");
  });

  it("is brought to the newest release at a Dot's starts: switched before the units start, staged after them", () => {
    const proxy = install.indexOf('nft -f "$proxy_dir/allow.nft"');
    const switched = install.indexOf('"$runtime/browser/dot-browser" switch');
    const started = install.indexOf('systemctl start "$unit"');
    const staged = install.indexOf('systemd-run --quiet --no-block --collect --unit=dot-browser-stage "$runtime/browser/dot-browser" stage');
    expect(proxy).toBeGreaterThan(0);
    expect(switched).toBeGreaterThan(proxy);
    expect(started).toBeGreaterThan(switched);
    expect(staged).toBeGreaterThan(started);
  });

  it("records the versions the environment holds, read from it, not the ones it was asked for", () => {
    expect(provision).toContain("installed_version() { as_dot \"$mcp_env/bin/python\" -c 'import sys, importlib.metadata as m; print(m.version(sys.argv[1]))' \"$1\"; }");
    for (const name of ["invisible-playwright-mcp", "invisible-playwright", "invisible-core"]) {
      expect(provision).toContain(`component ${name} "$(installed_version ${name})"`);
    }
  });

  /**
   * Owner's rule: the only browser of a Dot is invisible-playwright-mcp. No other browser, headless browser or browser
   * library enters the guest image: not as an apt package, not among the Python packages the browser's environment
   * installs (dot-browser.sh refuses them, reading the same list), not as a command of the scripts that build it.
   */
  const otherBrowsers = text(RUNTIME_OTHER_BROWSERS)
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
  const isOtherBrowser = (name: string) => otherBrowsers.some((other) => name === other || name.startsWith(`${other}-`));

  it("installs no other browser, headless browser or browser library", () => {
    expect(GUEST_PINS.apt_packages.filter(isOtherBrowser)).toEqual([]);
    expect(build).toContain('other_browsers="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/other-browsers.txt"');
    expect(build).toContain('installed="$(as_dot uv pip freeze --python "$env_dir/bin/python"');
    expect(build).toContain("another browser would enter the Dot (owner's rule)");
    for (const [name, content] of [["provision.sh", provision], ["dot-browser.sh", build]] as const) {
      expect(content, name).not.toMatch(/\b(chromium|google-chrome|selenium|puppeteer|patchright|chromedriver|geckodriver)\b/i);
      expect(content, name).not.toMatch(/\bplaywright install\b/);
    }
  });

  it("the list refuses what it is meant to refuse and lets the Dot's browser through", () => {
    for (const name of ["chromium", "chromium-browser", "firefox", "google-chrome-stable", "selenium", "playwright", "patchright", "pyppeteer", "lynx", "webkit2gtk-4.1"]) {
      expect(isOtherBrowser(name), name).toBe(true);
    }
    for (const name of ["invisible-playwright", "invisible-playwright-mcp", "invisible-core", "libgtk-3-0t64", "xvfb", "imagemagick", "fonts-dejavu-core"]) {
      expect(isOtherBrowser(name), name).toBe(false);
    }
  });
});

describe("guest units", () => {
  /** Each unit's own user (architecture 4.1): the desktop is dot's, the computer daemon and the engine have their own. */
  const UNIT_USER = { "dot-desktop.service": "dot", "dot-agentd.service": "dotagentd", "invisible-dots-agent.service": "dotengine" } as const;

  it("has one user for each unit it installs", () => {
    expect(Object.keys(UNIT_USER).sort()).toEqual([...GUEST_UNITS].sort());
  });

  /** The PATH of a unit: its one Environment=PATH= line. */
  const unitPath = (name: (typeof GUEST_UNITS)[number]): string[] => {
    const lines = text(unitAsset(name)).split("\n").filter((line) => line.startsWith("Environment=PATH="));
    expect(lines, name).toHaveLength(1);
    return lines[0]!.slice("Environment=PATH=".length).split(":");
  };

  it.each(GUEST_UNITS.filter((name) => name !== "dot-agentd.service"))("%s runs with the display, as its own user", (name) => {
    const unit = text(unitAsset(name));
    expect(unit).toMatch(new RegExp(`^User=${UNIT_USER[name]}$`, "m"));
    expect(unit).toMatch(/^Environment=DISPLAY=:0$/m);
    expect(unit).toMatch(/^RequiresMountsFor=\/opt\/invisible-dots$/m);
    expect(unit).toMatch(/^Restart=on-failure$/m);
    // Not enabled: install.sh starts it, after the Dot's proxy and browser (the test below).
    expect(unit).not.toMatch(/^\[Install\]$/m);
  });

  it("are started by install.sh alone, which also takes back what an earlier runtime enabled", () => {
    // Enabled, systemd would start them at multi-user.target on every boot after the first, ahead of cloud-init's final
    // stage that runs install.sh (cloud-final.service is After=multi-user.target): before the proxy and the browser.
    const install = text("runtime/install.sh");
    expect(install).not.toMatch(/systemctl enable/);
    expect(install).toContain('for unit in "${units[@]}"; do rm -f "/etc/systemd/system/multi-user.target.wants/$unit"; done');
  });

  it("runs the desktop, which is dot's, with uv's bin dir first", () => {
    expect(unitPath("dot-desktop.service")[0]).toBe("/home/dot/.local/bin");
  });

  it("runs the engine, which holds the key, with a PATH of system directories only, and names the browser's server by its path", () => {
    // Nothing the engine runs by name may come from a directory dot (the model) can write. The browser's MCP server
    // is dot's (dot-browser.sh links it into ~dot/.local/bin): the unit names it, and the engine starts it as dot.
    for (const dir of unitPath("invisible-dots-agent.service")) expect(dir, `PATH entry ${dir}`).toMatch(/^\/(usr\/local\/|usr\/)?s?bin$/);
    expect(text(unitAsset("invisible-dots-agent.service"))).toMatch(/^Environment=INVISIBLE_DOTS_MCP_COMMAND=\/home\/dot\/\.local\/bin\/invisible-playwright-mcp$/m);
  });

  it("runs dot-agentd with the display, as its own user, and a PATH of system directories only", () => {
    const unit = text(unitAsset("dot-agentd.service"));
    expect(unit).toMatch(/^User=dotagentd$/m);
    expect(unit).toMatch(/^Environment=DISPLAY=:0$/m);
    expect(unit).toMatch(/^RequiresMountsFor=\/opt\/invisible-dots$/m);
    expect(unit).toMatch(/^Restart=on-failure$/m);
    // Not enabled: install.sh starts it, after the Dot's proxy and browser (the test below).
    expect(unit).not.toMatch(/^\[Install\]$/m);
    // The daemon starts the poweroff as itself, and may become root through it: nothing it finds may be in a
    // directory dot (the model) can write, so its PATH has no entry of /home (dot's ~/.local/bin included) and
    // none that is relative or empty. The PATH of the model's commands is the daemon's to build.
    const path = unitPath("dot-agentd.service");
    expect(path.length).toBeGreaterThan(0);
    for (const dir of path) expect(dir, `PATH entry ${dir}`).toMatch(/^\/(usr\/local\/|usr\/)?s?bin$/);
  });

  it("runs dot-agentd as its own user, with the three capabilities that take it to start the model's work as dot and no others", () => {
    const unit = text(unitAsset("dot-agentd.service"));
    const settings = unit.split("\n").filter((line) => !line.startsWith("#")).join("\n");
    expect(unit).toMatch(/^User=dotagentd$/m);
    expect(unit).toMatch(/^Group=dotagentd$/m);
    // CAP_SETUID and CAP_SETGID to change to dot, CAP_KILL to end a process group of dot's: every capability more
    // makes the daemon's compromise more than it has to be.
    expect(unit).toMatch(/^AmbientCapabilities=CAP_SETUID CAP_SETGID CAP_KILL$/m);
    // The environment of what the daemon starts for the model is dot's, which the daemon sets from the account it
    // runs them as: the unit gives it no home of dot's, and the daemon is told no other user to run them as.
    expect(settings).not.toMatch(/Environment=(HOME|USER|LOGNAME|SHELL)=|WorkingDirectory=|--run-as|INVISIBLE_DOTS_RUN_AS/);
    expect(settings).not.toMatch(/^User=dot$/m);
  });

  it("starts dot-agentd from the runtime disk without overriding its TCP 1024 listener", () => {
    const unit = text(unitAsset("dot-agentd.service"));
    expect(unit).toContain("ExecStart=/opt/invisible-dots/bin/dot-agentd\n");
    expect(unit).toContain("TCP port 1024");
    // The default (all guest addresses, port 1024) is what QEMU's forward reaches; a
    // loopback-only override here would make every Dot unreachable.
    expect(unit).not.toMatch(/INVISIBLE_DOTS_AGENTD_LISTEN|--listen/);
  });

  it("orders the agent after dot-agentd and the desktop", () => {
    const unit = text(unitAsset("invisible-dots-agent.service"));
    expect(unit).toMatch(/^After=.*dot-agentd\.service.*dot-desktop\.service/m);
  });

  it("starts the Python engine as dotengine from its venv, isolated, with its state and sockets named", () => {
    const unit = text(unitAsset("invisible-dots-agent.service"));
    // -I: no PYTHON* variable and no user site; -B: the runtime disk is read-only.
    expect(unit).toContain("ExecStart=/opt/invisible-dots-engine/bin/python -I -B -m nanobot\n");
    expect(unit).toMatch(/^User=dotengine$/m);
    expect(unit).toMatch(/^Group=dotengine$/m);
    expect(unit).toMatch(/^UMask=0002$/m);
    expect(unit).toContain("Environment=HOME=/home/dotengine\n");
    expect(unit).toContain("Environment=TIKTOKEN_CACHE_DIR=/opt/invisible-dots-engine/share/tiktoken\n");
    expect(unit).toContain("Environment=INVISIBLE_DOTS_ENGINE_STATE=/home/dotengine/state\n");
    expect(unit).toContain("Environment=INVISIBLE_DOTS_AGENT_SOCKET=/run/invisible-dots-agent/agent.sock\n");
    expect(unit).toContain("Environment=INVISIBLE_DOTS_AGENTD_SOCKET=/run/invisible-dots/agentd.sock\n");
    expect(unit).toContain("Environment=INVISIBLE_DOTS_AGENTD_BIN=/opt/invisible-dots/bin/dot-agentd\n");
    expect(unit).toContain("Environment=INVISIBLE_DOTS_WORKSPACE=/home/dot/workspace\n");
    // It needs no privilege and may leave no core file: the key lives in its memory (architecture 4.3).
    expect(unit).toMatch(/^NoNewPrivileges=yes$/m);
    expect(unit).toMatch(/^LimitCORE=0$/m);
    expect(unit).toMatch(/^TimeoutStopSec=30$/m);
    // No key, ever, in the unit's environment, and no sudo or installer of any kind.
    const settings = unit.split("\n").filter((line) => !line.startsWith("#")).join("\n");
    expect(settings).not.toMatch(/API_KEY|NODE_ENV|sudo|INSTALLER/);
  });

  it("gives each socket a directory only its two daemons reach, never dot, and dotengine no root command", () => {
    const install = text("runtime/install.sh");
    // The group of each directory is the other daemon's: dot-agentd reaches the engine's, the engine reaches its own.
    expect(install).toContain("d /run/invisible-dots 2750 dotagentd dotengine -");
    expect(install).toContain("d /run/invisible-dots-agent 2750 dotengine dotagentd -");
    expect(install).not.toMatch(/d \/run\/invisible-dots(-agent)? 2750 [a-z]+ dot( |\\n)/);
    expect(install).toContain("install -d -o dotengine -g dotengine -m 0700 /home/dotengine/state");
    // One sudo rule, dot's, for dot-install and nothing else; no config directory: the engine's config lives in its database.
    expect(install.match(/NOPASSWD: .*/g)).toEqual(["NOPASSWD: /usr/local/sbin/dot-install\\n' > /etc/sudoers.d/dot-install.new"]);
    expect(install).not.toMatch(/dotengine ALL=|dotagentd ALL=|\/etc\/invisible-dots\/[a-z]+\//);
    expect(text("builder/user-data.yaml")).toMatch(/- name: dotengine\n[\s\S]*?groups: \[dot\]/);
  });

  it("the provisioner and install.sh make the home of the MCP servers, dot's, outside the home the host reads", () => {
    expect(GUEST_PATHS.mcpHomes.startsWith(`${GUEST_PATHS.home}/`)).toBe(false);
    for (const file of ["builder/provision.sh", "runtime/install.sh"]) {
      expect(text(file), file).toContain(`install -d -o dot -g dot -m 0700 ${GUEST_PATHS.mcpHomes}\n`);
    }
  });

  it("install.sh and the provisioner refuse a golden image without dot-agentd's user, as they do one without the engine's", () => {
    expect(text("runtime/install.sh")).toContain('id dotagentd >/dev/null 2>&1 || die "user dotagentd does not exist');
    expect(text("builder/provision.sh")).toContain("id dotagentd >/dev/null 2>&1 ||");
  });

  it("install.sh refuses a golden image without the engine's environment", () => {
    const install = text("runtime/install.sh");
    expect(install).toContain("[ -x /opt/invisible-dots-engine/bin/python ] || die ");
    expect(install).toContain("a golden image from before the nanobot engine");
  });

  it("install.sh installs exactly the units the runtime disk carries", () => {
    expect(text("runtime/install.sh")).toContain(`units=(${GUEST_UNITS.join(" ")})`);
  });
});

describe("the desktop", () => {
  it("starts Xvfb without a TCP listener, so X needs no guest firewall", () => {
    expect(text("runtime/dot-desktop.sh")).toContain('Xvfb "$display" -nolisten tcp');
  });
});

describe("the provisioner", () => {
  const provision = text("builder/provision.sh");

  it("reports progress, components and one verdict on the serial console", () => {
    expect(provision).toContain('step() { console "idots-build: $*"; }');
    expect(provision).toContain('component() { console "IDOTS-BUILD-COMPONENT: $1=$2"; }');
    expect(provision).toContain('console "IDOTS-BUILD-RESULT: ok"');
    expect(provision).toContain('console "IDOTS-BUILD-RESULT: failed at line $1: $2"');
  });

  it("builds the engine's Python environment with the script the seed carries, at the path the unit runs", () => {
    expect(provision).toContain('bash "$payload/$ENGINE_BUILD" "$payload/$ENGINE_LOCK" "$engine_venv" /opt/invisible-dots/engine');
    expect(provision).toContain("engine_venv=/opt/invisible-dots-engine\n");
    expect(provision).toContain('component engine-python "$engine_python"');
    // No build user and no Node build of the engine: its environment is the wheels of the lock.
    expect(provision).not.toMatch(/useradd --system|pnpm/i);
    expect(text(unitAsset("invisible-dots-agent.service"))).toContain(`ExecStart=/opt/invisible-dots-engine/bin/python `);
  });

  it("builds that environment from the hashed lock, wheels only, and joins the engine's source by a .pth file", () => {
    const build = text("builder/build-engine-env.sh");
    expect(build).toContain('uv venv --quiet --python /usr/bin/python3 "$venv"');
    expect(build).toContain('uv pip install --quiet --no-cache --python "$python" --require-hashes --only-binary :all: -r "$lock"');
    // The site-packages directory is asked of the venv's own Python, never written down.
    expect(build).toContain('sysconfig.get_path("purelib")');
    expect(build).toContain('printf \'%s\\n\' "$source_dir" > "$site_packages/invisible-dots-engine.pth"');
    expect(build).toContain('TIKTOKEN_CACHE_DIR="$venv/share/tiktoken"');
    expect(build).toContain('chown -R root:root "$venv"');
    expect(build).toContain('chmod -R go-w,a+rX "$venv"');
    // Never a resolution from the index, a build from source or a plain `pip install`.
    expect(build).not.toMatch(/pip install(?!.*--require-hashes)|--no-binary|--no-deps|-e /);
  });

  it("leaves no instance state behind", () => {
    expect(provision).toContain("cloud-init clean --logs --machine-id --seed");
    expect(provision).toContain("rm -f /etc/ssh/ssh_host_*");
  });
});
