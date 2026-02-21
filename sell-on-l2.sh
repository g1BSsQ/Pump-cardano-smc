#!/bin/bash
set -euo pipefail

# ============================================================================
# 1. CONFIGURATION
# ============================================================================
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export SCRIPT_FILE="$SCRIPT_DIR/plutus-scripts/pump-spend.plutus"

USER="bob"          # Người bán
AMOUNT_TO_SELL=100000 # Số lượng token muốn bán (Điều chỉnh tại đây)

export POLICY_ID="5d661e7f0b3bfdd2601ce01604a68a90b8cf5877f0bc391d094bb816"
export TOKEN_NAME_HEX="c3a164617364"
export ASSET_ID="${POLICY_ID}.${TOKEN_NAME_HEX}"
export SCRIPT_ADDR="addr_test1wpwkv8nlpvalm5nqrnspvp9x32gt3n6cwlctcwgap99ms9smf9w9j"
export CREDENTIALS_PATH="$HOME/credentials"
export HYDRA_API="http://127.0.0.1:4001"

VIRTUAL_ADA=30000000000
VIRTUAL_TOKEN=300000000
MAX_SUPPLY=1000000000
PLATFORM_FEE_BP=100
BASIS_POINTS_DIVISOR=10000
MIN_FEE=1000000
PLATFORM_ADDR="addr_test1qp5ze98ws7yvehsmg0kf9fsg6u88u9zd2udzyxzwpvm0ffe0dheqe6zch30uc36lwr2xvnhqmyrl6aqzjfpp4ftxaecsdfm0ty"

SELLER_SKEY="${CREDENTIALS_PATH}/${USER}-funds.sk"
SELLER_VKEY="${CREDENTIALS_PATH}/${USER}-funds.vk"
SELLER_ADDR_FILE="${CREDENTIALS_PATH}/${USER}-funds.addr"

if [ -f "$SELLER_ADDR_FILE" ]; then
  SELLER_ADDR=$(cat "$SELLER_ADDR_FILE")
else
  SELLER_ADDR=$(cardano-cli address build --payment-verification-key-file "$SELLER_VKEY" --testnet-magic 1)
fi

echo "👤 Signer: $USER | Bán: $AMOUNT_TO_SELL PUMP"

# ============================================================================
# 2. SETUP & QUERY
# ============================================================================
mkdir -p tmp
echo "🔍 Đang lấy UTXO từ Hydra Head..."
curl -s $HYDRA_API/snapshot/utxo > tmp/head-utxos.json
curl -s $HYDRA_API/protocol-parameters > tmp/protocol-params.json

POOL_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$SCRIPT_ADDR\") | .key" tmp/head-utxos.json)
if [ -z "$POOL_UTXO" ]; then echo "❌ Pool không tồn tại trên L2"; exit 1; fi

POOL_DATUM=$(jq -r ".[\"$POOL_UTXO\"].inlineDatum" tmp/head-utxos.json)
CURRENT_SUPPLY=$(echo $POOL_DATUM | jq -r '.fields[2].int')
CREATOR=$(echo $POOL_DATUM | jq -r '.fields[3].bytes')
POOL_ADA=$(jq -r ".[\"$POOL_UTXO\"].value.lovelace" tmp/head-utxos.json)
POOL_TOKENS=$(jq -r ".[\"$POOL_UTXO\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] // 0" tmp/head-utxos.json)

# TÌM UTXO BÁN: Phải có đủ ADA làm collateral/phí và có chứa Token để bán
PAYMENT_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$SELLER_ADDR\" and (.value.value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] // 0) >= $AMOUNT_TO_SELL) | {txix: .key, amt: .value.value.lovelace} | select(.amt > 1000000) | .txix" tmp/head-utxos.json | head -1)

if [ -z "$PAYMENT_UTXO" ]; then
    echo "❌ Lỗi: Không tìm thấy UTXO của $USER có đủ số dư (tối thiểu $AMOUNT_TO_SELL Token và >1 ADA)."
    exit 1
fi

PAYMENT_ADA=$(jq -r ".[\"$PAYMENT_UTXO\"].value.lovelace" tmp/head-utxos.json)
PAYMENT_TOKENS=$(jq -r ".[\"$PAYMENT_UTXO\"].value[\"$POLICY_ID\"][\"$TOKEN_NAME_HEX\"] // 0" tmp/head-utxos.json)

COLLATERAL_UTXO=$(jq -r "to_entries[] | select(.value.address == \"$SELLER_ADDR\" and (.value.value // .value | keys | length == 1)) | .key" tmp/head-utxos.json | head -1)
if [ -z "$COLLATERAL_UTXO" ]; then COLLATERAL_UTXO=$PAYMENT_UTXO; fi

# ============================================================================
# 3. AMM CALCULATION (SELL LOGIC)
# ============================================================================
NEW_SUPPLY=$((CURRENT_SUPPLY - AMOUNT_TO_SELL))
if [ $NEW_SUPPLY -lt 0 ]; then
    echo "❌ Lỗi: Tổng cung không thể < 0!"
    exit 1
fi

K=$(echo "$VIRTUAL_ADA * ($MAX_SUPPLY + $VIRTUAL_TOKEN)" | bc)
TOTAL_TOKEN_NEW=$(echo "$MAX_SUPPLY - $NEW_SUPPLY + $VIRTUAL_TOKEN" | bc)
TOTAL_ADA_NEW=$(echo "($K + $TOTAL_TOKEN_NEW - 1) / $TOTAL_TOKEN_NEW" | bc)
EXPECTED_ADA_NEW=$(echo "$TOTAL_ADA_NEW - $VIRTUAL_ADA" | bc)
if [ "$(echo "$EXPECTED_ADA_NEW < 0" | bc)" -eq 1 ]; then EXPECTED_ADA_NEW=0; fi

