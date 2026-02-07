#!/bin/bash

# ============================================================================
# Cardano CLI Script Address Generation
# ============================================================================

CARDANO_TESTNET_MAGIC=1  # 1 = Preprod, 2 = Preview

# Generate mint policy ID
echo "🏦 Generating mint policy ID..."
cardano-cli transaction policyid \
  --script-file pump-mint.plutus

# Generate spend script address  
echo ""
echo "🏠 Generating spend script address..."
cardano-cli address build \
  --payment-script-file pump-spend.plutus \
  --testnet-magic $CARDANO_TESTNET_MAGIC \
  --out-file pump-script-cli.addr

echo ""
echo "✅ Generated addresses:"
echo "   MeshSDK address: $(cat pump-script.addr)"
echo "   CLI address:     $(cat pump-script-cli.addr)"
echo ""
echo "📝 These should match your pool address!"
