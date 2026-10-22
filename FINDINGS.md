# Findings — LendingMarket pre-audit review

Scope: `src/LendingMarket.sol` behind `TransparentUpgradeableProxy`. Live balances,
so every fix must be storage-layout compatible (append-only) and keep all existing
external signatures.

Disposition legend — **Fix**: patch intended for this upgrade. **Document**: kept as-is,
called out for the audit. **Watch**: edge case to verify with more time.

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| C1 | Critical | Liquidation seizes collateral in base-asset units | Fix |
| C2 | Critical | Oracle answer used without validation | Fix |
| H1 | High | Pause guardian can repoint the pricing oracle | Fix |
| H2 | High | Oracle staleness never checked | Fix |
| M1 | Medium | `withdrawCollateral` checks health against stale debt | Fix |
| M2 | Medium | Principal rounding to zero drains base/creates free debt | Fix |
| M3 | Medium | Token transfer semantics unchecked | Fix |
| L1 | Low | Surplus accrues to no one and cannot be swept | Document |
| L2 | Low | Full repay/liquidate leaves residual dust debt | Fix |
| L3 | Low | Seize cap can overcharge the liquidator | Fix |
| L4 | Low | Self-liquidation permitted | Document |
| L5 | Low | `initialize` accepts zero addresses and out-of-bounds risk params | Fix |
| I1 | Info | Interest accrues through a pause while liquidation is frozen | Document |
| I2 | Info | No reserve factor — protocol earns nothing | Document |

---

## C1 — Liquidation seizes collateral in base-asset units · Critical

`seizeAmount = repayAmount * liquidationIncentive / 1e18` converts repaid base
straight into collateral units; the oracle price is never used. At 2,000 base/WETH,
repaying 10 base seizes ~11 WETH (~22,000 base) instead of ~0.0055 WETH.

**Exploit.** Wait for any position to cross its borrowing power (routine event —
price drift or accrued interest is enough), then `liquidate(borrower, dust)`. The
seize cap is the borrower's *entire* `collateralBalance`, so one dust repayment
empties the position. Borrowers lose all collateral; bad debt stays on the book.

**Fix.** Convert to collateral terms: `seizeAmount = repayAmount * incentive * FACTOR / (getPrice() * FACTOR)`
— i.e., price the repaid base in collateral units before applying the incentive.

`src/LendingMarket.sol` — `liquidate()`, seize computation.

## C2 — Oracle answer used without validation · Critical

`getPrice()` does `uint256(answer)` on the raw feed answer. A negative answer
wraps to ~1.15e77, giving 1 wei of collateral unbounded borrowing power — the
entire supplier base drains in one `borrow()`. A zero answer collapses every
position's borrowing power to 0, making all debt liquidatable (which, via C1,
becomes total collateral theft). The feed is third-party by design; the defect is
that the market validates nothing it reads.

**Fix.** `require(answer > 0)` and fail closed — revert on non-positive answers.
This halts `borrow`/`withdrawCollateral`/`liquidate` during a feed malfunction;
deliberate, and covered by the guardian pause for incidents.

`src/LendingMarket.sol` — `getPrice()`.

## H1 — Pause guardian can repoint the pricing oracle · High

`setOracle` is `onlyGuardian`. The documented trust model gives the guardian a
warmer, more distributed key whose remit is stopping the market — "not changing
how it prices or values anything." Today that key can install an oracle quoting
any price and grant arbitrary borrowing power: a warm-key compromise becomes a
full drain of supplier funds with no timelock.

**Fix.** Restrict `setOracle` to `onlyAdmin` (the timelock). If oracle failover
needs to be fast, a dedicated oracle-guardian role is the honest design — not
overloading the pause key.

`src/LendingMarket.sol` — `setOracle()`, `onlyGuardian` modifier.

## H2 — Oracle staleness never checked · High

`latestRoundData` returns `updatedAt`; the market discards it. A stalled feed
that freezes *above* the real price lets borrowers draw against phantom
collateral value — the protocol originates undercollateralized debt that
suppliers absorb as bad debt. The feed isn't broken in this scenario; the market
simply never asks how old the answer is.

**Fix.** `require(block.timestamp - updatedAt <= MAX_ORACLE_AGE /* 1 hour */)` in
`getPrice()`. A `constant` keeps the diff minimal and touches no storage; an
admin-settable value appended to storage is the flexible alternative.

`src/LendingMarket.sol` — `getPrice()`.

## M1 — `withdrawCollateral` checks health against stale debt · Medium

Every other risk path accrues first; `withdrawCollateral` does not. Debt only
grows, so the stale check is always optimistic: a borrower can extract collateral
that fresh accrual would show is securing debt, landing the position underwater
with no price move at all. `isHealthy()` is only truthful immediately after
`accrueInterest()` — any caller that skips it reads a smaller debt than exists.

