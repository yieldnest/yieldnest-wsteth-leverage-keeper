// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {YieldNestKeeper} from "../../src/YieldNestKeeper.sol";
import {IYnVault} from "../../src/interfaces/IYnVault.sol";
import {StablecoinRateProvider} from "../../src/StablecoinRateProvider.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {YnRWAxConfig} from "../../script/YnRWAxConfig.sol";

interface IAccessControl {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract YieldNestKeeperMainnetTest is Test, YnRWAxConfig {
    // ─── Test State ─────────────────────────────────────────────────────────────

    YieldNestKeeper keeper;
    StablecoinRateProvider rateProvider;
    address admin = makeAddr("admin");

    function setUp() public {
        // Fork is configured via [profile.mainnet] eth_rpc_url in foundry.toml

        // 1:1 USDC/USDe stablecoin peg
        rateProvider = new StablecoinRateProvider(USDC);

        // Deploy keeper with mainnet config
        keeper = new YieldNestKeeper(admin, _buildConfig(rateProvider, 9500));

        // Grant ASSET_WITHDRAWER_ROLE on ynRWAx so keeper can call withdrawAsset
        vm.prank(YN_ADMIN);
        IAccessControl(YNRWAX).grantRole(ASSET_WITHDRAWER_ROLE, address(keeper));

        // Approve keeper to pull ynRWAx from safe
        vm.prank(SAFE);
        IERC20(YNRWAX).approve(address(keeper), type(uint256).max);

        // Grant HARVESTER_ROLE to the test contract
        vm.prank(admin);
        keeper.grantRole(keccak256("HARVESTER_ROLE"), address(this));

        // Mock wstETH/USD oracle: the BGD adapter returns updatedAt=0 from latestRoundData
        _mockWstethOracle();
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
        console2.log("Earned yield (ynRWAx shares):", yield_);

        uint256 shares = keeper.totalPositionShares();
        uint256 positionValue = IYnVault(YNRWAX).convertToAssets(shares);
        uint256 debt = keeper.totalDebt();
        console2.log("Position value (convertToAssets):", positionValue);
        console2.log("Total debt (USDe):", debt);
    }

    // ─── Harvest Tests ──────────────────────────────────────────────────────────

    function test_harvest() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        uint256 strategyWstethBefore = IERC20(WSTETH).balanceOf(STRATEGY);

        keeper.harvest();

        uint256 strategyWstethAfter = IERC20(WSTETH).balanceOf(STRATEGY);
        assertGt(strategyWstethAfter, strategyWstethBefore, "Strategy should receive wstETH reward");

        uint256 received = strategyWstethAfter - strategyWstethBefore;
        console2.log("wstETH sent to strategy:", received);
    }

    function test_harvestSendsWstethToStrategy() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        uint256 before = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 received = IERC20(WSTETH).balanceOf(STRATEGY) - before;

