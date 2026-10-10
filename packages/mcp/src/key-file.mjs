// The agent wallet's key, from PRIORS_KEY (0.7.x and earlier) or from a file named by PRIORS_KEY_FILE (0.8.0).
//
// A key file keeps the key out of an MCP client's or an agent runtime's config: ElizaOS stores a character's settings
// in its database in plain text and returns them from its agents API, `claude mcp add -e` puts the value in `ps` and in
// Claude Code's config, and an OpenClaw or Hermes config file is often shared or committed. The file is read only when
// it is the user's own and nobody else can read it, the way ssh treats a private key: on Linux and macOS a regular
// file owned by the user running the server with no group or other permission bits (chmod 600 or 400); root may also
// read one another user owns (a key mounted owner-only into a container), but only when every directory above it, on
// the path as given and on the path it resolves to, belongs to root or to the file's owner and nobody else can write
// it: OpenSSH's secure_path rule (in /tmp, or under a directory another user owns, anyone could have put their own key
// at that path). On Windows, a file whose ACL lets nobody read it but the user, SYSTEM and the Administrators group
// (the rule OpenSSH for Windows applies), read with PowerShell's Get-Acl by SID so the answer does not depend on the
// system's language; PowerShell is run from System32 by its full path, never looked up by name (Windows searches the
// working directory, which the MCP client chooses, before PATH). Anything else is refused, and the key is not read at
// all: the server then starts with its read-only tools, and every tool that moves money says what to fix.
//
// The file holds the key alone (64 hex characters, with or without 0x), with an optional trailing newline (LF or
// CRLF) and an optional UTF-8 byte order mark (Notepad's). Its content is never echoed, whatever is wrong with it.
// The path may start with ~/ (or ~\ on Windows), the user's home directory; otherwise it must be absolute, since an
// MCP client starts the server in a directory of its own choosing. Setting both PRIORS_KEY and PRIORS_KEY_FILE is
// refused: the server never guesses which key signs.
import { closeSync, constants, fstatSync, openSync, readSync, realpathSync, statSync } from "node:fs";
import { homedir as osHomedir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

/** A private key: 64 hex characters, optional 0x. */
export const KEY_RE = /^(0x)?[0-9a-fA-F]{64}$/;
/** The most a key file may hold: a key with a BOM, 0x and CRLF is 71 bytes; anything far bigger is not a key file. */
const MAX_BYTES = 4096;
/** Windows SIDs that may hold read access besides the user: LocalSystem and BUILTIN\Administrators (OpenSSH's rule). */
const WIN_TRUSTED = new Set(["S-1-5-18", "S-1-5-32-544"]);
/** FileSystemRights bits that let a holder read the content: ReadData, GENERIC_ALL, GENERIC_READ (FullControl, Modify,
 *  Read and ReadAndExecute all include ReadData). */
const WIN_READ_BITS = [0x1, 0x10000000, 0x80000000];

/**
 * The Get-Acl report for `p`, as lines: "ME <sid>", "OWNER <sid>", then "ACE <sid> <Allow|Deny> <rights>" per rule,
 * explicit and inherited, with SIDs (not account names, which are translated). The path reaches PowerShell through
 * the environment, never through the command text, so no character in it can change the command.
 */
const ACL_SCRIPT = [
  "$ErrorActionPreference = 'Stop'",
  "$sid = [System.Security.Principal.SecurityIdentifier]",
  "$acl = Get-Acl -LiteralPath $env:PRIORS_ACL_PATH",
  "'ME ' + [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value",
  "'OWNER ' + $acl.GetOwner($sid).Value",
  "foreach ($r in $acl.GetAccessRules($true, $true, $sid)) { 'ACE ' + $r.IdentityReference.Value + ' ' + $r.AccessControlType + ' ' + [int64]$r.FileSystemRights }",
].join("; ");

/** Who may read a Windows file, from Get-Acl's report (aclReport): null when only the user, SYSTEM and Administrators
 *  can, else a sentence naming the first other SID (and what to run). Pure, for tests. */
export function aclVerdict(report, file) {
  const lines = String(report ?? "").split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const me = lines.find((l) => l.startsWith("ME "))?.slice(3).trim();
  const owner = lines.find((l) => l.startsWith("OWNER "))?.slice(6).trim();
  const fix = `icacls "${file}" /inheritance:r /grant:r "%USERNAME%:R"`;
  if (!me || !/^S-1-[0-9-]+$/.test(me)) return `could not tell who can read it (no answer from Get-Acl). Fix its access with: ${fix}`;
  if (!owner || (owner !== me && !WIN_TRUSTED.has(owner))) return `it is owned by ${owner || "an unknown account"}, not by the user running the server. Fix it with: ${fix}`;
  for (const l of lines.filter((x) => x.startsWith("ACE "))) {
    const [, who, type, rights] = l.split(/\s+/);
    if (type !== "Allow") continue; // a Deny rule only takes access away
    const mask = Number(rights) >>> 0; // GENERIC_READ comes back negative as a 32-bit enum
    if (!WIN_READ_BITS.some((b) => (mask & b) !== 0)) continue;
    if (who === me || WIN_TRUSTED.has(who)) continue;
    return `${who === "S-1-1-0" ? "Everyone" : who === "S-1-5-32-545" ? "the Users group" : who === "S-1-5-11" ? "Authenticated Users" : `another account (${who})`} can read it. Let only your own user read it: ${fix}`;
  }
  return null;
}

/** Windows PowerShell 5.1 by its full path (it ships in System32 with every supported Windows), and the directory it
 *  runs in. Never "powershell.exe" alone: Windows looks a bare name up in the working directory before PATH, and the
 *  MCP client picks that directory (Claude Code starts the server in the project, which can be a cloned repo holding
 *  a powershell.exe of its own that would then run as the user and answer the ACL check). SystemRoot is set by Windows
 *  for every process; a value that is not an absolute drive path falls back to C:\Windows. Pure, for tests. */
export function powershellCommand(env = process.env) {
  const root = /^[A-Za-z]:\\/.test(String(env.SystemRoot ?? "")) ? path.win32.normalize(env.SystemRoot) : "C:\\Windows";
  return { exe: path.win32.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), cwd: path.win32.join(root, "System32") };
}

