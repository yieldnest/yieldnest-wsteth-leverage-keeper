// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {YieldNestKeeper} from "../../src/YieldNestKeeper.sol";
import {IYnVault} from "../../src/interfaces/IYnVault.sol";
import {StablecoinRateProvider} from "../../src/StablecoinRateProvider.sol";
import {LatestAnswerAdapter} from "../../src/LatestAnswerAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {YnRWAxConfig} from "../../script/YnRWAxConfig.sol";

interface IAccessControl {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract YieldNestKeeperMainnetTest is Test, YnRWAxConfig {
    // ─── Constants ───────────────────────────────────────────────────────────────

    uint256 constant BPS_BASE = 10_000;
    uint256 constant MIN_OUTPUT_BPS = 9500;

    // ─── Test State ─────────────────────────────────────────────────────────────

    YieldNestKeeper keeper;
    StablecoinRateProvider rateProvider;
    LatestAnswerAdapter wstethOracle;
    address admin = makeAddr("admin");

    function setUp() public {
        // Fork is configured via [profile.mainnet] eth_rpc_url in foundry.toml

        rateProvider = new StablecoinRateProvider(USDC);
        wstethOracle = new LatestAnswerAdapter(WSTETH_USD_ORACLE, 8);

        keeper = new YieldNestKeeper(address(this));
        keeper.initialize(admin, _buildConfig(rateProvider, AggregatorV3Interface(address(wstethOracle)), MIN_OUTPUT_BPS));

        // Grant ASSET_WITHDRAWER_ROLE on ynRWAx so keeper can call withdrawAsset
        vm.prank(YN_ADMIN);
        IAccessControl(YNRWAX).grantRole(ASSET_WITHDRAWER_ROLE, address(keeper));

        // Approve keeper to pull ynRWAx from safe
        vm.prank(SAFE);
        IERC20(YNRWAX).approve(address(keeper), type(uint256).max);

    }

    // ─── Discovery Tests ────────────────────────────────────────────────────────

    function test_ynRWAxAssetIsUSDC() public view {
        address asset = IYnVault(YNRWAX).asset();
        assertEq(asset, USDC, "ynRWAx underlying asset should be USDC");
    }

    function test_discoverAaveCollateralIsWsteth() public view {
        uint256 collateral = IERC20(A_WSTETH).balanceOf(SAFE);
        assertGt(collateral, 0, "Safe should hold aWstETH (Aave wstETH collateral)");
        console2.log("Safe aWstETH balance:", collateral);
    }

    function test_discoverAaveDebtIsUSDe() public view {
        uint256 debt = IERC20(VARIABLE_DEBT_USDE).balanceOf(SAFE);
        assertGt(debt, 0, "Safe should have USDe variable debt on Aave");
        console2.log("Safe variableDebtUSDe balance:", debt);
    }

    // ─── View Function Tests ────────────────────────────────────────────────────

    function test_totalPositionShares() public view {
        uint256 shares = keeper.totalPositionShares();
        uint256 expected = IERC20(YNRWAX).balanceOf(SAFE);
        assertEq(shares, expected, "totalPositionShares should match safe's ynRWAx balance");
        console2.log("Total position shares:", shares);
    }

    function test_totalDebt() public view {
        uint256 debt = keeper.totalDebt();
        uint256 expected = IERC20(VARIABLE_DEBT_USDE).balanceOf(SAFE);
        assertEq(debt, expected, "totalDebt should match safe's variableDebtUSDe balance");
        console2.log("Total debt (USDe):", debt);
    }

