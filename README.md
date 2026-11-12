# Arms v1

Bonded agents called *arms* answer a fixed form (1 to 32 keys, one `bytes32` per key) about a target
contract. Two sealed answers are compared key by key; where they differ a tie break arm decides. After
settlement anyone can challenge a key, and an IdentityMD (IMD) oracle panel rules through `IMDCourt`.

There is **no owner, admin, upgrade or pause** in the core. Every number is an immutable constructor
argument. The token is used only through `transfer`, `transferFrom`, `balanceOf` and `burn(uint256)`.
Anyone can advance any timeout.

## Contracts (`src/`)

| Contract | Role |
| --- | --- |
| `Arms` | The core: bonds, forms, jobs, draws, commit/reveal, settlement, challenges, reads. |
| `ICourt` | Rulings interface: `feeAsset`, `fee`, `ask(...)`, `ruling(caseId)`; `Ruling {NONE, STORED, CLAIMED, NEITHER}`. |
| `IMDCourt` | `ICourt` adapter over the IMD `Intake`: one `oracle.request` per case, EIP-712 attestation verified in the callback. |
| `MockCourt` | A court anyone can rule for. Tests and local demos only. |
| `MockToken` | Burnable ERC-20 (`ARMT`) with an owner-only `mint`. The token Arms is bonded and paid in on Sepolia. |
| `Blocks` | Internal library reading block number and hash; switches to `ArbSys` for Arbitrum Orbit chains (Robinhood Chain later). |
| `OracleAttestation`, `OracleQuestion` | The protocol's verbatim libraries (from the `oracle-consumer` reference), plus `OracleQuestion.bodyWith` to insert the `consumer` member. One name adapted to OpenZeppelin 5.2 (`isValidSignatureNow`). |

Dependencies are vendored as plain files under `lib/` (forge-std v1.9.6, OpenZeppelin v5.2.0). No submodules.

## Launch (Sepolia, chain id 11155111)

IMD's launch deploys the contracts from the bytecode as built; this repository does not broadcast and
holds no key. Deploy order and constructor arguments (`script/Deploy.s.sol` rehearses the same on a
local node and `test/Deploy.t.sol` calls it):

1. `MockToken(owner_ = $owner)` — `$owner` = `0xcc4e8639884d08033597def041f966e8be5bc514`, the only privileged role (minting), outside the core.
2. `IMDCourt(intake, asset, action, oracleSigner)` =
   `0xa43e6f75ee006411f79ac1c84120606c2330de82` (IMD Intake v2),
   `0x56bcf2a5f47710649a4091219ef0b56e2d1b58bf` (imdTEST, the asset the Sepolia Intake sells `oracle.request` in),
   `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` (`bytes32("oracle.request@oracle-1")`, UTF-8 right-padded, not a hash),
   `0x5598aa9146215bc13eb26f2c692ad1461fd32982` (the live attester).
3. `Arms(Params)` with `token = $contract:MockToken`, `court = $contract:IMDCourt` and the parameters below. `Params` is one struct of static words (24 fields); `Arms` emits `Deployed(Params)` once so every value is readable from the logs.

Constructors call no other contract, so they run on an empty chain. Runtime sizes: Arms 23,765 bytes, IMDCourt 11,914 bytes (EIP-170 limit 24,576).

**Sepolia addresses and transaction hashes.** They are produced by IMD's launch after this work is
accepted and are recorded on the launch page, not here: this assignment has no wallet and never
broadcasts. The one real oracle question on Sepolia is therefore an *after launch* step (below), and its
transaction hashes are to be added to this section once run.

| Item | Value |
| --- | --- |
| MockToken | recorded by the launch |
| IMDCourt | recorded by the launch |
| Arms | recorded by the launch |
| Real oracle question (`IMDCourt.ask` tx, request id, callback tx) | to be added after `script/AskSepolia.s.sol` is run |

### Parameters

