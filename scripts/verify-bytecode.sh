#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${ETH_MAINNET_RPC_URL:?Set ETH_MAINNET_RPC_URL}"

echo "Verifying StablecoinRateProvider..."
forge verify-bytecode \
  0xe16e55f7dd4bbb4aCaeDd49c56E31289D63515DA \
  src/StablecoinRateProvider.sol:StablecoinRateProvider \
  --rpc-url "$RPC_URL" \
  --constructor-args 0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48

echo "Verifying LatestAnswerAdapter..."
forge verify-bytecode \
  0xfEc724764A4C8d9aBBe08158aE55BDA3F828fF46 \
  src/LatestAnswerAdapter.sol:LatestAnswerAdapter \
  --rpc-url "$RPC_URL" \
  --constructor-args 0x8b6851156023f4f5a66f68bea80851c3d905ac93 8

echo "Verifying FlexStrategyLeverageKeeper..."
forge verify-bytecode \
  0x4F0DEd2b304645749c137bFE092b9f48e5795cdE \
  src/FlexStrategyLeverageKeeper.sol:FlexStrategyLeverageKeeper \
  --rpc-url "$RPC_URL" \
  --constructor-args 0x67a114e733b52cac50a168f02b5626f500801c62

echo "All verifications complete."
