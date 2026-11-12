# Continuation review and regression record

Scope: the repairs requested for job `e1780683-4b86-470d-b664-d91fd15b250c`, including the lead's
constructor restrictions. Nothing was deployed. Compiler/dependencies/build settings were preserved.

This is the implementing contributor's verification record, **not an independent audit approval**.
The original four auditors' files were not present: the clean checkout contained no `test/scratch`
proofs or audit artifacts. The regressions below reconstruct the reported mechanisms from the task
and previous rejection. They live in delivered tests, not in disposable scratch space.

## Reported issues and regression mapping

| Brief item | Repair | Delivered checks |
| --- | --- | --- |
| 1: 24-word constructor | Exactly 13 flat arguments in the requested order; five code constants; derived minimum bond; target-chain admission delegated to the court. | `test_audit1_flatConstructorConstantsAndDerivedMinBond`, `test_constructor_rejectsBadParams`, `test_deploySepoliaConfig`, `script/check_launch.py` |
| 2: candidate list reshaping | Permanent per-form indices; job records list length and posting block; strict state-change cutoff; fixed-index hash attempts with persistent counter and seed. Exit/stop record a prospective job-id cutoff, including transaction order within one block. | All seven `test_audit2_*` cases cover exact selection, append-only indices, late additions, same/later-block changes, same-block exit/stop ordering, slashes, bounded work and empty pools. |
| 3: empty serve entries | Require `bond >= minBond` before registering/serving. Registry writes are authorized only from the bound core. | `test_audit3_serveRequiresMinimumBond`, `test_serve_rules`, direct registry-bypass checks in `test_deploySepoliaConfig` |
| 4: spot-check fourth arm | Three initial arms settle directly, key by key, with no tie breaker. Each arm earns at most one fee. | Both `test_audit4_*` cases; mixed majority/agreement/UNKNOWN/distinct answers; all-distinct full refund; existing spot-check and payment-conservation fuzz tests |
| 5: timeout strikes honest tie revealer | Timeout checks completion before touching an arm. Timely revealers, including reveals exactly at the deadline, cannot be struck. | `test_audit5_timeoutNeverStrikesTimelyTieRevealer`, `test_timeout_afterEveryoneRevealedIsNotATimeout`, timely commit preservation and all no-show compensation cases |
| 6: revealed answers copied by replacements | No replacement once any answer is public. All keys UNRESOLVED, escrow fully refunded, timely revealers compensated from missing tranches, all locks released once. Commit misses before disclosure remain replaceable. | The `audit6` unit/fuzz cases cover one/two missing arms, dust, timely UNKNOWN compensation, other-job locks, no repeated payouts, no cancellation, zero-reveal replacement, and tie commit/reveal no-shows. |
| 7: form-id squatting / URI instructions | Id commits to text hash, key count and URI; URI characters bounded and validated by both registry and court; quoted as untrusted data in the question. | Both `test_audit7_*` cases, `test_registerForm_rules`, exact body-byte assertion in `test_ask_buildsExactBodyAndPullsFee` |
| 8: signer reverse lookup | Commit/reveal explicitly name the arm; only that arm or its current signer is authorized. No signer-to-arm map or uniqueness constraint. | Both `test_audit8_*` cases, `test_setSigner_commitsAndReveals`, commitment binding fuzz test |
| 9: no-ruling stake policy | Preserved full stake return after the court deadline; explicitly accepted for v1 in README. Oracle fee remains spent. | `test_resolve_noRulingAfterCourtDeadline`, `test_fullChallengeNoAnswerEndsAtCourtDeadline` |
| 10: runtime size | Split form storage and read-only result computation into constructor-created contracts. Core retains funds and all authorization/state transitions. Form getters are on the registry. | Runtime assertions in deployment test; offline artifact checks below |
| 11: regressions/full suite/judge | Delivered reconstructed regressions and ran the full suite. Independent judge unavailable; see open item below. | `test/AuditRegressions.t.sol`, existing unit/invariant/conformance suites |
| 12: manifest compatibility/no setup | No constructor has an array, struct, string or bytes argument or receives ETH. Court, mocks and child contracts fit the entry limit. Both children bind automatically; MockIntake's initial price is constructor-configured. | `test_deploySepoliaConfig`, `script/check_launch.py`, all fixture setups without initialization calls |
| Previous rejection: wrong Arbitrum seed height | Select block mode from deployment chain id without probing precompile bytecode. Read the chain-local number/hash from ArbSys. | `test_audit12_arbitrumBlockModeComesFromChainId`: L1 stays at 1000 while L2 posting is 10010 and seed block is 10011. |

