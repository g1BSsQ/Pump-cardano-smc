#!/bin/bash
# Complete script to deposit pool UTxO to Hydra Head (Incremental Deposit)
# VERSION: SIMPLIFIED REDEEMER (Matches new pump.ak) + POSIX Deadline for Hydra

set -e

echo "🚀 === Hydra Head Pool Deposit (Incremental) ==="
echo ""

# ============================================================================
# SETUP
# ============================================================================

# Detect script directory để tự động tìm plutus-scripts
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export CARDANO_NODE_SOCKET_PATH=/home/g1bssq/node.socket
# Tự động đọc địa chỉ Pool từ file plutus-scripts/pump-script.addr
export POOL_ADDR=$(cat "$SCRIPT_DIR/plutus-scripts/pump-script.addr")
export CREDENTIALS_PATH=$HOME/credentials
export TESTNET_MAGIC=1
export SCRIPT_FILE="$SCRIPT_DIR/plutus-scripts/pump-spend.plutus"

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

# --- Extract lovelace amount từ UTxO ---
LOVELACE_AMOUNT=$(echo "$VALUE_JSON" | jq -r '.lovelace // 0')
echo "💰 Lovelace Amount: $LOVELACE_AMOUNT"

# --- CHECK DATUM (để preserve cấu trúc PoolDatum) ---
CURRENT_DATUM=$(echo "$UTXO_JSON" | jq -r ".\"${SCRIPT_UTXO_TXIX}\".inlineDatum")
if [ "$CURRENT_DATUM" == "null" ] || [ -z "$CURRENT_DATUM" ]; then
    echo "❌ ERROR: No inline datum found in pool UTxO!"
    exit 1
fi

# Extract datum fields theo cấu trúc PoolDatum trong pump.ak
DATUM_TOKEN_POLICY=$(echo "$CURRENT_DATUM" | jq -r '.fields[0].bytes')
DATUM_TOKEN_NAME=$(echo "$CURRENT_DATUM" | jq -r '.fields[1].bytes')
CURRENT_SUPPLY=$(echo "$CURRENT_DATUM" | jq -r '.fields[2].int // 0')
DATUM_CREATOR=$(echo "$CURRENT_DATUM" | jq -r '.fields[3].bytes')

echo "📊 Pool Datum Info:"
echo "   Token Policy: $DATUM_TOKEN_POLICY"
echo "   Token Name: $DATUM_TOKEN_NAME"
echo "   Current Supply: $CURRENT_SUPPLY"
echo "   Creator: $DATUM_CREATOR"

# Kiểm tra xem các giá trị có hợp lệ không
if [ -z "$DATUM_TOKEN_POLICY" ] || [ "$DATUM_TOKEN_POLICY" == "null" ]; then
    echo "❌ ERROR: Failed to extract token_policy from datum!"
    echo "Current datum:"
    echo "$CURRENT_DATUM" | jq '.'
    exit 1
fi

# --- TẠO DATUM ĐÚNG CẤU TRÚC PoolDatum (DÙNG JQ AN TOÀN) ---
# Theo pump.ak: { token_policy, token_name, current_supply, creator }
STRICT_DATUM="{
  \"constructor\": 0,
  \"fields\": [
    { \"bytes\": \"$DATUM_TOKEN_POLICY\" },
    { \"bytes\": \"$DATUM_TOKEN_NAME\" },
    { \"int\": $CURRENT_SUPPLY },
    { \"bytes\": \"$DATUM_CREATOR\" }
  ]
}"

echo "Checking JSON String: $STRICT_DATUM"

echo "✅ Pool Datum created successfully"
echo "$STRICT_DATUM" > $HOME/pool-datum.json

# KỸ THUẬT CHỐT HẠ: Tạo trực tiếp CBOR Hex cho Plutus Constr 0
# d879 = Tag 121 (Constr 0), 9f = Bắt đầu List, ff = Kết thúc List
# 581c = Bytes độ dài 28 (Policy & Creator), 44 = Bytes độ dài 4 (PUMP)
# 00 = Integer 0
CBOR_HEX="d8799f581c${DATUM_TOKEN_POLICY}44${DATUM_TOKEN_NAME}00581c${DATUM_CREATOR}ff"

# Chuyển Hex thành file nhị phân chuẩn Cardano
echo "$CBOR_HEX" | xxd -r -p > $HOME/pool-datum.cbor
echo "✅ Binary CBOR Datum created (Force Constructor 0)"

# --- REDEEMER (DepositToHydra - Constructor 1, no fields) ---
cat > $HOME/deposit-redeemer.json << EOF
{"constructor":1,"fields":[]}
EOF

# Build Blueprint
cardano-cli conway transaction build-raw \
  --tx-in $SCRIPT_UTXO_TXIX \
  --tx-in-script-file "$SCRIPT_FILE" \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file "$HOME/deposit-redeemer.json" \
  --tx-in-execution-units '(6000000, 2000000000)' \
  --tx-out "$POOL_ADDR+12000000+$TOKEN_QUANTITY $ASSET_ID" \
  --tx-out-inline-datum-cbor-file "$HOME/pool-datum.cbor" \
  --required-signer-hash $CREATOR_HASH \
  --fee 0 \
  --out-file "$HOME/deposit-blueprint.json"

echo "✅ Blueprint transaction created"
echo ""

# ============================================================================
# STEP 3: Inject Script & Create Request (NO CHAIN WAIT!)
# ============================================================================

echo "📦 Step 3: Injecting script directly into deposit request..."

# Lấy CBOR hex từ file .plutus
SCRIPT_CBOR=$(jq -r '.cborHex' "$SCRIPT_FILE")

if [ -z "$SCRIPT_CBOR" ] || [ "$SCRIPT_CBOR" == "null" ]; then
    echo "❌ Failed to extract script CBOR from $SCRIPT_FILE"
    exit 1
fi

echo "✅ Script CBOR extracted (${#SCRIPT_CBOR} chars)"

# Inject script vào UTxO JSON để Hydra node biết validator
# Hydra cần script để giả lập transaction, không cần reference script on-chain
UPDATED_UTXO=$(echo "$UTXO_JSON" | jq --arg cbor "$SCRIPT_CBOR" '
  to_entries | map(
    .value += {
      "referenceScript": {
        "script": {
          "cborHex": $cbor,
          "description": "",
          "type": "PlutusScriptV3"
        }
      }
    }
  ) | from_entries
')

echo "✅ Script injected into UTxO"

# Tạo deposit request với script đã inject
BLUEPRINT_JSON=$(cat $HOME/deposit-blueprint.json)

jq -n \
  --argjson utxo "${UPDATED_UTXO}" \
  --argjson blueprintTx "${BLUEPRINT_JSON}" \
  '{ "utxo": $utxo, "blueprintTx": $blueprintTx }' \
  > $HOME/deposit-request.json

echo "✅ Deposit request created with injected script"
echo ""

# ============================================================================
# STEP 4: Send to Hydra
# ============================================================================

echo "📤 Step 4: Sending to Hydra..."

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
echo ""

# ============================================================================
# STEP 5: Sign & Submit
# ============================================================================

echo "✍️  Step 5: Signing..."
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

echo "📤 Step 6: Submitting..."
cardano-cli conway transaction submit \
  --tx-file $HOME/deposit-signed.json \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH

echo "🎉 DONE! Pool Deposited to Hydra Head!"