/** Get-Acl's report for a Windows file (PowerShell 5.1 ships with every supported Windows). Throws when it cannot run.
 *  `spawn` is replaceable for tests. */
export function windowsAclReport(file, { spawn = spawnSync, env = process.env } = {}) {
  const ps = powershellCommand(env);
  const r = spawn(ps.exe, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", ACL_SCRIPT], {
    cwd: ps.cwd, env: { ...env, PRIORS_ACL_PATH: file }, encoding: "utf8", timeout: 15_000, windowsHide: true,
  });
  if (r.error || r.status !== 0) throw new Error(r.error?.code === "ENOENT" ? "PowerShell was not found" : `Get-Acl failed${r.stderr ? `: ${String(r.stderr).split(/\r?\n/)[0].slice(0, 200)}` : ""}`);
  return r.stdout;
}

/**
 * For root reading a POSIX file another user owns: null when nobody but root and the file's owner could have put it at
 * `file`, else what is wrong (in words, never the content). OpenSSH's secure_path rule: every directory above the file
 * belongs to root or to the file's owner and has no group or other write bit (a root-owned sticky /tmp fails too). It
 * is checked on the path as given (whoever can write one of its directories could have put a symlink there) and on
 * the path that resolves to (realpath), up to /, and the resolved file must be the one that was opened (`st`, its
 * fstat: same device and inode), so nothing was swapped in between. `fs` needs realpathSync and statSync.
 */