The protocol's fixed attestation digest and canonical question-hash vectors are unchanged. The
fresh-signature smoke case now asks about a supported target chain; it previously asked about chain 1,
which the accepted court target list does not include.

## Executed checks

- `forge build --sizes`: passed with pinned Solc 0.8.26.
- Full `forge test` with `FOUNDRY_FUZZ_SEED=0x1fd5805ab4bc5ebc9cdd4e5402d6a47d35f8aa16846bca0ff8665ea8f2ed1061`:
  **71 reported tests passed, zero failures/skips**, including all five invariant properties grouped
  by this Foundry runner. Fuzz cases used 256 runs; invariant handler used 64 runs × 40 calls.
- Plain `forge test`, using the existing pinned seed
  `0xfdf36b168f85a86bc774f0ff48b0b1f782b198779e504981632cb5dc0716825f`: **71 passed, zero failures/skips**.
- `forge fmt --check`: passed.
- `python3 script/check_launch.py`: all seven concrete application/mock artifacts passed constructor
  entry/type/payability, library linkage, EIP-170 and EIP-3860 checks. The latter includes ABI argument words.
- Exact oracle question wording sent to the free `https://api.imd.fun/requests/check` endpoint:
  HTTP 200, `judged: true`, **no blockers**. Suggestions were `not_answerable` for the local fixture
  and `evidence` preferring chain data over the accepted panel mode. This checks wording, not a live
  oracle answer. The check endpoint takes question inputs, not the full on-chain Intake body;
  sending the latter first returned HTTP 400 for unsupported checker fields. The corrected request
  and complete response are in [docs/oracle-question-check.json](docs/oracle-question-check.json).

| Contract | Constructor entries | Runtime bytes | Initcode including arguments |
| --- | ---: | ---: | ---: |
| Arms | 13 | 24,232 | 35,599 |
| ArmsForms | 2 | 3,356 | 3,625 |
| ArmsResults | 0 | 5,743 | 5,769 |
| IMDCourt | 4 | 12,780 | 14,324 |
| MockCourt | 2 | 2,770 | 2,993 |
| MockToken | 1 | 2,227 | 3,208 |
| MockIntake | 5 | 3,381 | 3,783 |

Arms has 344 bytes of runtime margin under EIP-170. Re-run size checks after future changes. Its
initcode includes both child contracts and remains below EIP-3860. Every library call is internal;
there are no unresolved link placeholders or post-deployment wiring calls.

## Still open

1. **Independent audit judge:** tool discovery exposed no judge capability, no judge runner was in
   the repository, and invoking `audit-judge` returned `command not found` (exit **127**). The judge
   could not be run and produced no fixed-code verdict. This is a tooling limitation, not a missing
   requester parameter; no blocked-input file was created. Independent adversarial review remains
   required before a later release. Slither/Mythril were not run by this contributor.
2. **Original proof provenance:** the task's scratch proofs were absent. The supplied scenarios now
   have passing regressions, but they cannot be claimed as byte-for-byte conversions of unavailable
   source proofs. The original proofs should also be rerun if the independent reviewer has them.
3. **Retained v1 risks, not redesigned:** proposer/sequencer-biased block hashes and the uncaptured
   seed's expired-hash fallback; multiple addresses controlled by one operator; sparse append-only
   pools and competition for free tranches; temporary capacity griefing by posting; full stake
   returned on a court timeout; reliance on a fixed oracle signer and action; no paid keeper.
4. **Deployment/operations:** later deployer must verify the retained Sepolia addresses, current
   signer and oracle sale, use the real owner, preserve any already deployed token, ensure form
   availability, choose confirmed target-chain blocks and arrange permissionless keeper calls.
   No deployment or live paid oracle request was authorized or performed here. A real form's
   answerability must be checked before paying; the question-check fixture is not a real form launch.
5. **Token/interface assumption:** the accepted core supports exact-transfer, non-rebasing,
   bool-returning tokens without callbacks and the documented court interface. Malicious,
   fee-on-transfer or hook-bearing token implementations are outside that accepted model. The
   unrestricted mock court/intake controls must never be used as production oracle authority.

Local review checked that state-transition roster/answer loops are bounded (three voters, 32 keys, 32 draw attempts),
that timeout compensation debits only already locked funds and preserves other jobs' locks, and that
all transferFrom paths pull only from their caller. Helpers cannot move funds or replace themselves.
These checks and the test results have no independent audit authority.