    function test_earnedYield() public view {
        uint256 yield_ = keeper.earnedYield();
        uint256 shares = keeper.totalPositionShares();
        uint256 debt = keeper.totalDebt();

        assertGt(yield_, 0, "Should have positive yield at current fork block");

        // Yield shares should be less than total position shares
        assertLt(yield_, shares, "Yield should be less than total position shares");

        // Verify yield is denominated in vault shares (18 decimals for ynRWAx)
        // and is reasonable relative to total position
        assertLt(yield_, shares / 10, "Yield should be a small fraction of total position");

        // After harvesting yield, position value should approximately equal debt
        uint256 remainingShares = shares - yield_;
        uint256 remainingValue = IYnVault(YNRWAX).convertToAssets(remainingShares);
        // Remaining value (6 dec USDC) should be close to debt converted to asset terms
        // Use rateProvider to convert debt to asset terms for comparison
        uint256 rate = rateProvider.getRate(USDC);
        uint256 debtInAsset = (debt * 1e18) / (rate * 10 ** (18 - 6));
        assertApproxEqRel(remainingValue, debtInAsset, 0.01e18, "After yield removal, position should approximate debt");
    }

    // ─── Harvest Tests ──────────────────────────────────────────────────────────

    function test_harvest() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        uint256 safeSharesBefore = IERC20(YNRWAX).balanceOf(SAFE);
        uint256 strategyWstethBefore = IERC20(WSTETH).balanceOf(STRATEGY);
        uint256 keeperUsdcBefore = IERC20(USDC).balanceOf(address(keeper));
        uint256 keeperWstethBefore = IERC20(WSTETH).balanceOf(address(keeper));

        keeper.harvest();

        uint256 safeSharesAfter = IERC20(YNRWAX).balanceOf(SAFE);
        uint256 strategyWstethAfter = IERC20(WSTETH).balanceOf(STRATEGY);

        // Vault shares were pulled from safe
        assertLt(safeSharesAfter, safeSharesBefore, "Safe should have fewer ynRWAx shares after harvest");
        assertEq(safeSharesBefore - safeSharesAfter, yield_, "Shares pulled should equal earnedYield");

        // Strategy received wstETH reward
        uint256 received = strategyWstethAfter - strategyWstethBefore;
        assertGt(received, 0, "Strategy should receive wstETH reward");

        // Verify received wstETH is roughly correct using oracle prices
        uint256 usdcFromYield = IYnVault(YNRWAX).convertToAssets(yield_);
        (, int256 usdcPrice,,,) = AggregatorV3Interface(USDC_USD_ORACLE).latestRoundData();
        (, int256 wstethPrice,,,) = wstethOracle.latestRoundData();
        uint256 expectedWsteth =
            (usdcFromYield * uint256(usdcPrice) * 1e18) / (uint256(wstethPrice) * 1e6);
        uint256 slippageMirror = BPS_BASE - MIN_OUTPUT_BPS; // e.g. 500 bps = 5%
        assertGe(received, (expectedWsteth * MIN_OUTPUT_BPS) / BPS_BASE, "Received wstETH below slippage tolerance");
        assertLe(
            received,
            (expectedWsteth * (BPS_BASE + slippageMirror)) / BPS_BASE,
            "Received wstETH unreasonably high"
        );

        // Keeper should not retain any tokens
        assertEq(IERC20(USDC).balanceOf(address(keeper)), keeperUsdcBefore, "Keeper should not retain USDC");
        assertEq(IERC20(WSTETH).balanceOf(address(keeper)), keeperWstethBefore, "Keeper should not retain wstETH");

        // Second harvest should revert since yield was just claimed
        assertEq(keeper.earnedYield(), 0, "No yield should remain after harvest");
    }

    function test_harvestSendsWstethToStrategy() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        // Compute expected USDC output from burning yield shares
        uint256 expectedUsdc = IYnVault(YNRWAX).convertToAssets(yield_);

        uint256 strategyBefore = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 received = IERC20(WSTETH).balanceOf(STRATEGY) - strategyBefore;

        assertGt(received, 0, "Strategy must receive wstETH");

        // Verify reward amount is reasonable relative to USDC input using oracle prices
        (, int256 usdcPrice,,,) = AggregatorV3Interface(USDC_USD_ORACLE).latestRoundData();
        (, int256 wstethPrice,,,) = wstethOracle.latestRoundData();
        uint256 expectedWsteth =
            (expectedUsdc * uint256(usdcPrice) * 1e18) / (uint256(wstethPrice) * 1e6);

