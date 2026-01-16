#!/bin/bash
# Buy tokens on Hydra L2
set -e

echo "🚀 === Buy Tokens on Hydra L2 ==="
echo ""

# ============================================================================
# CONFIGURATION
# ============================================================================

export POOL_ADDR=addr_test1wpakws8zf5rp8gazq9h97n3zuadjvpdr0a4uvt8353s9nngwvm3h8
export POLICY_ID=7b6740e24d0613a3a2016e5f4e22e75b2605a37f6bc62cf1a46059cd
export TOKEN_NAME=50554d50  # PUMP in hex
export SLOPE=1000000
export CREDENTIALS_PATH=$HOME/credentials
export HYDRA_API=http://127.0.0.1:4001

# Buy parameters
AMOUNT=${1:-1}  # Số token muốn mua (default: 1)
MAX_COST=${2:-10000000}  # Giá tối đa chấp nhận (default: 10 ADA)

echo "📋 Configuration:"
echo "   Pool Address: $POOL_ADDR"
echo "   Amount to buy: $AMOUNT tokens"
echo "   Max cost: $MAX_COST lovelace"
echo ""

# ============================================================================
# STEP 1: Query UTxOs in Hydra Head
# ============================================================================

echo "🔍 Step 1: Querying UTxOs in Hydra Head..."

curl -s $HYDRA_API/snapshot/utxo > $HOME/head-utxos.json

echo "✅ Head UTxOs retrieved"
cat $HOME/head-utxos.json | jq . | head -20
echo ""

# Find pool UTxO
POOL_UTXO_TXIX=$(jq -r "to_entries[] | select(.value.address == \"$POOL_ADDR\") | .key" $HOME/head-utxos.json)

if [ -z "$POOL_UTXO_TXIX" ]; then
  echo "❌ Pool UTxO not found in Head"
  exit 1
fi

echo "✅ Found pool UTxO: $POOL_UTXO_TXIX"

# Parse pool datum
POOL_DATUM=$(jq -r ".[\"$POOL_UTXO_TXIX\"].inlineDatum" $HOME/head-utxos.json)
CURRENT_SUPPLY=$(echo $POOL_DATUM | jq -r '.fields[3].int')

echo "   Current supply: $CURRENT_SUPPLY"
echo ""

# ============================================================================
# STEP 2: Calculate cost and new supply
# ============================================================================

echo "📊 Step 2: Calculating buy cost..."

NEW_SUPPLY=$((CURRENT_SUPPLY + AMOUNT))
# Cost = slope * (end² - start²) / 2
COST=$(( SLOPE * (NEW_SUPPLY * NEW_SUPPLY - CURRENT_SUPPLY * CURRENT_SUPPLY) / 2 ))

echo "   Cost: $COST lovelace"
echo "   New supply: $NEW_SUPPLY"
echo ""

if [ $COST -gt $MAX_COST ]; then
  echo "❌ Cost ($COST) exceeds max cost ($MAX_COST)"
  exit 1
fi

# ============================================================================
# STEP 3: Get buyer UTxO
# ============================================================================

echo "💰 Step 3: Finding buyer payment UTxO..."

BUYER_ADDR=$(cardano-cli address build --payment-verification-key-file ${CREDENTIALS_PATH}/bob-funds.vk --testnet-magic 1)

# Find buyer UTxO in Head (pure ADA)
BUYER_UTXO_TXIX=$(jq -r "to_entries[] | select(.value.address == \"$BUYER_ADDR\" and (.value.value | keys | length == 1)) | .key" $HOME/head-utxos.json | head -1)

if [ -z "$BUYER_UTXO_TXIX" ]; then
  echo "❌ No buyer payment UTxO found in Head"
  exit 1
fi

BUYER_UTXO_VALUE=$(jq -r ".[\"$BUYER_UTXO_TXIX\"].value.lovelace" $HOME/head-utxos.json)
echo "✅ Buyer UTxO: $BUYER_UTXO_TXIX ($BUYER_UTXO_VALUE lovelace)"
echo ""

# ============================================================================
# STEP 4: Create Buy redeemer and new datum
# ============================================================================