**Fix.** Call `accrueInterest()` at the top of `withdrawCollateral`, matching
`borrow`/`withdraw`/`repay`/`liquidate`.

`src/LendingMarket.sol` — `withdrawCollateral()`.

## M2 — Principal rounding to zero drains base / creates free debt · Medium

`_principalForSupply(amount) = amount * FACTOR / baseSupplyIndex` floors. Once
the index exceeds 1e18 — the normal state after any interest — `withdraw(1)`
burns 0 principal, so *anyone*, including non-suppliers, pulls 1 wei of base per
call; looped, it drains supplier liquidity while `totalSupplyPrincipal` never
moves. `_principalForBorrow` has the same shape: `borrow(1)` records zero debt,
passes `isHealthy`, and transfers base out.

**Fix.** Round principal *up* when destroying claims (withdraw) or creating debt
(borrow, liquidate); rounding down is only safe when creating claims (supply).
Also revert when a nonzero amount computes to zero principal.

`src/LendingMarket.sol` — `_principalForSupply`, `_principalForBorrow`, and
their call sites in `withdraw`/`borrow`/`repay`/`liquidate`.

## M3 — Token transfer semantics unchecked · Medium

`supply`, `repay`, and `liquidate` credit/burn principal for the *requested*
amount without checking `transferFrom`'s return value or the received balance
delta. A fee-on-transfer base token, or one returning `false` instead of
reverting, credits principal the contract never received — supplier claims then
exceed backing and the last withdrawers absorb the gap. Staging mocks are plain
ERC20, but the deployment "mirrors production topology" — the assumption must be
explicit.

**Fix.** `require(token.transferFrom(...), "transfer failed")` on every pull, or
balance-delta accounting if fee-on-transfer assets are in scope. Decide and
document which token classes are supported.

`src/LendingMarket.sol` — `supply`, `repay`, `liquidate`, plus `withdraw`,
`borrow`, `withdrawCollateral` return paths.

## L1 — Surplus accrues to no one and cannot be swept · Low

When `suppliesBefore == 0` while borrows remain open, `accrueInterest` grows the
borrow index but credits the interest to nobody. **In practice this branch is
unreachable**: a supplier's claimable PV always exceeds the contract's base
balance by the outstanding debt, so a full exit reverts on the token transfer —
`totalSupplyPrincipal` can only reach zero once borrows are repaid, at which
point nothing accrues anyway. The guard is dead code, not a loss path.

What remains real but small: floor-division dust in both index updates
accumulates as claimless base, and any direct transfer to the contract (a
fat-fingered deposit) is permanently unrecoverable — there is no sweep
function anywhere.

**Document.** A small admin `sweep` is cheap and signature-additive if the team
wants recovery; otherwise just state that surplus exists and is unreachable.

`src/LendingMarket.sol` — `accrueInterest()`.

## L2 — Full repay/liquidate leaves residual dust debt · Low

`repay` caps `amount` at `owed` — a floor-divided PV — then burns
`_principalForBorrow(amount)`, also floored. The account keeps a few wei of
`borrowPrincipal` that continues accruing and is effectively uncollectible.
Same shape on the `liquidate` burn path.

**Fix.** When the payment covers the full balance, burn the stored principal
directly instead of recomputing it.

`src/LendingMarket.sol` — `repay()`, `liquidate()`.

## L3 — Seize cap can overcharge the liquidator · Low

When `seizeAmount > collateralBalance[borrower]`, the seize is capped but the
full `repayAmount` is still pulled — the liquidator pays more than the collateral
is worth. Rational liquidators avoid the call, leaving nearly-empty positions
unliquidatable.

**Fix.** After the C1 price conversion, reduce `repayAmount` proportionally when
the seize is capped (or revert and let the caller retry).

`src/LendingMarket.sol` — `liquidate()`.

## L4 — Self-liquidation permitted · Low

Nothing stops a borrower from liquidating their own position — repaying debt and
pulling their own collateral out at the incentive rate while unhealthy. It's
their collateral, so the damage is bounded, but it partially bypasses the
`withdrawCollateral` health check and pays the borrower a bonus funded by the
position's remaining collateral.

**Document.** Most major markets allow it; flag for the audit rather than block.

## L5 — `initialize` accepts zero addresses and out-of-bounds risk params · Low

No validation on `admin_`, `oracle_`, `baseToken_`, `collateralToken_`. A bad
wire-up deploys a market that prices at address(0) — which reverts on
`latestRoundData`, bricking all priced paths — or locks admin functions forever.
The risk params are likewise unvalidated: `setParameters` enforces
`collateralFactor <= FACTOR` and `liquidationIncentive >= FACTOR`, but
`initialize` accepts anything — a `collateralFactor` above 1e18 wires a market
that originates borrows exceeding collateral value from block one. Proxied
deployment makes a bad init expensive to unwind.