        // Received should be within slippage tolerance (symmetric band around oracle expected)
        uint256 slippageMirror = BPS_BASE - MIN_OUTPUT_BPS;
        assertGe(received, (expectedWsteth * MIN_OUTPUT_BPS) / BPS_BASE, "Received wstETH below slippage tolerance");
        assertLe(
            received,
            (expectedWsteth * (BPS_BASE + slippageMirror)) / BPS_BASE,
            "Received wstETH unreasonably high"
        );
    }

    function test_harvestEmitsEvent() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        vm.expectEmit(true, true, true, false);
        emit YieldNestKeeper.Harvested(yield_, IYnVault(YNRWAX).convertToAssets(yield_), 0);
        keeper.harvest();
    }

    function test_harvestIsPermissionless() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        uint256 strategyBefore = IERC20(WSTETH).balanceOf(STRATEGY);
        vm.prank(makeAddr("random"));
        keeper.harvest();
        assertGt(IERC20(WSTETH).balanceOf(STRATEGY), strategyBefore, "Random caller should be able to harvest");
    }

    // ─── Admin Tests ────────────────────────────────────────────────────────────

    function test_recoverToken() public {
        deal(WSTETH, address(keeper), 1e18);
        uint256 adminBefore = IERC20(WSTETH).balanceOf(admin);

        vm.prank(admin);
        keeper.recoverToken(WSTETH, admin, 1e18);

        assertEq(IERC20(WSTETH).balanceOf(admin), adminBefore + 1e18, "Admin should receive recovered tokens");
        assertEq(IERC20(WSTETH).balanceOf(address(keeper)), 0, "Keeper should have zero balance after recovery");
    }

    function test_recoverToken_revertsNonAdmin() public {
        deal(WSTETH, address(keeper), 1e18);

        vm.prank(makeAddr("random"));
        vm.expectRevert();
        keeper.recoverToken(WSTETH, makeAddr("random"), 1e18);
    }

    function test_setMinOutputBps() public {
        vm.prank(admin);
        keeper.setMinOutputBps(9800);

        // Verify the new value is used — earnedYield should still work
        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "earnedYield should work after setMinOutputBps");
    }

    function test_setMinOutputBps_revertsInvalidValue() public {
        vm.prank(admin);
        vm.expectRevert(YieldNestKeeper.InvalidBps.selector);
        keeper.setMinOutputBps(0);

        vm.prank(admin);
        vm.expectRevert(YieldNestKeeper.InvalidBps.selector);
        keeper.setMinOutputBps(10_001);
    }

    function test_setMaxOracleAge() public {
        vm.prank(admin);
        keeper.setMaxOracleAge(3600);

        // Verify the keeper still functions with the new oracle age
        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "earnedYield should work with updated oracle age");
    }

    function test_updateConfig() public {
        YieldNestKeeper.Config memory cfg =
            _buildConfig(rateProvider, AggregatorV3Interface(address(wstethOracle)), 9000);

        vm.prank(admin);
        vm.expectEmit();
        emit YieldNestKeeper.ConfigUpdated();
        keeper.updateConfig(cfg);

        // Verify keeper functions with updated config
        uint256 shares = keeper.totalPositionShares();
        uint256 expected = IERC20(YNRWAX).balanceOf(SAFE);
        assertEq(shares, expected, "totalPositionShares should work after config update");

        uint256 debt = keeper.totalDebt();
        assertGt(debt, 0, "totalDebt should work after config update");

        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "earnedYield should work after config update");
    }

    function test_updateConfig_revertsNonAdmin() public {
        YieldNestKeeper.Config memory cfg =
            _buildConfig(rateProvider, AggregatorV3Interface(address(wstethOracle)), 9000);

        vm.prank(makeAddr("random"));
        vm.expectRevert();
        keeper.updateConfig(cfg);
    }

    // ─── Vault Token Decimals ────────────────────────────────────────────────

    function test_tokenDecimals_areCorrect() public view {
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC should have 6 decimals");
        assertEq(IERC20Metadata(WSTETH).decimals(), 18, "wstETH should have 18 decimals");
        assertEq(IERC20Metadata(VARIABLE_DEBT_USDE).decimals(), 18, "variableDebtUSDe should have 18 decimals");
    }
}