echo "🔨 Step 4: Creating redeemer and datum..."

# Buy redeemer (constructor 1)
cat > $HOME/buy-redeemer-l2.json << EOF
{"constructor":1,"fields":[{"int":$AMOUNT},{"int":$MAX_COST}]}
EOF

# New pool datum (supply updated)
cat > $HOME/new-pool-datum-l2.json << EOF
{
  "constructor": 0,
  "fields": [
    {"bytes": "$POLICY_ID"},
    {"bytes": "$TOKEN_NAME"},
    {"int": $SLOPE},
    {"int": $NEW_SUPPLY},
    {"bytes": "a0abf91dee3e17b3b3091bbc4acdd395209b7925fd62f147aae85416"}
  ]
}
EOF

echo "✅ Redeemer and datum created"
echo ""

# ============================================================================
# STEP 5: Build Buy transaction
# ============================================================================

echo "🔧 Step 5: Building Buy transaction..."

# Get current pool values
POOL_ADA=$(jq -r ".[\"$POOL_UTXO_TXIX\"].value.lovelace" $HOME/head-utxos.json)
POOL_TOKENS=$(jq -r ".[\"$POOL_UTXO_TXIX\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME\"]" $HOME/head-utxos.json)

# Calculate new values
NEW_POOL_ADA=$((POOL_ADA + COST))
NEW_POOL_TOKENS=$((POOL_TOKENS - AMOUNT))
NEW_BUYER_ADA=$((BUYER_UTXO_VALUE - COST - 200000))  # 200000 for min output

echo "   Pool: $POOL_ADA → $NEW_POOL_ADA lovelace"
echo "   Pool tokens: $POOL_TOKENS → $NEW_POOL_TOKENS"
echo ""

# Build transaction
cardano-cli conway transaction build-raw \
  --tx-in $POOL_UTXO_TXIX \
  --tx-in-script-file $HOME/pump-spend.plutus \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file $HOME/buy-redeemer-l2.json \
  --tx-in-execution-units '(14000000, 10000000000)' \
  --tx-in $BUYER_UTXO_TXIX \
  --tx-out "$POOL_ADDR+$NEW_POOL_ADA+$NEW_POOL_TOKENS $POLICY_ID.$TOKEN_NAME" \
  --tx-out-inline-datum-file $HOME/new-pool-datum-l2.json \
  --tx-out "$BUYER_ADDR+$NEW_BUYER_ADA+$AMOUNT $POLICY_ID.$TOKEN_NAME" \
  --fee 0 \
  --out-file $HOME/buy-tx-l2.json

echo "✅ Transaction built"
echo ""

# ============================================================================
# STEP 6: Sign transaction
# ============================================================================

echo "✍️  Step 6: Signing transaction..."

cardano-cli conway transaction sign \
  --tx-body-file $HOME/buy-tx-l2.json \
  --signing-key-file ${CREDENTIALS_PATH}/bob-funds.sk \
  --out-file $HOME/buy-tx-l2-signed.json

echo "✅ Transaction signed"
echo ""

# ============================================================================
# STEP 7: Submit to Hydra
# ============================================================================

echo "📤 Step 7: Submitting transaction to Hydra Head..."

# Get CBOR
TX_CBOR=$(jq -r '.cborHex' $HOME/buy-tx-l2-signed.json)

# Submit via Hydra API
curl -X POST \
  -H "Content-Type: application/json" \
  -d "{\"tag\":\"NewTx\",\"transaction\":{\"cborHex\":\"$TX_CBOR\",\"type\":\"Tx ConwayEra\"}}" \
  $HYDRA_API \
  | jq .

echo ""
echo "✅ Transaction submitted to Hydra Head!"
echo ""

# ============================================================================
# SUMMARY
# ============================================================================

echo "🎉 === Buy Transaction Completed ==="
echo ""
echo "📊 Summary:"
echo "   Bought: $AMOUNT PUMP tokens"
echo "   Cost: $COST lovelace"
echo "   New supply: $NEW_SUPPLY"
echo ""
echo "💡 Check Head status:"
echo "   curl -s $HYDRA_API/snapshot/utxo | jq ."