export function securePathProblem(file, st, fs) {
  let real, rs;
  try { real = fs.realpathSync(file); rs = fs.statSync(real); } catch (e) { return `its path could not be resolved (${e?.code || "error"})`; }
  if (rs.dev !== st.dev || rs.ino !== st.ino) return "it changed while it was being checked";
  const dirs = [];
  for (const p of [file, real]) {
    for (let d = path.posix.dirname(p); ; d = path.posix.dirname(d)) {
      if (!dirs.includes(d)) dirs.push(d);
      if (d === path.posix.dirname(d)) break;
    }
  }
  for (const d of dirs) {
    let ds;
    try { ds = fs.statSync(d); } catch (e) { return `the directory ${d} could not be checked (${e?.code || "error"})`; }
    if (ds.uid !== 0 && ds.uid !== st.uid) return `the directory ${d} belongs to yet another user (uid ${ds.uid})`;
    if ((ds.mode & 0o022) !== 0) return `the directory ${d} can be written by other users (mode ${(ds.mode & 0o7777).toString(8).padStart(4, "0")})`;
  }
  return null;
}

/**
 * For PRIORS_STATE_DIR (POSIX): null when no other local user can rename or remove what is in `dir`, else what is wrong.
 * It keeps the records that stop a payment being signed twice and the daily limits' ledgers, and a user who can write
 * to it, or to a directory above it without the sticky bit, can move them aside so the server starts counting from
 * nothing (GHSA-52gp). `dir` must belong to this user with no group or other write bit; each directory above it,
 * on the path as given and as resolved, must belong to root or this user with no group or other write bit unless it
 * is sticky (/tmp is): OpenSSH's rule, since a user's primary group can be shared (macOS's staff). `fs` needs
 * realpathSync and statSync; `uid` is this process's.
 */
export function stateDirProblem(dir, { fs, uid }) {
  let real, st;
  try { real = fs.realpathSync(dir); st = fs.statSync(real); } catch (e) { return `it could not be checked (${e?.code || "error"})`; }
  if (st.uid !== uid) return `it belongs to another user (uid ${st.uid})`;
  if ((st.mode & 0o022) !== 0) return `other users can write to it (mode ${(st.mode & 0o7777).toString(8).padStart(4, "0")})`;
  const dirs = [];
  for (const p of [dir, real]) {
    for (let d = path.posix.dirname(p); ; d = path.posix.dirname(d)) {
      if (!dirs.includes(d)) dirs.push(d);
      if (d === path.posix.dirname(d)) break;
    }
  }
  for (const d of dirs) {
    let ds;
    try { ds = fs.statSync(d); } catch (e) { return `the directory ${d} above it could not be checked (${e?.code || "error"})`; }
    const sticky = (ds.mode & 0o1000) !== 0;
    if (ds.uid !== 0 && ds.uid !== uid) return `the directory ${d} above it belongs to another user (uid ${ds.uid})`;
    if (!sticky && (ds.mode & 0o022) !== 0) return `other users can write to the directory ${d} above it (mode ${(ds.mode & 0o7777).toString(8).padStart(4, "0")})`;
  }
  return null;
}

/** The absolute path PRIORS_KEY_FILE names on `platform` (~ expanded), or a problem. */
export function keyFilePath(raw, { platform = process.platform, homedir = osHomedir } = {}) {
  const p = platform === "win32" ? path.win32 : path.posix;
  const s = String(raw ?? "").trim().replace(/^"(.*)"$/, "$1"); // a path pasted with its quotes, as Explorer's "Copy as path" gives it
  if (!s) return { problem: "PRIORS_KEY_FILE is empty" };
  if (/[\0\r\n]/.test(s)) return { problem: "PRIORS_KEY_FILE is not a file path" };
  let full = s;
  if (s === "~" || s.startsWith("~/") || (platform === "win32" && s.startsWith("~\\"))) full = p.join(homedir(), s.slice(1));
  if (!p.isAbsolute(full)) return { problem: `PRIORS_KEY_FILE must be an absolute path (or start with ~/), not a relative one: an MCP client starts the server in a directory of its own choosing` };
  return { file: p.normalize(full) };
}

/**
 * The key the server signs with, from the environment: { key, source, problem }. `key` is the trimmed key text ("" when
 * none), `source` names where it came from, `problem` (when set) says why a key that was configured is not used. The
 * key file's content never appears in `problem`. `deps` replaces the platform, the file system, the home directory,
 * the user id and the Windows ACL report for tests.
 */