# Số ADA hoàn trả lại = Số ADA hiện tại trong Pool - Số ADA kỳ vọng (mới)
EXACT_REFUND=$(echo "$POOL_ADA - $EXPECTED_ADA_NEW" | bc)
if [ "$(echo "$EXACT_REFUND < 0" | bc)" -eq 1 ]; then
    echo "❌ Lỗi toán học: Pool không đủ ADA để hoàn trả!"
    exit 1
fi

FEE=$(echo "$EXACT_REFUND * $PLATFORM_FEE_BP / $BASIS_POINTS_DIVISOR" | bc)
FEE_OUTPUT=$(echo "if ($FEE < $MIN_FEE) $MIN_FEE else $FEE" | bc)
USER_RECEIVE=$(echo "$EXACT_REFUND - $FEE_OUTPUT" | bc)
MIN_REFUND_LIMIT=$(echo "$USER_RECEIVE * 95 / 100" | bc) # 5% slippage

NEW_SELLER_ADA=$(echo "$PAYMENT_ADA + $USER_RECEIVE" | bc)
NEW_POOL_ADA=$EXPECTED_ADA_NEW
NEW_POOL_TOKENS=$((POOL_TOKENS + AMOUNT_TO_SELL))
NEW_SELLER_TOKENS=$((PAYMENT_TOKENS - AMOUNT_TO_SELL))

echo "💹 AMM Bán: Hoàn trả $EXACT_REFUND lovelace (Phí sàn: $FEE_OUTPUT, Người dùng nhận: $USER_RECEIVE)"

# ============================================================================
# 4. BUILD TX
# ============================================================================
jq -n --arg pol "$POLICY_ID" --arg tnm "$TOKEN_NAME_HEX" --argjson sup "$NEW_SUPPLY" --arg cre "$CREATOR" \
  '{"constructor":0,"fields":[{"bytes":$pol},{"bytes":$tnm},{"int":$sup},{"bytes":$cre}]}' > tmp/new-datum.json

# Redeemer Sell là Constructor 3
jq -n --argjson amt "$AMOUNT_TO_SELL" --argjson min "$MIN_REFUND_LIMIT" \
  '{"constructor":3,"fields":[{"int":$amt},{"int":$min}]}' > tmp/sell-redeemer.json

# Hàm Build & Gửi giao dịch
build_and_submit(){
  cardano-cli conway transaction build-raw \
    --protocol-params-file tmp/protocol-params.json \
    --tx-in $POOL_UTXO \
    --tx-in-script-file "$SCRIPT_FILE" \
    --tx-in-inline-datum-present \
    --tx-in-redeemer-file tmp/sell-redeemer.json \
    --tx-in-execution-units '(10000000000, 16500000)' \
    --tx-in $PAYMENT_UTXO \
    --tx-in-collateral $COLLATERAL_UTXO \
    --tx-out "$SCRIPT_ADDR + $NEW_POOL_ADA lovelace + $NEW_POOL_TOKENS $ASSET_ID" \
    --tx-out-inline-datum-file tmp/new-datum.json \
    --tx-out "$SELLER_ADDR + $NEW_SELLER_ADA lovelace + $NEW_SELLER_TOKENS $ASSET_ID" \
    --tx-out "$PLATFORM_ADDR + $FEE_OUTPUT lovelace" \
    --fee 0 \
    --out-file tmp/tx-body.json

  cardano-cli conway transaction sign --tx-body-file tmp/tx-body.json --signing-key-file $SELLER_SKEY --out-file tmp/tx-signed.json

  curl -s -X POST $HYDRA_API/transaction --data @tmp/tx-signed.json
}

# ============================================================================
# 5. KÝ, SUBMIT & AUTO-PATCH HASH
# ============================================================================
echo "📤 Submitting to Hydra L2..."
RESP=$(build_and_submit)

if echo "$RESP" | grep -q "PPViewHashesDontMatch"; then
    echo "⚠️ Phát hiện lỗi lệch mã băm (PPViewHashesDontMatch)."
    echo "🔧 Đang tự động trích xuất và vá CBOR..."
    
    ERR_MSG=$(echo "$RESP" | jq -r '.validationError' || echo "$RESP")
    
    WRONG_HASH=$(echo "$ERR_MSG" | grep -oP 'mismatchSupplied = SJust \(SafeHash "\K[^"]+') || true
    RIGHT_HASH=$(echo "$ERR_MSG" | grep -oP 'mismatchExpected = SJust \(SafeHash "\K[^"]+') || true
    
    if [ -n "$WRONG_HASH" ] && [ -n "$RIGHT_HASH" ]; then
        echo "   Đã tìm thấy Hash! Vá: $WRONG_HASH -> $RIGHT_HASH"
        
        sed -i "s/$WRONG_HASH/$RIGHT_HASH/g" tmp/tx-body.json
        cardano-cli conway transaction sign --tx-body-file tmp/tx-body.json --signing-key-file "$SELLER_SKEY" --out-file tmp/tx-signed-patched.json
        
        echo "📤 Submitting Patched Transaction..."
        curl -s -X POST "$HYDRA_API/transaction" --data @tmp/tx-signed-patched.json | jq .
    else
        echo "❌ Lỗi: Không thể trích xuất mã băm bằng regex. Chi tiết log:"
        echo "$ERR_MSG"
    fi
else
    echo "$RESP" | jq .
fi