        assertGt(received, 0, "Strategy must receive wstETH");
        console2.log("wstETH reward received by strategy:", received);
    }

    function test_harvestEmitsEvent() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        vm.expectEmit(false, false, false, false);
        emit YieldNestKeeper.Harvested(0, 0, 0);
        keeper.harvest();
    }

    function test_harvestRevertsWhenNoYield() public {
        // Mock the safe's ynRWAx balance to 0 so there's no position value
        vm.mockCall(YNRWAX, abi.encodeWithSelector(IERC20.balanceOf.selector, SAFE), abi.encode(uint256(0)));

        vm.expectRevert(YieldNestKeeper.NoYieldToHarvest.selector);
        keeper.harvest();
    }

    function test_harvestRevertsWithoutRole() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        keeper.harvest();
    }

    // ─── Harvest Tests (with yield setup) ───────────────────────────────────────

    /// @dev Creates yield by mocking debt lower than position value.
    ///      Dynamically calculates a safe mock debt so the resulting yield stays within
    ///      the vault's current liquid USDC reserves. We do NOT deal USDC to the vault
    ///      as that would inflate the share-to-asset conversion rate.
    function _setupHarvestableYield() internal {
        uint256 shares = IERC20(YNRWAX).balanceOf(SAFE);
        uint256 positionValueUsdc = IYnVault(YNRWAX).convertToAssets(shares);

        // Target yield = half the vault's liquid USDC (safe margin)
        uint256 vaultLiquidity = IERC20(USDC).balanceOf(YNRWAX);
        uint256 targetYieldUsdc = vaultLiquidity / 2;
        require(targetYieldUsdc > 0, "vault has no liquidity");
        require(positionValueUsdc > targetYieldUsdc, "position too small for yield");

        // debt in USDC terms = positionValue - targetYield
        // convert USDC (6 dec) to USDe (18 dec): multiply by 1e12
        uint256 mockDebtUsde = (positionValueUsdc - targetYieldUsdc) * 1e12;

        vm.mockCall(
            VARIABLE_DEBT_USDE, abi.encodeWithSelector(IERC20.balanceOf.selector, SAFE), abi.encode(mockDebtUsde)
        );
    }

    function test_harvestWithYield() public {
        _setupHarvestableYield();

        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "Should have yield after debt mock");
        console2.log("Yield (ynRWAx shares):", yield_);

        uint256 strategyWstethBefore = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 strategyWstethAfter = IERC20(WSTETH).balanceOf(STRATEGY);

        uint256 received = strategyWstethAfter - strategyWstethBefore;
        assertGt(received, 0, "Strategy should receive wstETH reward");
        console2.log("wstETH harvested to strategy:", received);
    }

    function test_harvestWithYieldEmitsEvent() public {
        _setupHarvestableYield();

        vm.expectEmit(false, false, false, false);
        emit YieldNestKeeper.Harvested(0, 0, 0);
        keeper.harvest();
    }

    function test_harvestWithYieldSendsWsteth() public {
        _setupHarvestableYield();

        uint256 before = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 received = IERC20(WSTETH).balanceOf(STRATEGY) - before;

        assertGt(received, 0, "Strategy must receive wstETH");
        console2.log("wstETH reward received:", received);
    }

    function test_harvestWithYieldAccessControl() public {
        _setupHarvestableYield();

        address harvester = makeAddr("harvester2");
        bytes32 harvesterRole = keeper.HARVESTER_ROLE();

        vm.prank(admin);
        keeper.grantRole(harvesterRole, harvester);

        // Non-harvester should revert
        vm.prank(makeAddr("random2"));
        vm.expectRevert();
        keeper.harvest();

        // Harvester should succeed
        vm.prank(harvester);
        keeper.harvest();
    }

    // ─── Admin Tests ────────────────────────────────────────────────────────────

    function test_recoverToken() public {
        deal(WSTETH, address(keeper), 1e18);

        vm.prank(admin);
        keeper.recoverToken(WSTETH, admin, 1e18);
        assertEq(IERC20(WSTETH).balanceOf(admin), 1e18);
    }

    function test_setMinOutputBps() public {
        vm.prank(admin);
        keeper.setMinOutputBps(9800);
        // Verify earnedYield still returns without revert
        keeper.earnedYield();
    }

    function test_setMaxOracleAge() public {
        vm.prank(admin);
        keeper.setMaxOracleAge(3600);
    }

    // ─── Double Harvest ────────────────────────────────────────────────────

    function test_harvestWithYield_secondHarvestHasReducedYield() public {
        _setupHarvestableYield();

        uint256 yieldBefore = keeper.earnedYield();
        assertGt(yieldBefore, 0);

        keeper.harvest();

        // After first harvest, the safe has fewer ynRWAx shares (yield was pulled).
        // Position value decreases while mocked debt stays the same, so yield should decrease.
        uint256 yieldAfter = keeper.earnedYield();
        assertLt(yieldAfter, yieldBefore, "Yield should decrease after harvest");
        console2.log("Yield before:", yieldBefore, "Yield after:", yieldAfter);
    }

    // ─── UpdateConfig on mainnet ─────────────────────────────────────────────

    function test_updateConfig_maintainsHarvestability() public {
        _setupHarvestableYield();

        // Update config with higher slippage tolerance
        YieldNestKeeper.Config memory cfg = _buildConfig(rateProvider, 9000);
        vm.prank(admin);
        keeper.updateConfig(cfg);

        // Should still be able to harvest
        keeper.harvest();
    }

    // ─── Vault Token Decimals ────────────────────────────────────────────────

    function test_tokenDecimals_areCorrect() public view {
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC should have 6 decimals");
        assertEq(IERC20Metadata(WSTETH).decimals(), 18, "wstETH should have 18 decimals");
        assertEq(IERC20Metadata(VARIABLE_DEBT_USDE).decimals(), 18, "variableDebtUSDe should have 18 decimals");
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    /// @dev Mock the wstETH/USD oracle's latestRoundData to return proper timestamps.
    ///      The BGD WstETHSynchronicityPriceAdapter returns updatedAt=0 which fails staleness checks.
    function _mockWstethOracle() internal {
        // Read the real price from latestAnswer (which the adapter does support)
        (, bytes memory data) = WSTETH_USD_ORACLE.staticcall(abi.encodeWithSignature("latestAnswer()"));
        int256 price = abi.decode(data, (int256));

        vm.mockCall(
            WSTETH_USD_ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
