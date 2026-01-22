#!/bin/bash
# Complete script to commit pool UTxO to Hydra Head
# Based on Hydra documentation

set -e

echo "🚀 === Hydra Head Pool Commit ==="
echo ""

# ============================================================================
# SETUP
# ============================================================================

export CARDANO_NODE_SOCKET_PATH=/home/g1bssq/node.socket
export POOL_ADDR=addr_test1wq7a5zum38mulsa8crx6eknq409yqh6wyauq7lrh8mrhx2smft2f0
export CREDENTIALS_PATH=$HOME/credentials
export TESTNET_MAGIC=1

echo "📋 Configuration:"
echo "   Pool Address: $POOL_ADDR"
echo "   Node Socket: $CARDANO_NODE_SOCKET_PATH"
echo "   Credentials: $CREDENTIALS_PATH"
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

if [ -z "$SCRIPT_UTXO_TXIX" ]; then
  echo "❌ No pool UTxO found"
  exit 1
fi

echo "✅ Captured script UTxO TxIn: $SCRIPT_UTXO_TXIX"
echo ""

# ============================================================================
# STEP 2: Prepare simple blueprint transaction
# ============================================================================

echo "🔨 Step 2: Building CommitToHydra blueprint transaction..."

# Tính creator key hash (Bob) - phải khớp với datum.creator
CREATOR_HASH=$(cardano-cli address key-hash --payment-verification-key-file ${CREDENTIALS_PATH}/bob-funds.vk)
echo "🔑 Creator Hash: $CREATOR_HASH"

# CommitToHydra redeemer: Constructor 4 (theo thứ tự trong Action enum)
# 0=MintInitial, 1=Buy, 2=Sell, 3=AdminWithdraw, 4=CommitToHydra
# Logic: Chỉ check chữ ký creator, không check outputs
cat > $HOME/commit-redeemer.json << EOF
{"constructor":4,"fields":[]}
EOF

echo "✅ CommitToHydra redeemer created (constructor 4, no fields)"

# Dummy output address cho blueprint (Hydra sẽ thay thế bằng Head script)
DUMMY_ADDR=$(cardano-cli address build --payment-verification-key-file ${CREDENTIALS_PATH}/bob-funds.vk --testnet-magic $TESTNET_MAGIC)

# Build CommitToHydra transaction blueprint
# ExUnits thấp vì logic đơn giản (chỉ check chữ ký): (1000000, 200000000)
cardano-cli conway transaction build-raw \
  --tx-in $SCRIPT_UTXO_TXIX \
  --tx-in-script-file $HOME/pump-spend.plutus \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file $HOME/commit-redeemer.json \
  --tx-in-execution-units '(1000000, 200000000)' \
  --tx-out "$DUMMY_ADDR+5000000+1000000 3dda0b9b89f7cfc3a7c0cdacda60abca405f4e27780f7c773ec7732a.50554d50" \
  --fee 0 \
  --out-file $HOME/blueprint-tx.json

echo "✅ Blueprint transaction created"
cat $HOME/blueprint-tx.json | jq . | head -20
echo ""

# ============================================================================
# STEP 3: Query UTxO context
# ============================================================================

echo "📦 Step 3: Querying UTxO context..."

# Query the specific UTxO to get full context including inline datum
UTXO_JSON=$(cardano-cli query utxo \
  --tx-in ${SCRIPT_UTXO_TXIX} \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH \
  --output-json)

echo "✅ UTxO context captured"
echo "$UTXO_JSON" | jq . | head -30
echo ""

# ============================================================================
# STEP 4: Create commit request
# ============================================================================

echo "📝 Step 4: Creating commit request..."

# Read blueprint
BLUEPRINT_JSON=$(cat $HOME/blueprint-tx.json)

# Create the commit request with both utxo context and blueprintTx
jq -n \
  --argjson utxo "${UTXO_JSON}" \
  --argjson blueprintTx "${BLUEPRINT_JSON}" \
  '{ "utxo": $utxo, "blueprintTx": $blueprintTx }' \
  > $HOME/commit-request.json

echo "✅ Commit request created"
echo "Preview:"
cat $HOME/commit-request.json | jq . | head -40
echo ""

