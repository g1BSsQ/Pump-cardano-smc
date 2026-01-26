#!/bin/bash
set -e

# ============================================================================
# 1. CẤU HÌNH
# ============================================================================
USER="alice" 
MIN_ADA_FOR_TOKEN=2000000 

export POLICY_ID="b6c9c5be7517a9412f09932692e7fe32f8fa4d56b89d37ec08559b22"
export TOKEN_NAME_HEX="50554d50"
export ASSET_ID="${POLICY_ID}.${TOKEN_NAME_HEX}"
export CREDENTIALS_PATH="$HOME/credentials"
export HYDRA_API="http://127.0.0.1:4001"

BUYER_SKEY="${CREDENTIALS_PATH}/${USER}-funds.sk"
BUYER_VKEY="${CREDENTIALS_PATH}/${USER}-funds.vk"
BUYER_ADDR=$(cardano-cli address build --payment-verification-key-file $BUYER_VKEY --testnet-magic 1)

# 2. LẤY UTXO TỪ SNAPSHOT
echo "🔍 Đang quét UTXO của $USER trên Layer 2..."
curl -s "$HYDRA_API/snapshot/utxo" > tmp/snapshot-utxos.json

# Lọc các UTXO thuộc về Alice
USER_UTXOS=$(jq -r --arg addr "$BUYER_ADDR" 'with_entries(select(.value.address == $addr))' tmp/snapshot-utxos.json)

if [ "$USER_UTXOS" == "{}" ]; then
    echo "❌ Không tìm thấy UTXO nào cho $USER."
    exit 1
fi

# 3. TÍNH TOÁN TỔNG TÀI SẢN
TX_INS=$(echo "$USER_UTXOS" | jq -r 'keys[]' | sed 's/^/--tx-in /' | tr '\n' ' ')
TOTAL_LOVELACE=$(echo "$USER_UTXOS" | jq -r '[.[] | .value.lovelace] | add')
TOTAL_TOKENS=$(echo "$USER_UTXOS" | jq -r --arg pol "$POLICY_ID" --arg tkn "$TOKEN_NAME_HEX" \
    '[.[] | .value[$pol][$tkn] // 0] | add')

REMAINING_ADA=$((TOTAL_LOVELACE - MIN_ADA_FOR_TOKEN))

echo "📊 Tổng tài sản: $((TOTAL_LOVELACE/1000000)) ADA và $TOTAL_TOKENS PUMP"

# 4. TẠO GIAO DỊCH (BUILD & SIGN)
echo "🛠  Đang build giao dịch gộp và tách..."
cardano-cli conway transaction build-raw \
  $TX_INS \
  --tx-out "$BUYER_ADDR + $MIN_ADA_FOR_TOKEN lovelace + $TOTAL_TOKENS $ASSET_ID" \
  --tx-out "$BUYER_ADDR + $REMAINING_ADA lovelace" \
  --fee 0 \
  --out-file tmp/tx-signed.json # Đặt tên trùng với lệnh curl bạn muốn

cardano-cli conway transaction sign \
  --tx-body-file tmp/tx-signed.json \
  --signing-key-file "$BUYER_SKEY" \
  --out-file tmp/tx-signed.json

# 5. SUBMIT QUA HTTP POST (Theo cách bạn muốn)
echo "🚀 Đang gửi giao dịch lên Hydra qua HTTP POST..."

# Thêm Header Content-Type để tránh lỗi "unexpected t"
curl -X POST "$HYDRA_API/transaction" \
  -H "Content-Type: application/json" \
  --data @tmp/tx-signed.json

echo -e "\n✅ Giao dịch đã gửi thành công!"