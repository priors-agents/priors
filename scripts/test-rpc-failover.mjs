// RPC_URL may name several endpoints. This proves the SDK actually uses them.
//
// The mechanism in sdk/env.mjs mirrors the one the site uses, and a mirrored implementation with a
// test on only one side is a mirrored implementation that drifts. These cases drive the real
// makeProvider against servers whose failures they script, and each is mutation-checked: take out
// the failover, the retry, or the per-attempt timeout and one of them goes red.
//
//   node scripts/test-rpc-failover.mjs

import http from 'node:http';
import { makeProvider, splitRpcs } from '../sdk/env.mjs';

let failed = 0;
const check = (name, fn) => Promise.resolve().then(fn)
  .then((d) => console.log(`  ok   ${name}${d ? ' — ' + d : ''}`))
  .catch((e) => { console.log(`  FAIL ${name}\n       ${e.message}`); failed += 1; });

/* `plan` is consulted per request: "ok" answers, "drop" kills the socket (a transport failure),
   "revert" returns a well-formed JSON-RPC error - the chain answering "no", which must NOT fail over. */
function fakeRpc(plan = []) {
  const state = { hits: 0, plan: plan.slice() };
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      const reqs = JSON.parse(body);
      const one = Array.isArray(reqs) ? reqs : [reqs];
      const mode = state.plan.length ? state.plan.shift() : 'ok';
      state.hits += 1;
      if (mode === 'drop') { req.socket.destroy(); return; }
      const answer = (r) => {
        if (mode === 'revert') return { jsonrpc: '2.0', id: r.id, error: { code: 3, message: 'execution reverted' } };
        if (r.method === 'eth_chainId') return { jsonrpc: '2.0', id: r.id, result: '0x1237' };
        return { jsonrpc: '2.0', id: r.id, result: '0x1' };
      };
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(Array.isArray(reqs) ? one.map(answer) : answer(one[0])));
    });
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${server.address().port}`, state, close: () => server.close(),
  })));
}

/* Accepts the connection, then never answers. ethers would otherwise wait 300 seconds. */
function blackHole() {
  const sockets = [];
  const server = http.createServer((req) => { sockets.push(req.socket); });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => { for (const s of sockets) s.destroy(); server.close(); },
  })));
}

const DEAD = 'http://127.0.0.1:1';

await check('RPC_URL splits on commas', () => {
  if (splitRpcs('http://a, http://b').length !== 2) throw new Error('two endpoints did not split');
  if (splitRpcs('http://only').length !== 1) throw new Error('a single endpoint broke');
});

await check('a dead FIRST endpoint fails over to the second', async () => {
  const good = await fakeRpc();
  try {
    const net = await makeProvider([DEAD, good.url]).getNetwork();
    if (Number(net.chainId) !== 4663) throw new Error(`got ${net.chainId}`);
    return `chainId ${net.chainId} from the backup`;
  } finally { good.close(); }
});

await check('the healthy first endpoint is preferred — priority order, not quorum', async () => {
  const first = await fakeRpc();
  const second = await fakeRpc();
  try {
    const p = makeProvider([first.url, second.url]);
    await p.getNetwork();
    await p.getBlockNumber();
    if (second.state.hits !== 0) throw new Error(`the backup was queried ${second.state.hits} times`);
    return `first ${first.state.hits} hits, backup ${second.state.hits}`;
  } finally { first.close(); second.close(); }
});

await check('a transient failure on the ONLY endpoint is retried', async () => {
  // One entry on purpose: with two the failover path would recover it and this would pass
  // with the retry switched off.
  const flaky = await fakeRpc(['drop']);
  try {
    const net = await makeProvider([flaky.url]).getNetwork();
    if (Number(net.chainId) !== 4663) throw new Error('the retry did not recover the call');
    if (flaky.state.hits < 2) throw new Error(`expected a second attempt, saw ${flaky.state.hits}`);
    return `recovered after ${flaky.state.hits} attempts`;
  } finally { flaky.close(); }
});

await check('a black-holed endpoint is abandoned on a timeout, not waited on', async () => {
  const hole = await blackHole();
  const good = await fakeRpc();
  const t0 = Date.now();
  try {
    const net = await makeProvider([hole.url, good.url]).getNetwork();
    const ms = Date.now() - t0;
    if (Number(net.chainId) !== 4663) throw new Error('never reached the healthy endpoint');
    if (ms > 20000) throw new Error(`waited ${ms}ms on a silent endpoint`);
    return `fell through in ${ms}ms`;
  } finally { hole.close(); good.close(); }
});

/* Answers, but slowly. Robinhood Chain's own endpoint has a 375ms median and has been measured at 5.4s
   and once at 10.4s, so "slow" is its real failure mode - not silence. */
function slowRpc(delayMs) {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => setTimeout(() => {
      const reqs = JSON.parse(body);
      const one = Array.isArray(reqs) ? reqs : [reqs];
      const answer = (r) => (r.method === 'eth_chainId'
        ? { jsonrpc: '2.0', id: r.id, result: '0x1237' }
        : { jsonrpc: '2.0', id: r.id, result: '0x1' });
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(Array.isArray(reqs) ? one.map(answer) : answer(one[0])));
    }, delayMs));
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${server.address().port}`, close: () => server.close(),
  })));
}

