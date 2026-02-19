#!/bin/bash
set -e

# ============================================================================
# 1. CONFIGURATION (Sửa tại đây)
# ============================================================================
USER="alice"          # Chọn "alice" hoặc "bob"
AMOUNT_TO_BUY=1000000      # Số lượng token muốn mua (1M)

# Cấu hình dự án PUMP.CARDANO (AMM VERSION)
export POLICY_ID="1254a9c1293231cb25eb202af80f9f73292b25e335118d7c7f1a27d4"
export TOKEN_NAME_HEX="50554d50" 
export ASSET_ID="${POLICY_ID}.${TOKEN_NAME_HEX}"
export SCRIPT_ADDR="addr_test1vzs2h7gaaclp0vanpydmcjkd6w2jpxmeyh7k9u284t59g9scejnr3"
export CREDENTIALS_PATH="$HOME/credentials"
export HYDRA_API="http://127.0.0.1:4001"

# AMM Constants (Must match smart contract)
export MAX_SUPPLY=1000000000        # 1B tokens
export VIRTUAL_ADA=30000000000      # 30B lovelace
export VIRTUAL_TOKEN=300000000      # 300M tokens
export PLATFORM_FEE_BP=100          # 1% = 100 basis points
export PLATFORM_ADDR="addr_test1vpvzw8hw8c30svltxx37pfzrq0gpws28w9z3zsqtqqskxscahns3q"

# Tự động nhận diện Key và Address
BUYER_SKEY="${CREDENTIALS_PATH}/${USER}-funds.sk"
BUYER_VKEY="${CREDENTIALS_PATH}/${USER}-funds.vk"
BUYER_ADDR=$(cardano-cli address build --payment-verification-key-file $BUYER_VKEY --testnet-magic 1)
BUYER_HASH=$(cardano-cli address key-hash --payment-verification-key-file $BUYER_VKEY)

echo "👤 Signer: $USER | Mua: $AMOUNT_TO_BUY PUMP"
echo "📊 AMM Mode: Virtual ADA=$VIRTUAL_ADA, Virtual Token=$VIRTUAL_TOKEN"

# ============================================================================
# 2. SETUP & QUERY
# ============================================================================
# Tạo folder tmp để chứa các file tạm
mkdir -p tmp

echo "🔍 Đang lấy UTXO từ Hydra Head..."
curl -s $HYDRA_API/snapshot/utxo > tmp/head-utxos.json
curl -s $HYDRA_API/protocol-parameters > tmp/protocol-params.json

# Tìm UTXO của Pool
POOL_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$SCRIPT_ADDR\") | .key" tmp/head-utxos.json)
if [ -z "$POOL_UTXO" ]; then echo "❌ Pool không tồn tại trên L2"; exit 1; fi

# Lấy dữ liệu Pool (NEW FORMAT: 4 fields, không có slope)
# PoolDatum { token_policy, token_name, current_supply, creator }
POOL_DATUM=$(jq -r ".[\"$POOL_UTXO\"].inlineDatum" tmp/head-utxos.json)
CURRENT_SUPPLY=$(echo $POOL_DATUM | jq -r '.fields[2].int')
CREATOR=$(echo $POOL_DATUM | jq -r '.fields[3].bytes')
POOL_ADA=$(jq -r ".[\"$POOL_UTXO\"].value.lovelace" tmp/head-utxos.json)
POOL_TOKENS=$(jq -r ".[\"$POOL_UTXO\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] // 0" tmp/head-utxos.json)

echo "📊 Current Pool: Supply=$CURRENT_SUPPLY, ADA=$POOL_ADA, Tokens=$POOL_TOKENS"

# Lấy UTXO có nhiều ADA nhất (có thể có token) làm payment
PAYMENT_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$BUYER_ADDR\") | {txix: .key, amt: .value.value.lovelace} | select(.amt > 1000000) | .txix" tmp/head-utxos.json | head -1)
PAYMENT_ADA=$(jq -r ".[\"$PAYMENT_UTXO\"].value.lovelace" tmp/head-utxos.json)
PAYMENT_TOKENS=$(jq -r ".[\"$PAYMENT_UTXO\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] // 0" tmp/head-utxos.json)

# Lấy pure ADA UTXO làm collateral
COLLATERAL_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$BUYER_ADDR\" and (.value.value | keys | length == 1)) | .key" tmp/head-utxos.json | head -1)

if [ -z "$PAYMENT_UTXO" ] || [ -z "$COLLATERAL_UTXO" ]; then
    echo "❌ Lỗi: Không tìm thấy đủ UTXOs (cần 1 payment + 1 collateral pure ADA)"
    exit 1
fi

# ============================================================================
# 3. AMM CALCULATION (Constant Product Formula)
# ============================================================================

# Function: Calculate expected ADA reserve
# expected_ada = (k / (max_supply - current_supply + virtual_token)) - virtual_ada
calc_expected_ada() {
    local supply=$1
    local k=$(( VIRTUAL_ADA * (MAX_SUPPLY + VIRTUAL_TOKEN) ))
    local real_token_reserve=$(( MAX_SUPPLY - supply ))
    local total_token_reserve=$(( real_token_reserve + VIRTUAL_TOKEN ))
    
    if [ $total_token_reserve -le 0 ]; then
        echo 999999999999999
        return
    fi
    
    local total_ada_reserve=$(( (k + total_token_reserve - 1) / total_token_reserve ))
    local real_ada_reserve=$(( total_ada_reserve - VIRTUAL_ADA ))
    
    if [ $real_ada_reserve -lt 0 ]; then
        echo 0
    else
        echo $real_ada_reserve
    fi
}

