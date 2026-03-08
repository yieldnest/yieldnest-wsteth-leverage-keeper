// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYnVault} from "./interfaces/IYnVault.sol";
import {IConversionRateProvider} from "./interfaces/IConversionRateProvider.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ICurveRouter} from "./interfaces/ICurveRouter.sol";

/// @title BaseLeverageKeeper
/// @notice Abstract base for leverage keepers. Harvests earned yield from vault positions by comparing
///         vault share value against debt, withdrawing the surplus, swapping the underlying asset for
///         a reward token on Curve, forwarding the reward to a destination strategy, and calling a
///         post-harvest hook for subclass-specific logic.
abstract contract BaseLeverageKeeper is AccessControlEnumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Configuration ────────────────────────────────────────────────────────────

    struct Config {
        IYnVault vault; // The YieldNest vault token
        address[] positions; // Addresses whose vault share balances constitute the managed position
        IERC20 debtToken; // The debt token (1:1 with stablecoin)
        IConversionRateProvider rateProvider; // Provides asset() <-> debtToken conversion rate
        address approvedWallet; // Wallet that pre-approved this keeper to pull vault shares
        address rewardAsset; // Token to swap asset() into on Curve
        address destinationStrategy; // Where reward tokens are sent
        // Curve swap config
        ICurveRouter curveRouter; // Curve Router
        address[11] route; // Curve swap route
        uint256[5][5] swapParams; // Curve swap params
        address[5] pools; // Curve pools for swap
        // Oracle config
        AggregatorV3Interface assetOracle; // Chainlink oracle for asset()
        AggregatorV3Interface rewardOracle; // Chainlink oracle for rewardAsset
        uint256 maxOracleAge; // Max staleness for oracle prices (seconds)
        uint256 minOutputBps; // Min output as bps of oracle-expected (e.g. 9900 = 1% slippage)
        uint256 allocationFraction; // Fraction of surplus to allocate (1e18 = 100%, 0.9e18 = 90%)
    }

    Config public config;
    address public initializer;

    // ─── Events ───────────────────────────────────────────────────────────────────

    event Harvested(uint256 yieldInShares, uint256 assetsWithdrawn, uint256 rewardOut);
    event ConfigUpdated();
    event Initialized(address admin);

    // ─── Errors ───────────────────────────────────────────────────────────────────

    error NoYieldToHarvest();
    error InvalidPrice();
    error StaleOraclePrice();
    error CurveSwapFailed();
    error ZeroAddress();
    error InvalidBps();
    error InvalidFraction();
    error AlreadyInitialized();
    error NotInitializer();

    // ─── Constructor ──────────────────────────────────────────────────────────────

    constructor(address _initializer) {
        if (_initializer == address(0)) revert ZeroAddress();
        initializer = _initializer;
    }

    // ─── Initialization ─────────────────────────────────────────────────────────

    /// @notice One-time initialization. Must be called by the initializer set in the constructor.
    function initialize(address admin, Config memory _config) external {
        if (initializer == address(0)) revert AlreadyInitialized();
        if (msg.sender != initializer) revert NotInitializer();
        _validateConfig(_config);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        config = _config;
        initializer = address(0);
        emit Initialized(admin);
    }

    // ─── Public Entry Point ───────────────────────────────────────────────────────

    /// @notice Parameterless harvest function. Computes earned yield, pulls vault shares from the
    ///         approved wallet, burns it for asset(), swaps asset() for rewardAsset on Curve,
    ///         and sends the reward to the destination strategy.
    function harvest() external nonReentrant {
        Config memory c = config;

        // Step 1: Calculate yield surplus in vault shares
        uint256 yieldInShares = _calculateYieldInShares(c);
        if (yieldInShares == 0) revert NoYieldToHarvest();

        // Step 2: Pull vault shares from the approved wallet
        IERC20(address(c.vault)).safeTransferFrom(c.approvedWallet, address(this), yieldInShares);

        // Step 3: Burn vault shares for underlying asset via withdrawAsset
        address _asset = c.vault.asset();
        uint256 assetsToWithdraw = c.vault.convertToAssets(yieldInShares);
        uint256 balBefore = IERC20(_asset).balanceOf(address(this));
        c.vault.withdrawAsset(_asset, assetsToWithdraw, address(this), address(this));
        uint256 assetsReceived = IERC20(_asset).balanceOf(address(this)) - balBefore;

        // Step 4: Swap asset() for rewardAsset on Curve
        uint256 rewardOut = _swapAssetForReward(c, assetsReceived);

        // Step 5: Send reward to destination strategy
        IERC20(c.rewardAsset).safeTransfer(c.destinationStrategy, rewardOut);

        // Step 6: Post-harvest hook
        _onPostHarvest(c, rewardOut);

        emit Harvested(yieldInShares, assetsReceived, rewardOut);
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────────

    function updateConfig(Config memory _config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateConfig(_config);
        config = _config;
        emit ConfigUpdated();
    }

    function setMinOutputBps(uint256 _minOutputBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_minOutputBps == 0 || _minOutputBps > 10_000) revert InvalidBps();
        config.minOutputBps = _minOutputBps;
    }

    function setMaxOracleAge(uint256 _maxOracleAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        config.maxOracleAge = _maxOracleAge;
    }

    function setAllocationFraction(uint256 _allocationFraction) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_allocationFraction == 0 || _allocationFraction > 1e18) revert InvalidFraction();
        config.allocationFraction = _allocationFraction;
    }

    /// @notice Recover any ERC20 tokens accidentally sent to this contract.
    function recoverToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ─── View Functions ───────────────────────────────────────────────────────────

    /// @notice Returns the total vault shares across all managed positions.
    function totalPositionShares() external view returns (uint256) {
        return _totalPositionShares(config);
    }

    /// @notice Returns the total debt token balance across all managed positions.
    function totalDebt() external view returns (uint256) {
        return _totalDebt(config);
    }

    /// @notice Returns position value, debt, and surplus (all in asset terms). Surplus is 0 if underwater.
    function surplus()
        external
        view
        returns (uint256 positionValueInAsset, uint256 debtInAsset, uint256 surplusInAsset)
    {
        return _surplus(config);
    }

    /// @notice Returns the current earned yield in vault shares, or 0 if underwater.
    function earnedYield() external view returns (uint256) {
        return _calculateYieldInShares(config);
    }

    // ─── Internal Functions ───────────────────────────────────────────────────────

    /// @notice Post-harvest hook for subclass-specific logic.
    function _onPostHarvest(Config memory c, uint256 rewardOut) internal virtual;

    function _surplus(Config memory c)
        internal
        view
        returns (uint256 positionValueInAsset, uint256 debtInAsset, uint256 surplusInAsset)
    {
        positionValueInAsset = c.vault.convertToAssets(_totalPositionShares(c));
        debtInAsset = _debtToAsset(c, _totalDebt(c));
        if (positionValueInAsset > debtInAsset) {
            surplusInAsset = positionValueInAsset - debtInAsset;
        }
    }

    function _calculateYieldInShares(Config memory c) internal view returns (uint256 yieldInShares) {
        (,, uint256 s) = _surplus(c);
        if (s > 0) {
            yieldInShares = c.vault.convertToShares(s * c.allocationFraction / 1e18);
        }
    }

    function _totalPositionShares(Config memory c) internal view returns (uint256 total) {
        uint256 len = c.positions.length;
        for (uint256 i; i < len;) {
            total += IERC20(address(c.vault)).balanceOf(c.positions[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _totalDebt(Config memory c) internal view returns (uint256 total) {
        uint256 len = c.positions.length;
        for (uint256 i; i < len;) {
            total += c.debtToken.balanceOf(c.positions[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Converts a debt amount (in debtToken decimals) to asset terms (in asset decimals).
    ///      Rate is scaled by 1e18: assetAmount_native * rate / 1e18 = debtAmount_native.
    ///      So: debtInAsset_native = debtAmount_native * 1e18 / rate,
    ///      then normalize decimals: multiply by 10^(assetDecimals - debtDecimals) if needed.
    function _debtToAsset(Config memory c, uint256 debtAmount) internal view returns (uint256) {
        address asset = c.vault.asset();
        uint256 rate = c.rateProvider.getRate(asset);
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint8 debtDecimals = IERC20Metadata(address(c.debtToken)).decimals();

        // Convert debt to asset terms: debtAmount * 1e18 / rate, then adjust for decimal difference
        if (assetDecimals >= debtDecimals) {
            return (debtAmount * 10 ** (assetDecimals - debtDecimals) * 1e18) / rate;
        } else {
            return (debtAmount * 1e18) / (rate * 10 ** (debtDecimals - assetDecimals));
        }
    }

    function _swapAssetForReward(Config memory c, uint256 amount) internal returns (uint256) {
        address asset = c.vault.asset();
        IERC20(asset).forceApprove(address(c.curveRouter), amount);

        uint256 minOut = _calculateMinOutput(c, amount);

        return c.curveRouter.exchange(c.route, c.swapParams, amount, minOut, c.pools);
    }

    function _calculateMinOutput(Config memory c, uint256 inputAmount) internal view returns (uint256) {
        (, int256 assetPrice,, uint256 assetUpdatedAt,) = c.assetOracle.latestRoundData();
        (, int256 rewardPrice,, uint256 rewardUpdatedAt,) = c.rewardOracle.latestRoundData();

        if (assetPrice <= 0 || rewardPrice <= 0) revert InvalidPrice();
        if (block.timestamp - assetUpdatedAt > c.maxOracleAge) revert StaleOraclePrice();
        if (block.timestamp - rewardUpdatedAt > c.maxOracleAge) revert StaleOraclePrice();

        uint8 assetOracleDecimals = c.assetOracle.decimals();
        uint8 rewardOracleDecimals = c.rewardOracle.decimals();

        address asset = c.vault.asset();
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint8 rewardDecimals = IERC20Metadata(c.rewardAsset).decimals();

        // expectedOutput = inputAmount * assetPrice / rewardPrice, adjusted for decimals
        uint256 expectedOutput = (inputAmount * uint256(assetPrice) * 10 ** rewardOracleDecimals * 10 ** rewardDecimals)
            / (uint256(rewardPrice) * 10 ** assetOracleDecimals * 10 ** assetDecimals);

        return (expectedOutput * c.minOutputBps) / 10_000;
    }

    function _validateConfig(Config memory c) internal pure {
        if (address(c.vault) == address(0)) revert ZeroAddress();
        if (address(c.debtToken) == address(0)) revert ZeroAddress();
        if (address(c.rateProvider) == address(0)) revert ZeroAddress();
        if (c.approvedWallet == address(0)) revert ZeroAddress();
        if (c.rewardAsset == address(0)) revert ZeroAddress();
        if (c.destinationStrategy == address(0)) revert ZeroAddress();
        if (address(c.curveRouter) == address(0)) revert ZeroAddress();
        if (address(c.assetOracle) == address(0)) revert ZeroAddress();
        if (address(c.rewardOracle) == address(0)) revert ZeroAddress();
        if (c.minOutputBps == 0 || c.minOutputBps > 10_000) revert InvalidBps();
        if (c.allocationFraction == 0 || c.allocationFraction > 1e18) revert InvalidFraction();
    }
}