export function keyFromEnv(env = process.env, deps = {}) {
  const platform = deps.platform ?? process.platform;
  const fs = deps.fs ?? { openSync, fstatSync, readSync, closeSync, statSync, realpathSync };
  const inline = typeof env.PRIORS_KEY === "string" ? env.PRIORS_KEY.trim() : "";
  const fileRaw = typeof env.PRIORS_KEY_FILE === "string" ? env.PRIORS_KEY_FILE.trim() : "";
  if (!fileRaw) return { key: inline, source: inline ? "PRIORS_KEY" : null, problem: null };
  if (inline) return { key: "", source: null, problem: "PRIORS_KEY and PRIORS_KEY_FILE are both set: keep one (PRIORS_KEY_FILE, so the key stays out of the client's config)" };
  const at = keyFilePath(fileRaw, { platform, homedir: deps.homedir ?? osHomedir });
  if (at.problem) return { key: "", source: null, problem: at.problem };
  const file = at.file;
  let fd;
  // non-blocking: a FIFO named as the key file would otherwise hold the start until something writes to it (it is then
  // refused below, as anything but a regular file is)
  try { fd = fs.openSync(file, constants.O_RDONLY | (platform === "win32" ? 0 : constants.O_NONBLOCK ?? 0)); } catch (e) {
    return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} could not be opened (${e?.code === "ENOENT" ? "no such file" : e?.code === "EACCES" || e?.code === "EPERM" ? "permission denied" : e?.code || "error"})` };
  }
  try {
    // The checks read the opened file itself (fstat), so the file cannot be swapped between the check and the read.
    const st = fs.fstatSync(fd);
    if (!st.isFile()) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} is not a regular file` };
    if (st.size > MAX_BYTES) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} is too large to be a key file` };
    if (platform === "win32") {
      let report;
      try { report = (deps.aclReport ?? windowsAclReport)(file); } catch (e) {
        return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file}: could not check who can read it (${String(e?.message || e).slice(0, 200)}), so it was not read` };
      }
      const why = aclVerdict(report, file);
      if (why) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} was not read: ${why}` };
    } else {
      const uid = deps.uid ?? (typeof process.getuid === "function" ? process.getuid() : -1);
      if ((st.mode & 0o077) !== 0) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} was not read: other users can access it (mode ${(st.mode & 0o777).toString(8).padStart(3, "0")}). Let only your own user read it: chmod 600 ${file}` };
      if (uid !== 0 && st.uid !== uid) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} was not read: it belongs to another user (uid ${st.uid}), not to the user running the server (uid ${uid})` };
      // root reads a file another user owns (a key mounted owner-only into a container) only where nobody but root and
      // that owner could have put it: in /tmp, or anywhere below a directory someone else owns or can write, anyone could
      // have put their own file (their key) at that path
      if (uid === 0 && st.uid !== 0) {
        const why = securePathProblem(file, st, fs);
        if (why) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} was not read: it belongs to another user (uid ${st.uid}), and ${why}, so anyone could have put their own key at that path. Keep it where every directory above it belongs to root or to its owner and nobody else can write it (as ssh requires), or chown it to root` };
      }
    }
    const buf = Buffer.alloc(MAX_BYTES + 1);
    let n = 0;
    for (;;) { const got = fs.readSync(fd, buf, n, buf.length - n, null); if (got <= 0) break; n += got; if (n >= buf.length) break; }
    const text = buf.subarray(0, n).toString("utf8").replace(/^\ufeff/, "").trim();
    buf.fill(0);
    if (!KEY_RE.test(text)) return { key: "", source: null, problem: `PRIORS_KEY_FILE ${file} does not hold a private key (64 hex characters, with or without 0x, alone in the file)` };
    return { key: text, source: "PRIORS_KEY_FILE", problem: null };
  } finally { try { fs.closeSync(fd); } catch (_) { /* closed */ } }
}