# ============================================================================
# STEP 5: Send commit request to Hydra node
# ============================================================================

echo "📤 Step 5: Sending commit request to Hydra node (port 4001)..."

curl -X POST \
  --data @$HOME/commit-request.json \
  http://127.0.0.1:4001/commit \
  > $HOME/commit-tx.json

echo ""
echo "✅ Received response from Hydra node:"
echo "Raw response (first 500 chars):"
head -c 500 $HOME/commit-tx.json
echo ""
echo ""

# Try to parse as JSON
if jq -e . $HOME/commit-tx.json > /dev/null 2>&1; then
  echo "Response is valid JSON:"
  cat $HOME/commit-tx.json | jq . | head -30
else
  echo "Response is not JSON, checking if it's a transaction CBOR..."
  # Check if it's a hex-encoded transaction
  if grep -q "^[0-9a-f]*$" $HOME/commit-tx.json; then
    echo "✅ Received transaction CBOR hex"
  fi
fi
echo ""

# Check if response is an error
if cat $HOME/commit-tx.json | jq -e '.tag' > /dev/null 2>&1; then
  ERROR_TAG=$(cat $HOME/commit-tx.json | jq -r '.tag')
  
  if [ "$ERROR_TAG" = "FailedToDraftTxNotInitializing" ]; then
    echo "❌ Error: Head is not in Initializing state"
    echo ""
    echo "💡 You need to initialize the Head first:"
    echo "   curl -X POST http://127.0.0.1:4002 \\"
    echo "     --header 'Content-Type: application/json' \\"
    echo "     --data '{\"tag\": \"Init\"}'"
    echo ""
    exit 1
  elif [ "$ERROR_TAG" != "null" ]; then
    echo "❌ Error from Hydra node: $ERROR_TAG"
    exit 1
  fi
fi

# ============================================================================
# STEP 6: Sign the commit transaction
# ============================================================================

echo "✍️  Step 6: Signing commit transaction..."

# 1. Trích xuất CBOR Hex chuẩn (An toàn nhất)
jq -r '.cborHex' $HOME/commit-tx.json > $HOME/commit-tx.cbor

# 2. Tạo Envelope dạng Tx (Full Transaction)
cat > $HOME/commit-tx-envelope.json << EOF
{
    "type": "Tx ConwayEra",
    "description": "",
    "cborHex": "$(cat $HOME/commit-tx.cbor)"
}
EOF

# 3. Ký giao dịch
# QUAN TRỌNG: Dùng --tx-body-file nhưng trỏ vào file envelope vừa tạo
# (Cardano CLI đôi khi coi Full Tx chưa đủ chữ ký là Body)
cardano-cli conway transaction sign \
  --tx-body-file $HOME/commit-tx-envelope.json \
  --signing-key-file ${CREDENTIALS_PATH}/bob-funds.sk \
  --signing-key-file ${CREDENTIALS_PATH}/alice-node.sk \
  --out-file $HOME/commit-signed.json

echo "✅ Transaction signed"

# ============================================================================
# STEP 7: Submit the commit transaction
# ============================================================================

echo "📤 Step 7: Submitting commit transaction to Cardano network..."

cardano-cli conway transaction submit \
  --tx-file $HOME/commit-signed.json \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH

echo ""
echo "✅ Commit transaction submitted!"
echo ""

# ============================================================================
# SUMMARY
# ============================================================================

echo "🎉 === Success! Pool UTxO committed to Hydra Head ==="
echo ""
echo "📊 Summary:"
echo "   Pool UTxO: $SCRIPT_UTXO_TXIX"
echo "   Blueprint: $HOME/blueprint-tx.json"
echo "   Commit Request: $HOME/commit-request.json"
echo "   Signed Transaction: $HOME/commit-signed.json"
echo ""
echo "📋 Next Steps:"
echo "   1. ⏳ Wait for transaction confirmation on-chain"
echo "   2. 👥 Other participants must also commit their UTxOs"
echo "   3. 🔓 Once all committed, send CollectCom to open the Head"
echo "   4. 🎯 Head will be open and ready for L2 trading"
echo ""
echo "💡 To check Head status:"
echo "   curl -s http://127.0.0.1:4001/snapshot/utxo | jq ."
