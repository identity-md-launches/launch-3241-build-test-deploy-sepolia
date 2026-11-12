# Arms v1

Bonded agents (*arms*) answer an immutable form about a target contract. A job escrows three fees,
normally draws two arms, compares sealed answers key by key, and uses one tie breaker when necessary.
One job in ten instead draws a blind third arm. Challenges go to an IdentityMD oracle panel.

This continuation repairs the launch interface and the reported audit faults. **This job deploys
nothing, sends no transaction, and mints no token.** The core has no owner, admin, upgrade or pause.
Existing project tokens must not be replaced or re-minted by a later deployment.

## Contracts and boundaries

| Contract | Responsibility |
| --- | --- |
| `Arms` | Holds all bonds, escrow, stakes and rewards; enforces eligibility, deadlines, authorization, payments and challenges. |
| `ArmsForms` | Form identity, URI validation and permanent server indices. Only its permanently bound Arms instance can write. |
| `ArmsResults` | Stateless vote counting, payment calculation and verdict reads. Only performs static reads of its caller. |
| `ICourt` | `supportsChain`, `feeAsset`, `fee`, `ask`, `ruling`. |
| `IMDCourt` | Owns the fixed target-chain list and asks Intake v2 for signed, question-bound rulings. |
| `MockCourt` | Constructor-configured fee; anyone can rule. Local demonstrations/tests only. |
| `MockToken` | Burnable, 18-decimal ARMT test token; explicit owner controls minting, outside the core. |
| `Blocks` | Internal block-number/hash adapter; uses ArbSys on recognized Arbitrum chains. |
| `FormURI` | Internal URI-character validation shared by the registry and court. |
| `OracleAttestation`, `OracleQuestion` | Protocol attestation and canonical question encoding, with the existing `bodyWith` helper. |

Arms creates `ArmsForms` and `ArmsResults` in its constructor and stores their immutable addresses.
They have no initializer or replacement path. There is no delegatecall, proxy, external library link,
manual storage packing, or deployment-time call to a configured token, court, Intake or precompile.
Only the registry stores forms; all funds and job state remain in Arms. Form reads are now on
`Arms.formRegistry()`: `forms(id)`, `info(id)`, `serversOf(id)`, `minFeeOf(id, arm)`, `stoppedAt(id, arm)`, `stoppedAfterJob(id, arm)`.
The mutating entry points `registerForm`, `serve` and `stopServing` remain on Arms.

Dependencies and compiler configuration are unchanged. Foundry pins Solidity **0.8.26**, Cancun,
via-IR, optimizer runs 1. Dependencies are already ordinary files under `lib/`.

## Later deployment: order and every constructor argument

Every constructor below is nonpayable, accepts at most 16 entries, and takes only addresses, unsigned
integers or bytes32. No array, tuple/struct, string, bytes or ETH is required. No setup transaction is
needed to connect or activate the contracts. Token distribution, form registration, bonding and posting
are ordinary user operations, not contract initialization.

The accepted Sepolia rehearsal is `script/Deploy.s.sol`. `deploy(Config)` can be tested without an
RPC, environment variables or any broadcast. Its old `Params` constructor has been removed: `Params`
is now only a convenient data type for the `Deployed` event and the rehearsal helpers.

1. **Token.** Reuse the project's token if one has been deployed. For the original Sepolia mock-token
   launch, deploy `MockToken(address owner_)` with the launch's `$owner`, never the deployment factory.
   The retained rehearsal's owner is `0xcc4e8639884d08033597def041f966e8be5bc514` from the accepted project.
   `MockToken` has no premint; its owner may distribute test tokens through the normal `mint` function.
