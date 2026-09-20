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

/* `plan` is consulted per request: "ok" answers, "drop" kills the socket (a transport failure). */
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
      const answer = (r) => (r.method === 'eth_chainId'
        ? { jsonrpc: '2.0', id: r.id, result: '0x1237' }
        : { jsonrpc: '2.0', id: r.id, result: '0x1' });
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
