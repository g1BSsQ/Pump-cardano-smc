#!/bin/bash
set -e

# ============================================================================
# 1. CONFIGURATION
# ============================================================================
USER="alice"          # Chọn "alice" hoặc "bob"
AMOUNT_TO_SELL=1     # Số lượng token muốn bán

# Cấu hình dự án PUMP.CARDANO
export POLICY_ID="3dda0b9b89f7cfc3a7c0cdacda60abca405f4e27780f7c773ec7732a"
export TOKEN_NAME_HEX="50554d50" 
export ASSET_ID="${POLICY_ID}.${TOKEN_NAME_HEX}"
export SCRIPT_ADDR="addr_test1wq7a5zum38mulsa8crx6eknq409yqh6wyauq7lrh8mrhx2smft2f0"
export CREDENTIALS_PATH="$HOME/credentials"
export HYDRA_API="http://127.0.0.1:4001"

# Tự động nhận diện Key và Address
SELLER_SKEY="${CREDENTIALS_PATH}/${USER}-funds.sk"
SELLER_VKEY="${CREDENTIALS_PATH}/${USER}-funds.vk"
SELLER_ADDR=$(cardano-cli address build --payment-verification-key-file $SELLER_VKEY --testnet-magic 1)
SELLER_HASH=$(cardano-cli address key-hash --payment-verification-key-file $SELLER_VKEY)

echo "👤 Signer: $USER | Bán: $AMOUNT_TO_SELL PUMP"

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

# Validate có đủ supply để bán không
if [ "$CURRENT_SUPPLY" -lt "$AMOUNT_TO_SELL" ]; then
    echo "❌ Cannot sell $AMOUNT_TO_SELL tokens. Current supply is only $CURRENT_SUPPLY"
    exit 1
fi

# Tìm UTXO có token của người bán
SELLER_TOKEN_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$SELLER_ADDR\" and .value.value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] != null) | .key" tmp/head-utxos.json)
if [ -z "$SELLER_TOKEN_UTXO" ]; then echo "❌ Bạn không có PUMP token"; exit 1; fi

SELLER_TOKENS=$(jq -r ".[\"$SELLER_TOKEN_UTXO\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"]" tmp/head-utxos.json)
if [ "$SELLER_TOKENS" -lt "$AMOUNT_TO_SELL" ]; then
    echo "❌ Không đủ token. Bạn có: $SELLER_TOKENS, cần: $AMOUNT_TO_SELL"
    exit 1
fi

SELLER_UTXO_ADA=$(jq -r ".[\"$SELLER_TOKEN_UTXO\"].value.lovelace" tmp/head-utxos.json)

# Lấy collateral (UTXO pure ADA)
COLLATERAL_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$SELLER_ADDR\" and (.value.value | keys | length == 1)) | .key" tmp/head-utxos.json | head -1)
if [ -z "$COLLATERAL_UTXO" ]; then
    echo "❌ Lỗi: Không tìm thấy collateral (pure ADA UTXO)"
    exit 1
fi

# ============================================================================
# 3. LOGIC TÍNH TOÁN REFUND (Ngược với Buy)
# ============================================================================
# Refund = Slope * (supply_end^2 - supply_start^2) / 2
# supply_start = current_supply - amount
# supply_end = current_supply
SUPPLY_START=$((CURRENT_SUPPLY - AMOUNT_TO_SELL))
REFUND=$(( (SLOPE * (CURRENT_SUPPLY * CURRENT_SUPPLY - SUPPLY_START * SUPPLY_START)) / 2 ))
MIN_REFUND=$(( REFUND * 95 / 100 ))  # 5% slippage protection

NEW_SUPPLY=$SUPPLY_START

# TỔNG ADA ĐẦU VÀO = Pool ADA + Seller UTXO ADA
TOTAL_IN=$((POOL_ADA + SELLER_UTXO_ADA))