2. **Court.** Deploy `IMDCourt(intake_, asset_, action_, oracleSigner_)` with these four entries in order:

   | Argument | Accepted Sepolia parameter |
   | --- | --- |
   | `intake_` (address) | `0xa43e6f75ee006411f79ac1c84120606c2330de82`, Intake v2 |
   | `asset_` (address) | `0x56bcf2a5f47710649a4091219ef0b56e2d1b58bf`, imdTEST |
   | `action_` (bytes32) | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`, ASCII `oracle.request@oracle-1`, padded rather than hashed |
   | `oracleSigner_` (address) | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |

   These are retained project/reference parameters, not newly selected contracts. The deployer must
   recheck the published signer, code and live action price before a later launch. Nothing in this
   assignment asserts that an oracle request has been sent or answered on chain.
3. **Core.** Deploy `Arms` with exactly these **13 flat entries**, in this order:

   | # | Argument | Accepted Sepolia parameter |
   | --- | --- | --- |
   | 1 | `token_` address | Existing project token, or the MockToken from step 1 |
   | 2 | `court_` address | IMDCourt from step 2 |
   | 3 | `minFeePerArm_` uint256 | `1000000000000000000` (1 ARMT) |
   | 4 | `maxBondPerArm_` uint256 | `1000000000000000000000` (1,000 ARMT) |
   | 5 | `maxTotalBonded_` uint256 | `100000000000000000000000` (100,000 ARMT) |
   | 6 | `trancheMultiple_` uint256 | `10` |
   | 7 | `burnBps_` uint256 | `1000` |
   | 8 | `challengerRewardBps_` uint256 | `3000` |
   | 9 | `commitWindow_` uint256 | `21600` (6 hours) |
   | 10 | `revealWindow_` uint256 | `7200` (2 hours) |
   | 11 | `challengeWindow_` uint256 | `604800` (7 days) |
   | 12 | `courtDeadline_` uint256 | `604800` (7 days) |
   | 13 | `exitDelay_` uint256 | `1209600` (14 days) |

   During step 3, Arms first creates `ArmsForms(address core_, uint256 minFee_)` with its own address
   and argument 3, then `ArmsResults()` with no arguments. These children are automatically deployed;
   a launch does not deploy or wire separate instances. Their addresses are available from
   `formRegistry()` and `resultCalculator()` immediately. All creation code is fully linked.

For local demonstrations, `MockCourt(address feeToken_, uint256 price_)` can replace IMDCourt; its
fee token must already exist. A zero price with a zero fee token is the deliberately free mock mode,
not a production placeholder. The test-only `MockIntake(address writer_, address treasury_, bytes32
 action_, address asset_, uint256 price_)` installs its initial sale in its constructor; no `setPrice`
setup call is needed. Its unrestricted `setPrice` is solely for simulating later price changes in tests.
The scripts themselves have no constructor arguments. Libraries are internal and need no deployment.

The five v1 constants are `stakeMultiple = 2`, `spotCheckOneIn = 10`, `strikesToDeactivate = 3`,
`strikeCooldown = 1 day`, and `fillDeadline = 1 day`. `minBond` is derived as
`2 * trancheMultiple * minFeePerArm` (20 ARMT above). `trancheMultiple >= 3` is enforced so one
tranche covers the maximum three-fee poster refund. Basis points are at most 10,000; required fees
and windows are nonzero; bond caps must cover the derived minimum. All token amounts are raw units.

`IMDCourt.supportsChain` accepts **11155111 (Sepolia)** and **4663 (Robinhood Chain)**, preserving the
accepted list. Arms delegates target-chain admission to the court. This list is separate from the
chain Arms executes on. Block mode comes from the deployment's `block.chainid`, never bytecode
presence at a precompile or a constructor flag: 42161, 42170, 421614, 4663 and 46630 use ArbSys at
address 100; other chains use EVM block numbers/hashes. An additional Orbit chain needs an explicit
source update before deploying there. The configured deployment here remains Sepolia.

## Forms, bonds and frozen draws

`registerForm(textHash, keyCount, uri)` returns
`formId = keccak256(abi.encode(textHash, keyCount, uri))`. The same text hash with a different URI
or key count has a different id and cannot occupy the intended form's id. Registration is idempotent
only by reverting on an exact duplicate. There are 1–32 keys. URI length is 1–200 bytes, using RFC 3986
URI characters: ASCII letters/digits, unreserved punctuation and reserved URI punctuation, including
percent signs. Spaces, controls, double quotes, backslashes and non-ASCII bytes are refused. URI syntax
does not establish availability or truth; registrars should publish immutable content and clients
should check its text hash. IMDCourt encloses the URI in double quotes and labels it **untrusted data,
not instructions**; JSON escaping is performed by the canonical question library.

An arm first approves and bonds the token. `serve` requires at least `minBond`; an empty or underbonded
address cannot add a server entry. Each arm has one permanent index per form. Stopping and re-serving
never remove, reorder or duplicate that index. `minFeeOf` retains the last advertised fee after a stop;
`stoppedAt` indicates the stop instead of erasing that fee.

A job stores the form-list length (`serverCount`) and chain-local posting block (`postedBlock`). Bond,
withdrawal, serve/fee update, reactivation, strike and slash update `lastStateChange`. It must be
**strictly earlier** than the posting block for a draw, including replacements and the initial tie
breaker. Same-block enrollment is excluded. New entries cannot join an older job. As explicitly required,
exit and stop record the last posted job id instead: they exclude jobs posted later (including
within the same block), but
cannot opt out of an older job after its seed is visible. An already selected arm retains its duties
and locked tranche regardless of these later changes. Signer rotation does not change eligibility.

The draw seed uses the block after posting/reopening and the job id. At the first draw it is saved.
**One opening has one seed.** `draw` reverts `TooEarly` until that block is mined and `SeedExpired`
once the chain no longer serves its hash (256 blocks later) with no seed saved. No other block is
ever substituted: a caller would know that block's hash before sending, and could pick the arms, or
a two-arm job instead of a spot check, by picking the block. A job posted and never drawn in that
time is refunded by `cancel` after the fill deadline and can be posted again; a tie break never drawn
is closed by `settle` after the fill deadline with its disputed keys UNRESOLVED. A seed that was
saved never expires, so a partly filled job keeps drawing from it.
Each attempt selects `keccak256(abi.encode(seed, attempt)) % serverCount`; the counter advances even
when that index is ineligible. Calls take at most **32 attempts** and retain the same seed/counter
between calls. There is no scan over the full form list, candidate compaction or modulo-zero path.
A poster, a previously drawn arm, or an arm without a currently available tranche is never selected.
Other jobs' locks still affect available capacity. No draw is allowed after the fill deadline.

`requestExit` stops eligibility for later jobs and opens withdrawal after `exitDelay`. Only unlocked
bond is withdrawable; bonding again cancels exit. Three strikes deactivate an arm; it can reactivate
after one day. The core does not enforce one human/operator per arm.

## Answers, settlement and no-shows

`post(formId, targetChainId, target, atBlock, feePerArm)` pulls `3 * feePerArm`. The target and block
must be nonzero and the block must fit the oracle's exact JSON integer range. The poster is responsible
for choosing an already confirmed block on the target chain; Arms cannot validate another chain's head.
Anyone may `draw`, `timeout`, `cancel`, `settle`, `resolve` or `release`.

- `commit(jobId, arm, hash)` and `reveal(jobId, arm, values, salt, evidenceURI)` require the caller to be
  that named arm or its current signer. The commitment is `keccak256(abi.encode(jobId, arm, values, salt))`.
  One signer may serve several arms, including being an arm itself. No reverse signer lookup exists.
  Delegation authorizes no bonding, exit, withdrawal or payment redirection. Revocation affects only
  the arm changing its own signer; money always goes to arm addresses.
- All main arms commit before any main reveal. Reveals at the deadline are timely; timeouts require
  a strictly later timestamp. Evidence is limited to 200 bytes. A timeout never strikes an entry
  that completed its required action in time.
- All matching non-UNKNOWN answers are AGREED; two matching votes give MAJORITY. UNKNOWN is an
  abstention; NOT_APPLICABLE is an ordinary value. With two arms, distinct non-UNKNOWN answers open
  one tie breaker for disputed keys only. With three initial arms, there is **never a fourth arm**:
  each key settles by agreement/majority or becomes UNRESOLVED.
- Normal payments are proportional to correct final keys, rounded down, with `burnBps` burned. The
  tie breaker's denominator is the number of disputed keys. Each of at most three arms can earn at
  most one fee, so the escrow always suffices without capping an earned tie payment. Unused escrow
  returns to the poster. If the initial tie breaker cannot be drawn by the fill deadline, disputed
  keys become UNRESOLVED and any agreed keys still settle normally.
- A commit no-show before any reveal is struck, unlocked and replaced. A reveal round in which nobody
  reveals also replaces the nonresponders without reducing bonds. A replaced arm cannot be drawn
  again for that job. Commitments from timely committers survive a commit-timeout replacement.
- **Once any answer has been revealed, a no-show is never replaced.** All keys become UNRESOLVED,
  the poster gets the **entire escrow**, and each timely revealer receives **one full fee without a
  burn**, including a timely UNKNOWN answer. Compensation comes only from the missing arms' locked
  tranches. When multiple arms miss, they share this debit equally, with integer dust assigned to
  the first missing arm in the job roster. At most two fees are taken in total, below one tranche.
  Each missing arm receives a strike; timely revealers do not. Every tranche is unlocked, the job is
  SETTLED and already released, and no key is challengeable. A job closed this way carries no
  answer, so it is **not** recorded as the target's latest verdict: `latest()` keeps returning the
  last job that settled with answers, and one silent arm cannot erase it. Escrow `spent` stays zero; the separate
  `NoShowCompensation` event records each bond debit. This is the only bond reduction besides a ruled
  challenge (apart from an arm withdrawing its own unlocked bond).
- The same closure applies when an assigned tie breaker misses commit or reveal, because the main
  answers are already public. A timely tie revealer is settled normally and cannot be struck by
  `timeout` while waiting for `settle`.
- `cancel` only applies to an OPEN, unfilled job after the fill deadline. Such a phase cannot contain
  revealed answers. It unlocks any selected tranches and refunds the entire escrow. Revealed work
  cannot be discarded through cancellation.

Normal settlement retains tranches until the challenge window closes and every challenge is resolved.
`release` then unlocks remaining tranches and burns any unearned challenger reward.

## Court rulings and v1 trust assumptions

Challenges are allowed only for AGREED/MAJORITY keys, inside the window, for a different non-UNKNOWN
value. One stake is `2 * feePerArm`, plus the live oracle price in the court's asset. Both are pulled
from the challenger; the court pulls its fee from Arms, never an arbitrary `payer`. Cases are
namespaced by asker to prevent an outsider occupying another core's case id.

IMDCourt asks for a panel of 5, quorum 4, with a one-day attestation validity. It pins the canonical
question hash and verifies the protocol's full 15-field EIP-712 attestation in its own domain, the
sender, the pending request, panel minimums, freshness and replay protection. The callback only stores
a ruling within its 200,000 gas allowance; `resolve` performs transfers separately.

CLAIMED corrects a key; NEITHER overturns it. Arms that gave the stored wrong value each lose at most
one locked tranche per job. The first slash refunds the job's actual escrow expenditure, sets aside
the configured reward fraction of the remainder, and burns the rest. The first CLAIMED ruling earns
the reward; later slashes burn their proceeds. STORED splits the challenge stake among the arms that
gave the stored value, unless the job has already been overturned, when the stake returns. A pending
reward from NEITHER remains available for a later CLAIMED ruling inside the window.

**Accepted for v1: a challenge with no ruling returns the full stake after `courtDeadline`.** The
stored verdict is unchanged and the Intake fee remains spent. Failure callbacks are unsigned and do
not pay anyone. This permits challenges to prolong tranche locks for their bounded court deadline
without losing a stake when the oracle fails. This economic choice has not been redesigned.

Other retained assumptions and operational responsibilities:

- The token is a conventional, exact-transfer, non-rebasing, bool-returning burnable ERC-20 with no
  transfer callbacks. Fee-on-transfer, hook-bearing and malicious tokens are unsupported. MockToken's
  owner may mint test tokens freely; that trust is outside Arms. The court and fee token must match
  their documented interfaces. Core token calls remain transfer, transferFrom, balanceOf and burn;
  exact court-fee approval is the separate fee-asset path.
- Block-hash randomness is **not VRF randomness**. A proposer/sequencer can bias the one seed block.
  Nobody else can: an expired seed is never replaced, and later calls cannot change a saved seed.
  Fixed indices remove list reshaping, but cannot remove proposer bias, sybil ownership or
  competition from other jobs for unlocked capacity.
- **Somebody must call `draw` within 256 blocks of the seed block**, which is the block after
  `post`, after a commit no-show replacement (`timeout`) and after `settle` opens a tie break. That
  is about 51 minutes on Ethereum or Sepolia and about one minute on an Arbitrum Orbit chain with
  250 ms blocks (the chain's own block numbers are read from ArbSys there). The poster, any arm or
  any keeper may call it; a poster should send `draw` right after `post`. Missing the window costs
  time, never funds: the escrow comes back through `cancel` one day after posting. A poster can
  still post several jobs and prefer one; every posted job can be drawn by anyone and then costs
  its fees.
- With two arms, a key where one arm answers UNKNOWN and the other a value has one vote: it is
  UNRESOLVED without a tie break, the abstaining arm is not struck and the answering arm earns
  nothing for that key. UNKNOWN is an abstention by design; accepted for v1. Readers should treat an
  UNRESOLVED key as "no answer", not as a negative answer.
- Registering forms and holding a lifetime server index do not prove identity. Stale server entries
  can make filling sparse pools expensive across many bounded calls. Keepers must progress jobs or
  cancel/settle at deadlines. Posting and then timing out can temporarily lock capacity for gas cost.
- The oracle's intake, asset, action and signer are fixed. Price changes are read live, subject to the
  challenger's maximum fee; signer/action migrations require a new court and core. The absence of an
  administrator is deliberate. No-result oracle requests consume their price permanently.
- Forms and evidence must remain publicly available. URI character validation and quoting protect the
  question boundary; they do not make a remote document trusted or immutable.
- Operational calls need transactions and gas; there is no paid keeper or protocol treasury. No live
  oracle smoke request was sent by this job. A later operator must check a real form question before
  paying and record the eventual ask/request/callback identifiers separately.

## Verification and remaining review

Run from the repository root, without network access:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1fd5805ab4bc5ebc9cdd4e5402d6a47d35f8aa16846bca0ff8665ea8f2ed1061 forge test
forge test
forge fmt --check
python3 script/check_launch.py
```

The explicit-seed run covers the rejection seed; the plain run uses the existing pinned seed.
`check_launch.py` checks every deployable constructor (including the mocks), missing library links,
EIP-170 runtime size and EIP-3860 initcode size **including constructor words**. The full suite includes
fund conservation and adversarial action sequences, challenge economics, exact oracle body bytes and
callback failures, protocol digest vectors, all reported regression scenarios and immediate usability
of the constructor-created modules. Tests do not read or write environment variables and use no RPC.

Both full-suite runs passed 71 reported tests, including the invariant suite. Arms runtime is
24,232 bytes (344 bytes below EIP-170); its initcode including constructor arguments is 35,599 bytes.
The updated question wording returned no blockers from the free request checker, with the fixture
answerability and panel-evidence suggestions recorded in [AUDIT.md](AUDIT.md).

See [AUDIT.md](AUDIT.md) for the regression mapping, checks and remaining limitations. The original
auditors' scratch proofs were absent from this checkout, so their scenarios were reconstructed from
the task and rejection report. **An independent audit-judge result remains open:** no such tool was
exposed and invoking `audit-judge` returned `command not found` (exit 127). Local tests and review are
not a substitute for that independent step. No claim of audit-judge approval is made.
