# LendingMarket

Single-collateral money market. Suppliers deposit the base asset and earn interest, borrowers post collateral and draw the base asset against it, and positions that fall below their borrowing power can be liquidated.

## Running it

The project is self-contained. `forge-std` is vendored under `lib/`, so no network access or `forge install` is needed.

```bash
forge build
forge test
forge test -vvv --match-test <name>     # a single test, with traces
```

Requires Foundry. If you do not have it: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Layout

```
src/
  LendingMarket.sol                 the implementation, and the only file you need to change
  TransparentUpgradeableProxy.sol   the proxy the market is deployed behind
  interfaces/                       IERC20, IPriceOracle (Chainlink-style aggregator)
  mocks/                            test doubles for the base asset, collateral and oracle
script/
  Deploy.s.sol                      staging deployment, mirrors the production topology
test/
  LendingMarket.t.sol               the suite the market ships with today
```

## How it works

**Accounting.** Supplier and borrower balances are stored as *principal* and scaled by two global indices, `baseSupplyIndex` and `baseBorrowIndex`. `accrueInterest()` advances both to the current timestamp. Present value is `principal * index / 1e18`, so a balance grows without anyone touching per-account storage.

**Scaling.** Everything is 1e18 fixed point unless stated otherwise. The oracle quotes the collateral in base-asset terms, also 1e18. So with WETH at 2,000 base, `getPrice()` returns `2000e18`.

**Borrowing power.** `collateralBalance * price * collateralFactor`, all 1e18 scaled. A position is healthy while its borrowing power covers its debt. `isHealthy()` is the single source of truth for this, and it is checked on any path that increases risk.

**Liquidation.** Once a position is unhealthy, anyone may repay part of its debt and receive collateral in exchange, plus the liquidation incentive. The incentive is 1e18 scaled and always at or above par, so `1.10e18` means the liquidator receives 110% of what they repaid, valued in collateral.

**Deployment.** The market is an implementation behind a `TransparentUpgradeableProxy`. All market state lives in the proxy's storage, which is why any change you make has to be layout-compatible with what is already deployed. The admin owns upgrades and risk parameters. A separate pause guardian exists so the market can be stopped quickly without reaching for the admin key.

## Roles

| Role | Held by | Remit |
|---|---|---|
| `admin` | governance timelock | upgrades, risk parameters, wiring |
| `pauseGuardian` | operations multisig | stopping the market in an incident |

The split matters. The guardian key is warmer and held by more people than the admin key, so anything the guardian can reach should be limited to stopping the market, not changing how it prices or values anything.

## Listed markets

See `script/Deploy.s.sol` for the current staging configuration.

## Findings (pre-audit review)

