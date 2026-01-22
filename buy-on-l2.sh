#!/bin/bash
set -e

# ============================================================================
# 1. CONFIGURATION (Sửa tại đây)
# ============================================================================
USER="alice"          # Chọn "alice" hoặc "bob"
AMOUNT_TO_BUY=2      # Số lượng token muốn mua

# Cấu hình dự án PUMP.CARDANO
export POLICY_ID="3dda0b9b89f7cfc3a7c0cdacda60abca405f4e27780f7c773ec7732a"
export TOKEN_NAME_HEX="50554d50" 
export ASSET_ID="${POLICY_ID}.${TOKEN_NAME_HEX}"
export SCRIPT_ADDR="addr_test1wq7a5zum38mulsa8crx6eknq409yqh6wyauq7lrh8mrhx2smft2f0"
export CREDENTIALS_PATH="$HOME/credentials"
export HYDRA_API="http://127.0.0.1:4001"

# Tự động nhận diện Key và Address
BUYER_SKEY="${CREDENTIALS_PATH}/${USER}-funds.sk"
BUYER_VKEY="${CREDENTIALS_PATH}/${USER}-funds.vk"
BUYER_ADDR=$(cardano-cli address build --payment-verification-key-file $BUYER_VKEY --testnet-magic 1)
BUYER_HASH=$(cardano-cli address key-hash --payment-verification-key-file $BUYER_VKEY)

echo "👤 Signer: $USER | Mua: $AMOUNT_TO_BUY PUMP"

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

# Lấy dữ liệu Pool (Slope, Supply, ADA hiện tại)
POOL_DATUM=$(jq -r ".[\"$POOL_UTXO\"].inlineDatum" tmp/head-utxos.json)
SLOPE=$(echo $POOL_DATUM | jq -r '.fields[2].int')
CURRENT_SUPPLY=$(echo $POOL_DATUM | jq -r '.fields[3].int')
POOL_ADA=$(jq -r ".[\"$POOL_UTXO\"].value.lovelace" tmp/head-utxos.json)
POOL_TOKENS=$(jq -r ".[\"$POOL_UTXO\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] // 0" tmp/head-utxos.json)

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
# 3. LOGIC TÍNH TOÁN (ĐẢM BẢO CÂN BẰNG ADA)
# ============================================================================
# Tính Cost: Slope * (supply_end^2 - supply_start^2) / 2
NEW_SUPPLY=$((CURRENT_SUPPLY + AMOUNT_TO_BUY))
COST=$(( (SLOPE * (NEW_SUPPLY * NEW_SUPPLY - CURRENT_SUPPLY * CURRENT_SUPPLY)) / 2 ))
MAX_COST=$(( COST * 105 / 100 ))

# TỔNG ADA ĐẦU VÀO = Pool ADA + Payment ADA
TOTAL_IN=$((POOL_ADA + PAYMENT_ADA))

# TỔNG ADA ĐẦU RA (Phải bằng TOTAL_IN vì fee = 0)
NEW_POOL_ADA=$((POOL_ADA + COST))
NEW_BUYER_ADA=$((TOTAL_IN - NEW_POOL_ADA))

# Token balance: Payment UTXO có thể đã có token
NEW_BUYER_TOKENS=$((PAYMENT_TOKENS + AMOUNT_TO_BUY))

echo "💹 Cost: $COST lovelace. Cân bằng ví: $TOTAL_IN lovelace."
echo "💹 Tokens: Payment có $PAYMENT_TOKENS, mua thêm $AMOUNT_TO_BUY → tổng $NEW_BUYER_TOKENS"

# ============================================================================
# 4. BUILD TX
# ============================================================================
# Tạo datum file
jq -n --arg pol "$POLICY_ID" --argjson sup $NEW_SUPPLY --arg cre "a0abf91dee3e17b3b3091bbc4acdd395209b7925fd62f147aae85416" \
  '{"constructor":0,"fields":[{"bytes":$pol},{"bytes":"50554d50"},{"int":1000000},{"int":$sup},{"bytes":$cre}]}' > tmp/new-datum.json

# Tạo redeemer file
jq -n --argjson amt $AMOUNT_TO_BUY --argjson max $MAX_COST \
  '{"constructor":1,"fields":[{"int":$amt},{"int":$max}]}' > tmp/buy-redeemer.json

# Build transaction
cardano-cli conway transaction build-raw \
  --protocol-params-file tmp/protocol-params.json \
  --tx-in $POOL_UTXO \
  --tx-in-script-file ~/pump-spend.plutus \
  --tx-in-inline-datum-present \
  --tx-in-redeemer-file tmp/buy-redeemer.json \
  --tx-in-execution-units '(10000000000, 16500000)' \
  --tx-in $PAYMENT_UTXO \
  --tx-in-collateral $COLLATERAL_UTXO \
  --tx-out "$SCRIPT_ADDR + $NEW_POOL_ADA lovelace + $((POOL_TOKENS - AMOUNT_TO_BUY)) $ASSET_ID" \
  --tx-out-inline-datum-file tmp/new-datum.json \
  --tx-out "$BUYER_ADDR + $NEW_BUYER_ADA lovelace + $NEW_BUYER_TOKENS $ASSET_ID" \
  --fee 0 \
  --out-file tmp/tx-body.json

# ============================================================================
# 5. KÝ VÀ SUBMIT
# ============================================================================
cardano-cli conway transaction sign --tx-body-file tmp/tx-body.json --signing-key-file $BUYER_SKEY --out-file tmp/tx-signed.json

echo "📤 Submitting to Hydra L2..."
curl -s -X POST $HYDRA_API/transaction --data @tmp/tx-signed.json | jq .