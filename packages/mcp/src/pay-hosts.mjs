// PRIORS_PAY_HOSTS (0.8.0): the hosts pay_url may pay, for an agent that reads untrusted text all day (posts on X, mail,
// web pages) and could be talked into paying a URL someone planted there. Unset, pay_url pays any public https host,
// as before.
//
// Each entry is a host name (or an IP literal), with an optional port, separated by commas or spaces:
// `api.example.com, data.example.org:8443`. A match is exact: no wildcard, no parent domain covering its subdomains, and
// a port only when the entry names it (a bare name is the https default, 443). Both sides go through the WHATWG URL
// parser, the one fetch uses, so what is compared is what would be connected to: lowercase, an internationalised name
// in its punycode (xn--) form, full-width dots and percent-escapes in the name decoded, an IPv4 address in its dotted
// form whatever way it was written, and one trailing dot dropped (a fully qualified name is the same host). An entry
// that is not a plain host (a URL with a path, a wildcard, user info, spaces inside) stops the server at start, so a
// typo never widens the list.
//
// pay_url never follows a redirect (the payer sends every request with redirect: "manual" and hands a 3xx back as the
// answer, its Location fenced as merchant text); on top of that the allowlist is checked twice: on the URL before
// anything is fetched (so a refused host sees no request at all), and on every request the payer sends (guardFetch),
// so no code path can carry a payment header to a host off the list.

/** The comparable form of a host ("name" or "name:port"), as fetch would connect to it; throws on anything else. */
export function normalHost(entry) {
  const s = String(entry ?? "").trim();
  if (!s || /[\s/\\?#@*]/.test(s) || s.includes("://")) throw new Error(`"${s.slice(0, 80)}" is not a host name`);
  let u;
  try { u = new URL(`https://${s}/`); } catch (_) { throw new Error(`"${s.slice(0, 80)}" is not a host name`); }
  if (u.username || u.password || u.pathname !== "/" || u.search || u.hash || !u.hostname) throw new Error(`"${s.slice(0, 80)}" is not a host name`);
  return hostKey(u);
}

/** The comparable host of a parsed URL: hostname without one trailing dot, plus the port when it is not the default. */
export function hostKey(u) {
  const name = u.hostname.toLowerCase().replace(/\.$/, "");
  return u.port ? `${name}:${u.port}` : name;
}

/** PRIORS_PAY_HOSTS → a frozen Set of comparable hosts, or null when unset (every host, as in 0.7.x). Throws on a bad entry. */
export function parsePayHosts(raw) {
  const s = String(raw ?? "").trim();
  if (s === "") return null;
  const out = new Set();
  for (const part of s.split(/[\s,]+/).filter(Boolean)) {
    try { out.add(normalHost(part)); } catch (e) { throw new Error(`PRIORS_PAY_HOSTS: ${e.message}; list exact host names, comma-separated (like api.example.com, data.example.org:8443)`); }
  }
  if (out.size === 0) throw new Error("PRIORS_PAY_HOSTS is set but names no host");
  return Object.freeze(out);
}

/** Whether `url` (a string or URL) is on the list; null (no list) allows every URL. */
export function hostAllowed(hosts, url) {
  if (!hosts) return true;
  let u;
  try { u = url instanceof URL ? url : new URL(String(url)); } catch (_) { return false; }
  // the default port of the URL's own scheme is already dropped by the parser; an http URL (only with
  // PRIORS_ALLOW_LOCAL) on port 80 compares as the bare name, like an https one on 443
  return hosts.has(hostKey(u));
}

/** fetch that refuses any request to a host off the list, before it is sent, and never follows a redirect. */
export function guardFetch(fetchImpl, hosts) {
  if (!hosts) return fetchImpl;
  return async (input, init) => {
    const r = input instanceof Request ? input : new Request(input, init);
    if (!hostAllowed(hosts, r.url)) throw Object.assign(new Error(`refused: ${new URL(r.url).host} is not in PRIORS_PAY_HOSTS`), { code: "HOST_NOT_ALLOWED" });
    return fetchImpl(r.redirect === "manual" ? r : new Request(r, { redirect: "manual" }));
  };
}