Severity-ordered; one line each. Full analysis, bug-class taxonomy, and dispositions are in `FINDINGS.md`. Proofs are executable — see "Test layout" below.

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| C1 | Critical | `liquidate` seized collateral in base-asset units — a dust repayment could take a borrower's entire collateral balance. | Seize is now priced through the oracle before the incentive applies. |
| C2 | Critical | `getPrice` cast the signed answer to `uint256` — a negative print wrapped to ~1.15e77, giving 1 wei of collateral unbounded borrowing power; a zero print made every position liquidatable. | `getPrice` reverts on `answer <= 0` and fails closed. |
| H1 | High | The pause guardian — the warmest key, documented as stop-only — could repoint the oracle and grant arbitrary borrowing power. | `setOracle` is `onlyAdmin`. |
| H2 | High | `latestRoundData`'s `updatedAt` was ignored; a stalled feed kept pricing borrows indefinitely. | `getPrice` reverts when the answer is older than `MAX_ORACLE_AGE` (1 hour, a constant — no storage change). |
| M1 | Medium | `withdrawCollateral` checked health against stale (smaller) debt; borrowers could extract collateral and land underwater with no price move. | It accrues interest first, like every other risk path. |
| M2 | Medium | `amount * 1e18 / index` floored to zero for dust amounts once an index passed 1e18 — strangers withdrew base free, borrowers took base with zero debt recorded. | Principal rounds up when burning claims or creating debt; down only when minting claims. |
| M3 | Medium | `transferFrom`/`transfer` return values ignored — a false-returning or fee-on-transfer token would be credited principal it never deposited. | All token calls are `require`d to return true. |
| L1 | Low | Floor-dust surplus and direct transfers to the contract have no sweep — trapped permanently. The related "interest to nobody" branch is unreachable in practice: suppliers can't fully exit while borrows are open, so `suppliesBefore == 0` only holds once nothing accrues anyway. | Documented; no fix — dead-code branch plus an optional `sweep` if recovery is ever wanted. |
| L2 | Low | Capped full repayments burned a floor-computed principal, leaving ~1 wei of debt accruing forever. | Full repayments burn the stored principal outright. |
| L3 | Low | When seize was capped at `collateralBalance`, the liquidator still paid the full `repayAmount` — thin positions became unliquidatable. | Repay scales down to the collateral actually seized. |
| L4 | Low | Self-liquidation is permitted — a borrower can deleverage themselves at the incentive rate. | Documented, allowed deliberately; bounded harm. |
| L5 | Low | `initialize` accepted zero addresses and out-of-bounds risk params — a bad wire-up could deploy a bricked market, or one originating undercollateralized borrows (`cf > 1e18`) from block one. | Non-zero addresses; `collateralFactor` in (0, 1e18], `liquidationIncentive` ≥ 1e18 — mirroring `setParameters`. |
| I1 | Info | Debt accrues through a pause while `liquidate` stays frozen — pause duration manufactures unhealthy drift. | Documented; the right trade-off, now stated. |
| I2 | Info | Suppliers capture 100% of borrow interest; the protocol keeps no reserve and builds no bad-debt buffer. | Documented as a design observation. |

Two interactions worth stating: `getPrice` failing closed means an oracle outage halts priced paths even without a guardian pause — a second circuit breaker, but it also means a feed malfunction freezes `borrow`, `withdrawCollateral` and `liquidate` until it recovers. And ceil-rounding on `withdraw` means pulling a floor-computed PV burns the full principal — intentional.

## Test layout

`test/PoCTests.t.sol` holds two suites, both green:

- **`PoCTests`** runs against the patched `src/LendingMarket.sol` — every Fix finding's test asserts the *correct* behavior, so each one failed on the original code and passes on the fix. Rounding findings (M2) are fuzzed at 1,024 runs over the full dust domain.
- **`OriginalExploitTest`** runs the same findings against `test/original/OriginalLendingMarket.sol`, a frozen copy of the pre-fix implementation — every test asserts the exploit *succeeds*, standing proof each finding was real on shipped code.

The shipped `LendingMarket.t.sol` suite still passes unchanged.

## Scope note

Prioritized the paths that move money or decide who gets liquidated: oracle consumption (C2, H1, H2), seize/health math (C1, M1), and value conservation under rounding (M2, L2, L3). Deliberately left out: a protocol reserve factor (product decision, I2), blocking self-liquidation (L4), fee-on-transfer *support* — M3 rejects them safely rather than accounting deltas — and the unreachable empty-supply accrual branch (L1).

Unsure about: `MAX_ORACLE_AGE = 1 hour` tracks the usual feed heartbeat, but with more time I'd bind it to the real feed's documented heartbeat or make it admin-settable, and I'd verify the proxy's `upgradeTo` flow against this diff on a fork before shipping.

AI tooling: used throughout for drafting and analysis. One output I modified rather than accepted: the first seize fix kept an extra `FACTOR` term (`repay * incentive * FACTOR / (price * FACTOR)`); it's algebraically identical to `repay * incentive / price` but noisier, so I simplified it — and separately validated then downgraded the "interest accrues to nobody" branch after working out it requires total supply principal of exactly zero, which a full supplier exit can't produce while borrows are open.
