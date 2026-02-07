#!/bin/bash
# Complete script to deposit pool UTxO to Hydra Head (Incremental Deposit)
# VERSION: PERMISSIONLESS & SECURE (Datum fields removed)

set -e

echo "🚀 === Hydra Head Pool Deposit (Incremental) ==="
echo ""

# ============================================================================
# SETUP
# ============================================================================

export CARDANO_NODE_SOCKET_PATH=/home/g1bssq/node.socket
# Đảm bảo đây là địa chỉ Pool MỚI NHẤT (sau khi build lại và mint lại)
export POOL_ADDR=addr_test1wr2sdxpl7x2saecl6w4u2s23cxvs69kd8kpt26xgzzyxvnq2y2vsk
export CREDENTIALS_PATH=$HOME/credentials
export TESTNET_MAGIC=1
export SCRIPT_FILE=$HOME/pump-spend.plutus

echo "📋 Configuration:"
echo "   Pool Address: $POOL_ADDR"
echo "   Node Socket: $CARDANO_NODE_SOCKET_PATH"
echo ""

# ============================================================================
# STEP 1: Query and capture script UTxO
# ============================================================================

echo "🔍 Step 1: Querying pool UTxO..."
export SCRIPT_UTXO_TXIX=$(cardano-cli query utxo \
  --address $POOL_ADDR \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH \
  --output-json | jq -r 'keys[0]')

if [ -z "$SCRIPT_UTXO_TXIX" ] || [ "$SCRIPT_UTXO_TXIX" == "null" ]; then
  echo "❌ CRITICAL ERROR: No UTxO found at Pool Address!"
  echo "👉 Address: $POOL_ADDR"
  exit 1
fi

echo "✅ Captured script UTxO TxIn: $SCRIPT_UTXO_TXIX"

# ============================================================================
# STEP 2: Prepare blueprint transaction
# ============================================================================

echo "🔨 Step 2: Building DepositToHydra blueprint transaction..."

# Query UTxO JSON
UTXO_JSON=$(cardano-cli query utxo \
  --tx-in ${SCRIPT_UTXO_TXIX} \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH \
  --output-json)

echo "🔍 Analyzing UTxO content..."

# 1. Lấy Value Object
VALUE_JSON=$(echo "$UTXO_JSON" | jq -r ".\"${SCRIPT_UTXO_TXIX}\".value")

# 2. Tìm Policy ID (Key khác lovelace)
POLICY_ID=$(echo "$VALUE_JSON" | jq -r 'keys[] | select(. != "lovelace")')

if [ -z "$POLICY_ID" ] || [ "$POLICY_ID" == "null" ]; then
    echo "❌ Error: Only ADA found. Please send Tokens (PUMP) to the pool."
    exit 1
fi

# 3. Lấy nội dung bên trong Policy ID (TokenName -> Quantity)
POLICY_CONTENT=$(echo "$VALUE_JSON" | jq -r ".\"$POLICY_ID\"")

# 4. Kiểm tra xem nội dung là Object (nested) hay Number (flat)
IS_NESTED=$(echo "$POLICY_CONTENT" | jq -r 'type')

if [ "$IS_NESTED" == "object" ]; then
    TOKEN_NAME_HEX=$(echo "$POLICY_CONTENT" | jq -r 'keys[0]')
    TOKEN_QUANTITY=$(echo "$POLICY_CONTENT" | jq -r ".\"$TOKEN_NAME_HEX\"")
    ASSET_ID="${POLICY_ID}.${TOKEN_NAME_HEX}"
else
    TOKEN_QUANTITY=$POLICY_CONTENT
    ASSET_ID=$POLICY_ID
fi

echo "✅ Detected Asset:"
echo "   Policy ID: $POLICY_ID"
echo "   Asset ID:  $ASSET_ID"
echo "   Quantity:  $TOKEN_QUANTITY"

# Creator Hash
CREATOR_HASH=$(cardano-cli address key-hash --payment-verification-key-file ${CREDENTIALS_PATH}/bob-funds.vk)

# --- REDEEMER (RỖNG) ---
# Action DepositToHydra không có tham số
cat > $HOME/deposit-redeemer.json << EOF
{"constructor":3,"fields":[]}
EOF

DUMMY_ADDR=$(cardano-cli address build --payment-verification-key-file ${CREDENTIALS_PATH}/bob-funds.vk --testnet-magic $TESTNET_MAGIC)

# Build Blueprint
cardano-cli conway transaction build-raw \
  --tx-in $SCRIPT_UTXO_TXIX \
  --tx-in-script-file $SCRIPT_FILE \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file $HOME/deposit-redeemer.json \
  --tx-in-execution-units '(6000000, 2000000000)' \
  --tx-out "$DUMMY_ADDR+2000000+$TOKEN_QUANTITY $ASSET_ID" \
  --required-signer-hash $CREATOR_HASH \
  --fee 0 \
  --out-file $HOME/deposit-blueprint.json

echo "✅ Blueprint transaction created"
echo ""

# ============================================================================
# STEP 3 & 4: Create Request
# ============================================================================

echo "📦 Step 3: Creating deposit request..."
BLUEPRINT_JSON=$(cat $HOME/deposit-blueprint.json)

jq -n \
  --argjson utxo "${UTXO_JSON}" \
  --argjson blueprintTx "${BLUEPRINT_JSON}" \
  '{ "utxo": $utxo, "blueprintTx": $blueprintTx }' \
  > $HOME/deposit-request.json

# ============================================================================
# STEP 5: Send to Hydra
# ============================================================================

echo "📤 Step 5: Sending to Hydra..."

curl -s -X POST \
  --data @$HOME/deposit-request.json \
  http://127.0.0.1:4001/commit \
  > $HOME/deposit-tx.json

# --- ERROR HANDLING ---
if grep -q "ValidationFailure" $HOME/deposit-tx.json; then
    echo "🚨 CRITICAL ERROR: Smart Contract Rejected!"
    cat $HOME/deposit-tx.json
    exit 1
fi

if grep -q "FailedToDraftTx" $HOME/deposit-tx.json; then
    echo "❌ Hydra Error:"
    cat $HOME/deposit-tx.json
    exit 1
fi

CBOR_HEX=$(jq -r '.cborHex // empty' $HOME/deposit-tx.json)
if [ -z "$CBOR_HEX" ]; then
    echo "❌ Error: No CBOR in response. Possible malformed request or internal error."
    cat $HOME/deposit-tx.json
    exit 1
fi

echo "✅ Valid Transaction received from Hydra!"

# ============================================================================
# STEP 6: Sign & Submit
# ============================================================================

echo "✍️  Step 6: Signing..."
cat > $HOME/deposit-tx-envelope.json << EOF
{
    "type": "Tx ConwayEra",
    "description": "",
    "cborHex": "$CBOR_HEX"
}
EOF

cardano-cli conway transaction sign \
  --tx-body-file $HOME/deposit-tx-envelope.json \
  --signing-key-file ${CREDENTIALS_PATH}/bob-funds.sk \
  --signing-key-file ${CREDENTIALS_PATH}/alice-node.sk \
  --out-file $HOME/deposit-signed.json

echo "📤 Step 7: Submitting..."
cardano-cli conway transaction submit \
  --tx-file $HOME/deposit-signed.json \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH

echo "🎉 DONE! Pool Deposited to Hydra Head!"