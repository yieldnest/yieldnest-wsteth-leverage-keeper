#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${ETH_MAINNET_RPC_URL:?Set ETH_MAINNET_RPC_URL}"

echo "Verifying StablecoinRateProvider..."
forge verify-bytecode \
  0xeC90d3F01Ea53d4e99b1ee758F160521C2968c12 \
  src/StablecoinRateProvider.sol:StablecoinRateProvider \
  --rpc-url "$RPC_URL" \
  --constructor-args 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

echo "Verifying LatestAnswerAdapter..."
forge verify-bytecode \
  0x537C8D5a25c5467A3A68Fc0ffDfC89eA9C309360 \
  src/LatestAnswerAdapter.sol:LatestAnswerAdapter \
  --rpc-url "$RPC_URL" \
  --constructor-args 0x8B6851156023f4f5A66F68BEA80851c3D905Ac93 8

echo "Verifying FlexStrategyLeverageKeeper..."
forge verify-bytecode \
  0x6920C7c9a66EdEa563b1aEcb8CA8097f811CbFc5 \
  src/FlexStrategyLeverageKeeper.sol:FlexStrategyLeverageKeeper \
  --rpc-url "$RPC_URL" \
  --constructor-args 0x67a114e733b52cac50a168f02b5626f500801c62

echo "All verifications complete."