**Fix.** `require` non-zero on all address params, `collateralFactor_` in
`(0, FACTOR]`, and `liquidationIncentive_ >= FACTOR` — mirroring `setParameters`.

`src/LendingMarket.sol` — `initialize()`.

## I1 — Interest accrues through a pause while liquidation is frozen · Info

`accrueInterest` runs unpaused (correct — freezing it would let positions dodge
interest), but `liquidate` and `borrow` are `whenNotPaused`. Debt grows during an
incident with no liquidation path open, so pause duration directly manufactures
unhealthy drift. Right trade-off; worth stating because pause is not
cost-neutral.

## I2 — No reserve factor — protocol earns nothing · Info

`accruedToSuppliers = borrowsBefore * interest` hands 100% of borrow interest to
suppliers. No protocol share exists — no revenue line, no insurance buffer
against bad debt. Design observation, not a defect; the README's model
description just never mentions a protocol share.

---

## Bug-class taxonomy — how these map to known lending-market failure modes

Grouped the way audit reports and post-mortems usually categorize them, with the
public precedent for each class.

### A. Oracle dependence and validation (C2, H1, H2)

The single most-reported finding class in lending audits: incomplete
`latestRoundData` validation — missing `answer > 0`, missing `updatedAt`
freshness, missing `roundId`/`answeredInRound` sanity. Price feeds are
third-party by definition; the market owns the failure to check them.

- **Compound, Nov 2020**: the Coinbase Pro DAI oracle printed ~$1.30; ~$89M of
  positions liquidated on a single-source price the market trusted blindly —
  the canonical "market must bound what it accepts from the feed" event.
- **Venus, May 2021**: XVS collateral price inflated, then used as borrowing
  power; left ~$100M in bad debt — the positive-side analog of C2's negative
  answer, and the exact outcome of H1's arbitrary-oracle capability.
- **Negative prints happen**: WTI futures traded negative in April 2020; signed
  feed answers can and do cross zero, which is why `uint256(answer)` alone is
  unsafe rather than merely unlucky.
- **Inverse Finance (Apr 2022), Mango Markets (Oct 2022)**: collateral/oracle
  price manipulation → unbacked borrows → insolvency. H1 hands that capability
  to the protocol's warmest key.

### B. Cross-asset unit mismatches (C1)

Converting value between debt units and collateral units without the price is
the classic seize-math bug in Compound-style markets — the same family as
exchange-rate confusion between cTokens and underlying in fork audits. Any
function crossing the base↔collateral boundary is suspect until proven to
divide by price exactly once, at 1e18 scale.

### C. Stale-state reads before risk checks (M1)

Compound's discipline — `accrueInterest()` first in *every* state-changing
entry point — exists because indices make all stored balances stale by
definition. Audits of Compound forks repeatedly flag omitted accrual before
collateral or debt checks; the read is always optimistic in the direction that
helps the caller.

### D. Rounding and dust economics (M2, L2)

The rule is "round in the protocol's favor"; floor-dividing claim burns and
debt creation does the opposite. Same family as the ERC-4626 share-inflation
class OpenZeppelin flagged — dust-scale per call, unbounded when looped, and
invisible to happy-path tests. Residual dust debt (L2) is the accounting tail
of the same decision.

### E. Privilege scope creep on operational keys (H1)

Recurring audit finding: the pause/incident key acquiring capabilities beyond
stopping the market. Least-privilege for warm keys is the point of the
guardian/admin split documented in the README — the code just doesn't enforce
it.

### F. ERC20 integration assumptions (M3)

Unchecked `transfer`/`transferFrom` returns and assumed 1:1 transfer semantics
are a standard lending-audit finding — non-reverting false returns, missing
return data (USDT-style), and fee-on-transfer assets all break the naive path.
The Agave/Hundred Finance incident (2022, ~$11M) showed how non-standard token
behavior turns into real losses on a Compound fork.

### G. Value-conservation edge cases (L1, L3)

Where does every wei end up? Trapped surplus with no sweep (L1) and asymmetric
caps that overcharge the counterparty (L3) are the bookkeeping findings audits
attach to otherwise-sound math — low severity, but exactly the "state it cannot
recover from" category when funds lock permanently.

### H. Incident semantics (I1)

What a pause does and doesn't stop — interest accrual, liquidation, exits — is
a standard audit question because it defines the incident playbook. Frozen
liquidation plus accruing debt is a defensible choice that must be a stated
one.

---

## Not pursued

- Reserve factor / protocol revenue share (I2) — product decision, not a bug.
- Blocking self-liquidation (L4) — bounded harm, conventional to allow.
- Utilization-based interest curve — out of scope; the fixed rate is the design.
- Reentrancy review — no callbacks exist in current token paths; revisit if
  ERC777-style collateral is ever listed (see M3 on token-class assumptions).