# TỔNG ADA ĐẦU RA (Phải bằng TOTAL_IN vì fee = 0)
NEW_POOL_ADA=$((POOL_ADA - REFUND))
NEW_SELLER_ADA=$((TOTAL_IN - NEW_POOL_ADA))

# Token balance changes
NEW_POOL_TOKENS=$((POOL_TOKENS + AMOUNT_TO_SELL))
REMAINING_SELLER_TOKENS=$((SELLER_TOKENS - AMOUNT_TO_SELL))

echo "💹 Refund: $REFUND lovelace (Min: $MIN_REFUND)"
echo "💹 Cân bằng: Pool ADA: $POOL_ADA → $NEW_POOL_ADA, Seller ADA: $SELLER_UTXO_ADA → $NEW_SELLER_ADA"

# ============================================================================
# 4. BUILD TX
# ============================================================================
# Tạo datum file
jq -n --arg pol "$POLICY_ID" --argjson sup $NEW_SUPPLY --arg cre "a0abf91dee3e17b3b3091bbc4acdd395209b7925fd62f147aae85416" \
  '{"constructor":0,"fields":[{"bytes":$pol},{"bytes":"50554d50"},{"int":1000000},{"int":$sup},{"bytes":$cre}]}' > tmp/new-datum.json

# Tạo redeemer file (constructor 2 cho Sell)
jq -n --argjson amt $AMOUNT_TO_SELL --argjson min $MIN_REFUND \
  '{"constructor":2,"fields":[{"int":$amt},{"int":$min}]}' > tmp/sell-redeemer.json

# Build transaction
if [ "$REMAINING_SELLER_TOKENS" -gt 0 ]; then
    # Seller còn token → trả lại token + ADA
    cardano-cli conway transaction build-raw \
      --protocol-params-file tmp/protocol-params.json \
      --tx-in $POOL_UTXO \
      --tx-in-script-file ~/pump-spend.plutus \
      --tx-in-inline-datum-present \
      --tx-in-redeemer-file tmp/sell-redeemer.json \
      --tx-in-execution-units '(10000000000, 16500000)' \
      --tx-in $SELLER_TOKEN_UTXO \
      --tx-in-collateral $COLLATERAL_UTXO \
      --tx-out "$SCRIPT_ADDR + $NEW_POOL_ADA lovelace + $NEW_POOL_TOKENS $ASSET_ID" \
      --tx-out-inline-datum-file tmp/new-datum.json \
      --tx-out "$SELLER_ADDR + $NEW_SELLER_ADA lovelace + $REMAINING_SELLER_TOKENS $ASSET_ID" \
      --fee 0 \
      --out-file tmp/tx-body.json
else
    # Seller bán hết token → chỉ nhận ADA
    cardano-cli conway transaction build-raw \
      --protocol-params-file tmp/protocol-params.json \
      --tx-in $POOL_UTXO \
      --tx-in-script-file ~/pump-spend.plutus \
      --tx-in-inline-datum-present \
      --tx-in-redeemer-file tmp/sell-redeemer.json \
      --tx-in-execution-units '(10000000000, 16500000)' \
      --tx-in $SELLER_TOKEN_UTXO \
      --tx-in-collateral $COLLATERAL_UTXO \
      --tx-out "$SCRIPT_ADDR + $NEW_POOL_ADA lovelace + $NEW_POOL_TOKENS $ASSET_ID" \
      --tx-out-inline-datum-file tmp/new-datum.json \
      --tx-out "$SELLER_ADDR + $NEW_SELLER_ADA lovelace" \
      --fee 0 \
      --out-file tmp/tx-body.json
fi

# ============================================================================
# 5. KÝ VÀ SUBMIT
# ============================================================================
cardano-cli conway transaction sign --tx-body-file tmp/tx-body.json --signing-key-file $SELLER_SKEY --out-file tmp/tx-signed.json

echo "📤 Submitting to Hydra L2..."
curl -s -X POST $HYDRA_API/transaction --data @tmp/tx-signed.json | jq .