| Parameter | Sepolia value | Source |
| --- | --- | --- |
| trancheMultiple | 10 (× feePerArm locked per job; ≥ 3 enforced so the first slash always covers the refund) | brief |
| stakeMultiple | 2 (× feePerArm challenge stake) | brief |
| minFeePerArm | 1 ARMT (1e18) | chosen: the brief left it open on a test token |
| minBond | 20 × minFeePerArm = 20 ARMT | brief |
| maxBondPerArm | 1,000 ARMT | chosen |
| maxTotalBonded | 100,000 ARMT | chosen |
| burnBps | 1000 (10% of every payment burned) | brief |
| challengerRewardBps | 3000 (30% of the first slash after the refund) | brief |
| spotCheckOneIn | 10 (seed % 10 == 0 draws a blind third arm) | brief |
| commitWindow / revealWindow | 6 h / 2 h | brief |
| fillDeadline | 1 day (from the moment a job is, or returns to, OPEN / TIE_OPEN) | brief |
| challengeWindow / courtDeadline | 7 days / 7 days | brief |
| exitDelay | 14 days | brief |
| strikesToDeactivate / strikeCooldown | 3 / 1 day | brief |
| target chains | 11155111 (Sepolia), 4663 (Robinhood Chain); two unused slots | brief |
| arbitrumBlocks | false (Sepolia); true on an Arbitrum Orbit deployment | chain |
| IMDCourt panel / quorum / validForSeconds | 5 / 4 / 86,400 (constants) | brief; 5 is also the Intake's minimum panel |
| Form URI and evidence URI | ≤ 200 bytes, printable ASCII without `"` or `\` | brief / oracle body rules |

### Trust assumptions

- **Token owner.** `MockToken`'s owner mints at will. It can inflate the test token; it cannot touch Arms' balances or rules. On a real deployment the token is the requester's choice.
- **Oracle signer.** One hot key (`0x5598…2982`, read from `api.imd.fun/oracle/requests` on 2026-11-12) signs every ruling. It is **fixed at deploy** (the brief forbids an admin); a rotation by IMD requires deploying a new `IMDCourt` *and* a new `Arms`, since Arms' court is immutable too. The IMD docs recommend an owner-settable signer; the brief's "no owner" rule wins and this is the consequence.
- **Oracle price and liveness.** The court reads `Intake.priceOf` live (0.5 imdTEST today) and refuses a case above the challenger's `maxCourtFee`. If IMD stops selling the action the price reads 0 and `ask` reverts (no challenge can open). A refused body, a disagreeing panel or a lost callback leaves the ruling `NONE`; the case ends at `courtDeadline` with the stake returned and the stored verdict unchanged. The intake refunds nothing.
- **Block hash seed.** Draws are seeded by `blockhash(seedBlock)` (the block after the post / reopen) and the job id. A block proposer can bias one draw; once the hash is older than 256 blocks the seed moves to the newest available hash, so whoever calls `draw` then can pick the block. This is accepted for v1 and is only as valuable as the fee of one job.
- **Form text.** `formId` is the keccak256 of the form text published at `uri`; Arms never sees the text. The panel reads it from the URI the form registrar gave.
- **IMD plane.** The question text, its panel's honesty and the attestation's single signature are IMD's.

### Differences from the brief and from IMD's documentation

- `ICourt.ask` keeps the brief's signature, but the court pulls its fee from **`msg.sender`** (Arms), never from the `payer` argument. Arms pulls the fee from the challenger itself and approves the court in the same call. Reason: a `transferFrom` from an arbitrary address is a theft vector and a Slither hard failure (`arbitrary-send-erc20`). `ICourt` gained two views, `feeAsset()` and `fee()`, so Arms can quote and pull the fee first. `payer` is recorded in the case for the record.
- Cases are namespaced by asker inside the court (`keccak256(asker, caseId)`), so nobody can pre-occupy a case id and block a challenge. `ruling(caseId)` is read by the asker; `rulingOf(asker, caseId)` for anyone else.
- The oracle body carries `"consumer": <IMDCourt>` as the brief asks; the attestation is signed in IMDCourt's EIP-712 domain. The exact body shape (`POST /requests/check` on 2026-11-12) returned **no blockers**; its suggestions were `not_answerable` (a generic warning for a template with placeholder values) and `evidence` (it proposed `chain` where the brief fixes `panel`). The live Sepolia Intake was read with `priceOf`: imdTEST `0x56bc…58bf` → 0.5e18 (the `0x44a1…f89a` address seen in third-party repos prices at 0 and is not used).
- IMD's reference makes intake, asset, action and signer owner-settable. The brief says no owner; all four are immutable here.
- The brief's "deploy to Sepolia with transaction hashes": deployment is IMD's launch step and this worker holds no key, so hashes are not in this commit (see Launch).

### Behaviour decided where the brief was open

- A key is **AGREED** when every drawn arm gives the same non-UNKNOWN value; **MAJORITY** when a value has ≥ 2 votes and a unique maximum (three arms 2–1, or after a tie break); **disputed** (tie break) when ≥ 2 distinct non-UNKNOWN values and no majority; **UNRESOLVED** otherwise (all UNKNOWN, or one answer plus UNKNOWN with two arms).
- A replaced (struck) arm is never redrawn for the same job. A newly drawn replacement after a reveal miss can read the revealed answers on chain; accepted for v1.
- A tie break nobody can be drawn for by `fillDeadline` settles with the disputed keys UNRESOLVED and the full escrow returned (nothing is paid). `fillDeadline` counts from the job's latest return to OPEN / TIE_OPEN.
- With a spot-check (three arms) **and** a tie break, entitled payments can exceed the 3 × fee escrow; the tie break arm's payment is capped at what is left.
- A reward set aside by a NEITHER ruling waits for a CLAIMED ruling until the challenge window closes; `release` burns it if none came (the brief burns it as soon as all open challenges resolve, which would strand a later honest CLAIMED challenger inside the window).
- `bond()` cancels a pending exit; `withdraw()` keeps the exit flag so an arm can withdraw in several steps.
- The stake split on STORED gives the dust to the first arm.

## Flows

1. `registerForm(formId, keyCount, uri)` — anyone, once. `serve(formId, minFee)` / `stopServing(formId)`.
2. `bond(amount)`, `setSigner(signer)`, `requestExit()`, `withdraw()`, `reactivate()`.
3. `post(formId, chainId, target, atBlock, feePerArm)` escrows 3 × fee → `draw(jobId)` (≥ 2 blocks later; repeat until filled; `cancel` after `fillDeadline`) → `commit(jobId, keccak256(abi.encode(jobId, arm, values, salt)))` → `reveal(jobId, values, salt, evidenceURI)` → `settle(jobId)`. `timeout(jobId)` strikes and replaces arms that missed a deadline.
4. Disputes: `settle` opens TIE_OPEN → `draw` → tie break arm `commit`/`reveal` (one value per disputed key, key order) → `settle`.
5. `challenge(jobId, key, claimedValue, maxCourtFee)` inside the window → `resolve(jobId, key, claimedValue)` once ruled or after `courtDeadline` → `release(jobId)` after the window unlocks tranches.
6. Reads: `verdict(jobId)`, `latest(chainId, target, formId)`, `jobs`, `armsOf`, `results`, `entries`, `challenges`, `arms`, `isActive`, `unlockedBond`.

## Review findings and changes

An independent adversarial review is IMD's separate step before deployment. The findings below are from
the implementation's own review pass; each was fixed and tested in this commit.

| # | Finding | Change |
| --- | --- | --- |
| 1 | `timeout` after everyone revealed (but before `settle`) sent the job back to OPEN with a full roster; `draw` then re-entered COMMIT with nothing to commit, a loop that never settles. | `timeout` reverts `NotPending` when it removes nobody. Test `test_timeout_afterEveryoneRevealedIsNotATimeout`. |
| 2 | Court pulling the fee from an arbitrary `payer` (as the brief reads) is a theft vector and a Slither `arbitrary-send-erc20` failure. | Fee pulled from `msg.sender`; Arms pulls from the challenger and approves the court. |
| 3 | A stranger could open a case under an id Arms would later use and block the challenge. | Cases namespaced by asker in both courts. |
| 4 | The tie break arm's unset answers read as `bytes32(0)`, which could match a legitimate `0` answer when slashing or splitting a stake on a non-disputed key. | `_gave` only counts the tie break arm on keys in `disputedMask`. |
| 5 | Spot check plus tie break could pay more than the escrow. | Tie break payment capped at the remaining escrow; fuzz test asserts the whole escrow and no more leaves. |
| 6 | `trancheMultiple` below 3 would let a first slash fall short of the refund. | Constructor requires `trancheMultiple ≥ 3`. |
| 7 | Arms' runtime was 26.6 KB, over EIP-170. | Arms array moved out of `Job`, memory-struct getters replaced by public mappings, SafeERC20 replaced by checked plain calls, parameters emitted in `Deployed` instead of 22 getters. |
| 8 | Tests read `block.number`/`block.timestamp` after `vm.roll`/`vm.warp`; via-IR caches them inside one call, so the second roll was a no-op. | Tests use `vm.getBlockNumber()` / `vm.getBlockTimestamp()`. |
| 9 | Posting is almost free to grief: a job that is drawn and then cancelled locks two tranches for a day at the cost of gas. | Known limitation of v1, documented; a post fee would need a treasury the brief forbids. |
| 10 | `_candidates` iterates every server of a form. | Known limitation of v1 (gas grows with the number of servers); documented. |

## Tests

```
forge build
FOUNDRY_FUZZ_SEED=0xfdf36b168f85a86bc774f0ff48b0b1f782b198779e504981632cb5dc0716825f forge test
forge fmt --check
```

49 tests: unit tests for every path and timeout (`test/Arms.t.sol`), the full job and full challenge with
the mock court, fuzz tests, a handler-based invariant suite (`test/ArmsInvariant.t.sol`: balance equals
bonds + escrow + stakes + rewards; unlocked bond withdrawable after `exitDelay`; no owner/admin/pause/upgrade
entry point; UNKNOWN never paid or slashed; poster never above escrow plus one refund; no arm drawn twice and
the poster never; at most one tranche lost per job and no ruling applied twice; the first slash covers the
refund; an operator controlling every actor never gains), the court through a mock Intake
(`test/IMDCourt.t.sol`: exact body bytes, fee pulled and nothing left approved, callback refusals, 200,000
gas stipend, failure path, end-to-end challenge), the protocol's conformance vector
(`test/OracleConformance.t.sol`), and the deploy function. Tests read no environment and run in any order.

## After launch

1. **Mint and distribute ARMT.** The owner calls `MockToken.mint`; arms `approve` Arms and `bond(≥ 20 ARMT)`, then `serve(formId, minFee)`.
2. **Register a form.** `registerForm(keccak256(formText), keyCount, uri)` with the text published at `uri` (ASCII, ≤ 200 bytes).
3. **One real oracle question on Sepolia.** The owner's wallet needs 0.5 imdTEST (ask the IMD team). Run
   `forge script script/AskSepolia.s.sol --sig "ask(address,bytes32,address,uint256)" <IMDCourt> <formId> <target> <atBlock> --rpc-url <sepolia> --broadcast --account <wallet>`,
   wait for `api.imd.fun/oracle/requests/<id>` to show `attested`, then read with
   `--sig "read(address,address,bytes32)" <IMDCourt> <wallet> <caseId>`. Record the `ask` transaction hash, the request id and the callback transaction hash in the table above.
4. **Operate.** Anyone may call `draw`, `timeout`, `cancel`, `settle`, `resolve` and `release`; a small keeper that does so keeps jobs moving. Nothing else needs an operator.