/* A node that will not serve the request, in the two shapes Robinhood Chain's public endpoints
   actually use: `robinhood-rpc.publicnode.com` answers HTTP 403 "Archive requests require a personal
   token", and `rpc.ordofi.network` answers 200 with `-32005` "the network is busy". Both are the NODE
   declining, not the chain answering, so both are worth asking somebody else. */
function refusingRpc(mode) {
  const state = { hits: 0 };
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      state.hits += 1;
      const reqs = JSON.parse(body);
      const one = Array.isArray(reqs) ? reqs : [reqs];
      const err = mode === 'token'
        ? { code: -32602, message: 'Archive requests require a personal token. Get one at: https://www.allnodes.com/publicnode' }
        : { code: -32005, message: 'the network is busy, please try again in a moment' };
      const answer = one.map((r) => ({ jsonrpc: '2.0', id: r.id, error: err }));
      res.statusCode = mode === 'token' ? 403 : 200;
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(Array.isArray(reqs) ? answer : answer[0]));
    });
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${server.address().port}`, state, close: () => server.close(),
  })));
}

await check('a SLOW but healthy endpoint is waited for even when BACKUPS are configured', async () => {
  /* The case that was missing, and the one that was broken. The per-attempt cap used to be the budget
     divided by (endpoints x attempts), so configuring three endpoints cut it to 2.5s and killed a
     5.4s answer that worked perfectly with one endpoint configured. Following the documented advice to
     add backups therefore broke a working setup. Testing this with a single URL - which is what the
     suite did - passes throughout and proves nothing. */
  const slow = await slowRpc(5400);
  try {
    const alone = await makeProvider([slow.url]).getNetwork();
    if (Number(alone.chainId) !== 4663) throw new Error('a healthy slow response was discarded with one endpoint');
    const t0 = Date.now();
    const withBackups = await makeProvider([slow.url, DEAD, DEAD]).getNetwork();
    if (Number(withBackups.chainId) !== 4663) throw new Error('adding backups discarded the same healthy response');
    return `answered in ${Date.now() - t0}ms with two backups behind it`;
  } finally { slow.close(); }
});

await check('a silent first endpoint does not starve the healthy backup', async () => {
  /* Endpoints have to be the inner loop. With them as the outer loop the first entry's retries ran
     before the second entry was tried at all, so a black-holed first endpoint spent the whole budget
     on itself and the healthy backup was never reached. */
  const hole = await blackHole();
  const good = await fakeRpc();
  const t0 = Date.now();
  try {
    const net = await makeProvider([hole.url, good.url]).getNetwork();
    const ms = Date.now() - t0;
    if (Number(net.chainId) !== 4663) throw new Error('never reached the healthy endpoint');
    /* The bound has to discriminate, not just pass. With endpoints as the outer loop the silent entry
       burns BOTH its attempts (~12s) before the backup is tried, and the read still succeeds inside the
       15s budget - so a 15s assertion cannot tell the two arrangements apart, and a mutation check
       caught exactly that. One silent attempt is ~6s; two is ~12s. 9s is the line between them. */
    if (ms > 9000) throw new Error(`took ${ms}ms: the silent endpoint was retried before the backup was tried at all`);
    return `reached the backup in ${ms}ms, one silent attempt deep`;
  } finally { hole.close(); good.close(); }
});

await check('a node REFUSING to serve is failed over, in both shapes this chain uses', async () => {
  for (const mode of ['busy', 'token']) {
    const refuser = await refusingRpc(mode);
    const good = await fakeRpc();
    try {
      const net = await makeProvider([refuser.url, good.url]).getNetwork();
      if (Number(net.chainId) !== 4663) throw new Error(`a "${mode}" refusal was not failed over`);
      if (refuser.state.hits === 0) throw new Error('the refusing endpoint was never tried, so priority order is broken');
    } finally { refuser.close(); good.close(); }
  }
  return 'both the 403 archive refusal and the -32005 busy refusal moved on';
});

await check('a revert is NOT failed over — it is the chain answering, and the same everywhere', async () => {
  // The other half of the rule above: retrying a revert against every endpoint is pure latency, and
  // for a write it can look like a failure for something that actually happened.
  const reverting = await fakeRpc(['ok', 'revert', 'revert', 'revert', 'revert']);
  const backup = await fakeRpc();
  try {
    const p = makeProvider([reverting.url, backup.url]);
    await p.getNetwork(); // consumes the leading "ok"
    const before = backup.state.hits;
    try { await p.call({ to: '0x' + '11'.repeat(20), data: '0x12345678' }); } catch (_) { /* expected */ }
    if (backup.state.hits > before) throw new Error('a revert was retried against the backup');
    return 'revert stayed on the first endpoint';
  } finally { reverting.close(); backup.close(); }
});

await check('a transaction broadcast is never retried', async () => {
  // Retrying a send can report failure for a transaction that actually landed, and a caller who
  // believes that may re-sign at the next nonce.
  const flaky = await fakeRpc(['ok', 'drop']);
  try {
    const p = makeProvider([flaky.url]);
    await p.getNetwork();
    const before = flaky.state.hits;
    try { await p.send('eth_sendRawTransaction', ['0xdeadbeef']); } catch (_) { /* expected */ }
    const sends = flaky.state.hits - before;
    if (sends !== 1) throw new Error(`the broadcast was attempted ${sends} times; it must be exactly 1`);
    return 'attempted exactly once';
  } finally { flaky.close(); }
});

console.log(failed ? `\n${failed} check(s) failed` : '\nSDK RPC failover holds');
process.exit(failed ? 1 : 0);
