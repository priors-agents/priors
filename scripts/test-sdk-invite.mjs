// The SDK's side of treasury v3: parsing an invite code, and picking the right firstLine overload.
//
// Both halves are worth a test for the same reason. The parser is what stands between a user and a
// transaction that costs gas to be told what a regex could have said for free, so its rejections matter as
// much as its acceptance. The overload choice is invisible when it is right and silent when it is wrong:
// v2's `firstLine(uint256)` and v3's `firstLine(uint256,uint64,bytes)` share a name, and ethers will happily
// encode the one you did not mean. No network.
import assert from "node:assert/strict";
import { ethers } from "ethers";
import { parseInvite, TREASURY_ABI } from "../sdk/priors.mjs";

const hour = 3600;
const future = Math.floor(Date.now() / 1000) + 72 * hour;
const past = Math.floor(Date.now() / 1000) - hour;
const sig = "0x" + "ab".repeat(65); // 65 bytes, the shape ECDSA.recover wants
const code = (id, exp) => `priors-invite:${id}:${exp}:${sig}`;

// ---- what it accepts ----
const ok = parseInvite(code(462, future), 462);
assert.equal(ok.agentId, 462);
assert.equal(ok.expiry, future);
assert.equal(ok.signature, sig);
console.log("  ok   a well-formed invite parses into agent, expiry and signature");

// the agent id is optional to check against, for a caller that does not have one to hand
assert.equal(parseInvite(code(462, future)).agentId, 462);
console.log("  ok   the agent id check is skipped when no agent is supplied");

// ---- what it refuses, and why each refusal earns its place ----
assert.throws(() => parseInvite("", 462), /not an invite code/);
assert.throws(() => parseInvite("priors-invite:462:" + future, 462), /not an invite code/);
assert.throws(() => parseInvite(`priors-invite:462:${future}:0xdeadbeef`, 462), /not an invite code/);
console.log("  ok   a malformed code is refused before it can cost gas");

assert.throws(() => parseInvite(code(463, future), 462), /for agent #463, not #462/);
console.log("  ok   an invite for another agent is refused, and says which");

assert.throws(() => parseInvite(code(462, past), 462), /expired/);
console.log("  ok   an expired invite is refused locally, not by the contract");

// whitespace around a pasted code is the normal case, not an error
assert.equal(parseInvite(`  ${code(462, future)}\n`, 462).agentId, 462);
console.log("  ok   a pasted code survives its surrounding whitespace");

// ---- the overloads are both reachable and distinct ----
const iface = new ethers.Interface(TREASURY_ABI);
const v3 = iface.encodeFunctionData("firstLine(uint256,uint64,bytes)", [462, future, sig]);
const v2 = iface.encodeFunctionData("firstLine(uint256)", [462]);
assert.notEqual(v3.slice(0, 10), v2.slice(0, 10));
assert.equal(iface.getFunction("firstLine(uint256,uint64,bytes)").inputs.length, 3);
console.log("  ok   v2 and v3 firstLine are separate selectors the SDK can each reach");

// the invite-specific reverts decode, so an integrator reads a reason rather than four bytes
const notInvited = iface.encodeErrorResult("NotInvited", [462, ethers.ZeroAddress]);
assert.equal(iface.parseError(notInvited).name, "NotInvited");
for (const e of ["InviteExpired", "InviteUsed"]) assert.ok(iface.getError(e), `${e} missing from the ABI`);
console.log("  ok   NotInvited, InviteExpired and InviteUsed decode instead of printing a selector");

console.log("sdk invite handling: all checks passed");