# Calculate cost
NEW_SUPPLY=$(( CURRENT_SUPPLY + AMOUNT_TO_BUY ))

if [ $NEW_SUPPLY -gt $MAX_SUPPLY ]; then
    echo "❌ Cannot buy $AMOUNT_TO_BUY tokens. Only $((MAX_SUPPLY - CURRENT_SUPPLY)) remaining!"
    exit 1
fi

CURRENT_EXPECTED_ADA=$(calc_expected_ada $CURRENT_SUPPLY)
NEW_EXPECTED_ADA=$(calc_expected_ada $NEW_SUPPLY)
EXACT_COST=$(( NEW_EXPECTED_ADA - CURRENT_EXPECTED_ADA ))

# Calculate platform fee (1%)
FEE=$(( (EXACT_COST * PLATFORM_FEE_BP) / 10000 ))
TOTAL_COST=$(( EXACT_COST + FEE ))

# Slippage protection (2%)
MAX_COST=$(( TOTAL_COST * 102 / 100 ))

echo "💹 AMM Calculation:"
echo "   Current Supply: $CURRENT_SUPPLY → New: $NEW_SUPPLY"
echo "   Expected ADA: $CURRENT_EXPECTED_ADA → $NEW_EXPECTED_ADA"
echo "   Exact Cost: $EXACT_COST lovelace"
echo "   Platform Fee (1%): $FEE lovelace"
echo "   Total Cost: $TOTAL_COST lovelace"
echo "   Max Cost Limit (2% slippage): $MAX_COST lovelace"

# ============================================================================
# 4. BALANCE CALCULATION
# ============================================================================

# TỔNG ADA ĐẦU VÀO = Pool ADA + Payment ADA
TOTAL_IN=$(( POOL_ADA + PAYMENT_ADA ))

# TỔNG ADA ĐẦU RA (fee = 0 trên L2)
# Pool nhận exact_cost, Platform nhận fee, Buyer nhận số còn lại
NEW_POOL_ADA=$(( POOL_ADA + EXACT_COST ))
NEW_BUYER_ADA=$(( TOTAL_IN - NEW_POOL_ADA - FEE ))

# Token balance: Payment UTXO có thể đã có token
NEW_BUYER_TOKENS=$(( PAYMENT_TOKENS + AMOUNT_TO_BUY ))
NEW_POOL_TOKENS=$(( POOL_TOKENS - AMOUNT_TO_BUY ))

echo "💰 Balance:"
echo "   Total IN: $TOTAL_IN lovelace"
echo "   Pool ADA: $POOL_ADA → $NEW_POOL_ADA"
echo "   Pool Tokens: $POOL_TOKENS → $NEW_POOL_TOKENS"
echo "   Buyer ADA: $PAYMENT_ADA → $NEW_BUYER_ADA"
echo "   Buyer Tokens: $PAYMENT_TOKENS → $NEW_BUYER_TOKENS"
echo "   Platform Fee: $FEE lovelace"

# ============================================================================
# 5. BUILD TX
# ============================================================================
# Tạo datum file (NEW FORMAT: 4 fields, no slope)
jq -n --arg pol "$POLICY_ID" --argjson sup $NEW_SUPPLY --arg cre "$CREATOR" \
  '{"constructor":0,"fields":[{"bytes":$pol},{"bytes":"50554d50"},{"int":$sup},{"bytes":$cre}]}' > tmp/new-datum.json

# Tạo redeemer file (Buy { amount, max_cost_limit })
jq -n --argjson amt $AMOUNT_TO_BUY --argjson max $MAX_COST \
  '{"constructor":1,"fields":[{"int":$amt},{"int":$max}]}' > tmp/buy-redeemer.json

# Build transaction (với platform fee output)
cardano-cli conway transaction build-raw \
  --protocol-params-file tmp/protocol-params.json \
  --tx-in $POOL_UTXO \
  --tx-in-script-file ~/pump-spend.plutus \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file tmp/buy-redeemer.json \
  --tx-in-execution-units '(10000000000, 16500000)' \
  --tx-in $PAYMENT_UTXO \
  --tx-in-collateral $COLLATERAL_UTXO \
  --tx-out "$SCRIPT_ADDR + $NEW_POOL_ADA lovelace + $NEW_POOL_TOKENS $ASSET_ID" \
  --tx-out-inline-datum-file tmp/new-datum.json \
  --tx-out "$PLATFORM_ADDR + $FEE lovelace" \
  --tx-out "$BUYER_ADDR + $NEW_BUYER_ADA lovelace + $NEW_BUYER_TOKENS $ASSET_ID" \
  --fee 0 \
  --out-file tmp/tx-body.json

# ============================================================================
# 6. KÝ VÀ SUBMIT
# ============================================================================
cardano-cli conway transaction sign --tx-body-file tmp/tx-body.json --signing-key-file $BUYER_SKEY --out-file tmp/tx-signed.json

echo "📤 Submitting to Hydra L2..."
curl -s -X POST $HYDRA_API/transaction --data @tmp/tx-signed.json | jq .