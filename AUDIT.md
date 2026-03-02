# Audit Report: YieldNestKeeper

**Scope**: `YieldNestKeeper.sol`, `StablecoinRateProvider.sol`, all interfaces

**Tests**: 56 unit + 21 mainnet integration = **77 total, all passing**

---

## Findings

### MEDIUM-1: Potential share rounding revert in `harvest()` (Lines 88-99)

The harvest function computes `yieldInShares` via `convertToShares()` (rounds down), then calls `convertToAssets(yieldInShares)` again to get `assetsToWithdraw`. It then passes `assetsToWithdraw` to `withdrawAsset()`, which burns shares from the keeper.

If the vault's `withdrawAsset` rounds **up** the shares to burn (standard ERC4626 `withdraw` behavior), it could try to burn `yieldInShares + 1` -- but the keeper only holds exactly `yieldInShares`. This would revert the entire harvest.

**Impact**: Harvest could revert on rounding edge cases, especially with small yield amounts.
**Recommendation**: Consider using `redeem(yieldInShares)` instead of `withdrawAsset(assetsToWithdraw)` to avoid the double-conversion. Or catch and handle the rounding case.

### LOW-1: `CurveSwapFailed` error is defined but never used (Line 58)

The swap was refactored to use `ICurveRouter.exchange()` directly (which reverts on its own) rather than a low-level call. The custom error is now dead code.

**Recommendation**: Remove the unused error.

### LOW-2: `setMaxOracleAge` allows setting to 0 (Line 124)

Setting `maxOracleAge = 0` would cause all oracle checks to fail (since `block.timestamp - updatedAt > 0` for any past block), effectively bricking `harvest()`.

**Recommendation**: Add a minimum bound check, e.g., `if (_maxOracleAge == 0) revert`.

### INFO-1: `_validateConfig` doesn't check `positions.length > 0`

If positions is empty, `totalPositionShares` returns 0, `positionValueInAsset` is 0, and harvest reverts with `NoYieldToHarvest`. The error is misleading -- the real issue is misconfigured positions.

### INFO-2: `StablecoinRateProvider.BASE_ASSET` is stored but unused in `getRate()`

The `BASE_ASSET` immutable is set in the constructor but `getRate()` ignores its `asset` parameter and always returns `1e18`. This is informational-only storage.

### INFO-3: No validation that `route[0]` matches `vault.asset()`

A misconfigured Curve route with wrong input token would silently approve the wrong token to the router, causing a confusing swap failure.

---

## Test Coverage Added

| Category | Tests Added | Key Scenarios |
|---|---|---|
| Constructor validation | 12 | All 9 zero-address fields, BPS bounds (0, 1, 10000, 10001), admin role |
| Oracle edge cases | 5 | Stale asset/reward oracle, zero/negative prices, boundary age |
| Yield calculation | 4 | Exact math, zero yield (equal), zero yield (underwater), positive yield |
| Debt-to-asset decimals | 3 | Same decimals, asset > debt decimals, asset < debt decimals |
| Multiple positions | 2 | Aggregation, harvest across positions |
| Admin functions | 8 | updateConfig (success, non-admin, invalid), setMinOutputBps bounds, setMaxOracleAge, recoverToken (success, zero-addr, non-admin) |
| Harvest flow | 5 | Success, event emission, wallet balance change, second harvest, role restriction |
| StablecoinRateProvider | 2 | Returns 1e18, stores BASE_ASSET |
| MinOutput scenarios | 2 | Different oracle decimals, high reward price |
| Mainnet additions | 3 | Double harvest reduced yield, updateConfig preserves harvestability, token decimals |
