// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YieldNestKeeper} from "../src/YieldNestKeeper.sol";
import {IYnVault} from "../src/interfaces/IYnVault.sol";
import {IConversionRateProvider} from "../src/interfaces/IConversionRateProvider.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ICurveRouter} from "../src/interfaces/ICurveRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title YnRWAxConfig
/// @notice Shared mainnet addresses and config-building logic for ynRWAx keeper deployment and testing.
abstract contract YnRWAxConfig {
    // ─── Mainnet Contract Addresses ─────────────────────────────────────────────

    // ynRWAx vault (asset = USDC)
    address constant YNRWAX = 0x01Ba69727E2860b37bc1a2bd56999c1aFb4C15D8;

    // Strategy deployment
    address constant SAFE = 0x24D2486F5b2C2c225B6be8B4f72D46349cBf4458;
    address constant STRATEGY = 0x115B50649e50c2b36B3D2Ec0928E72492c85dA7D;

    // Tokens
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Aave V3
    address constant A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant VARIABLE_DEBT_USDE = 0x015396E1F286289aE23a762088E863b3ec465145;

    // Chainlink Oracles
    address constant USDC_USD_ORACLE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant WSTETH_USD_ORACLE = 0x8B6851156023f4f5A66F68BEA80851c3D905Ac93;

    // Curve Router NG v1.1
    address constant CURVE_ROUTER = 0x16C6521Dff6baB339122a0FE25a9116693265353;

    // Curve pools
    address constant TRICRYPTO_USDC = 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B;
    address constant STETH_NG_POOL = 0x21E27a5E5513D6e65C4f830167390997aA84843a;

    // ynRWAx admin (YNSecurityCouncil)
    address constant YN_ADMIN = 0xfcad670592a3b24869C0b51a6c6FDED4F95D6975;

    // ynRWAx roles
    bytes32 constant ASSET_WITHDRAWER_ROLE = keccak256("ASSET_WITHDRAWER_ROLE");

    // ─── Config Builder ─────────────────────────────────────────────────────────

    function _buildConfig(
        IConversionRateProvider rateProvider,
        AggregatorV3Interface rewardOracle,
        uint256 minOutputBps
    ) internal pure returns (YieldNestKeeper.Config memory) {
        address[] memory positions = new address[](1);
        positions[0] = SAFE;

        (address[11] memory route, uint256[5][5] memory swapParams, address[5] memory pools) = _curveRoute();

        return YieldNestKeeper.Config({
            vault: IYnVault(YNRWAX),
            positions: positions,
            debtToken: IERC20(VARIABLE_DEBT_USDE),
            rateProvider: rateProvider,
            approvedWallet: SAFE,
            rewardAsset: WSTETH,
            destinationStrategy: STRATEGY,
            curveRouter: ICurveRouter(CURVE_ROUTER),
            route: route,
            swapParams: swapParams,
            pools: pools,
            assetOracle: AggregatorV3Interface(USDC_USD_ORACLE),
            rewardOracle: rewardOracle,
            maxOracleAge: 86400,
            minOutputBps: minOutputBps
        });
    }

    /// @dev Curve route: USDC -> WETH -> ETH -> stETH -> wstETH
    ///      4 hops: TricryptoUSDC exchange, WETH unwrap, stETH-ng exchange, wstETH wrap
    function _curveRoute()
        internal
        pure
        returns (address[11] memory route, uint256[5][5] memory swapParams, address[5] memory pools)
    {
        address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // Hop 1: USDC -> WETH via TricryptoUSDC pool
        route[0] = USDC;
        route[1] = TRICRYPTO_USDC;
        route[2] = WETH;

        // Hop 2: WETH -> ETH (unwrap)
        route[3] = WETH;
        route[4] = ETH;

        // Hop 3: ETH -> stETH via stETH-ng pool
        route[5] = STETH_NG_POOL;
        route[6] = STETH;

        // Hop 4: stETH -> wstETH via wrapping
        route[7] = WSTETH;
        route[8] = WSTETH;
        // route[9..10] = address(0) by default

        // Swap params: [i, j, swap_type, pool_type, n_coins]
        // Hop 1: USDC(0) -> WETH(2), exchange(uint256), tricrypto, 3 coins
        swapParams[0] = [uint256(0), 2, 1, 3, 3];
        // Hop 2: WETH -> ETH, unwrap via swap_type 8
        swapParams[1] = [uint256(0), 0, 8, 0, 0];
        // Hop 3: ETH(0) -> stETH(1), exchange(int128), stableswap, 2 coins
        swapParams[2] = [uint256(0), 1, 1, 1, 2];
        // Hop 4: stETH -> wstETH, wrap via swap_type 8
        swapParams[3] = [uint256(0), 0, 8, 0, 0];
        // swapParams[4] = [0,0,0,0,0] by default
    }
}
