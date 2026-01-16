#!/bin/bash
set -e

echo "🚀 === Hydra Head Alice Commit ==="

# 1. Cấu hình đường dẫn tuyệt đối
export CARDANO_NODE_SOCKET_PATH=/home/g1bssq/node.socket
export TESTNET_MAGIC=1
export CREDENTIALS_PATH=$HOME/credentials  # <--- SỬA QUAN TRỌNG
export ALICE_ADDR=$(cat $CREDENTIALS_PATH/alice-funds.addr)

echo "📋 Alice Address: $ALICE_ADDR"
echo "📂 Credentials Path: $CREDENTIALS_PATH"

# 2. Tìm UTxO của Alice để commit
echo "🔍 Tìm kiếm UTxO của Alice..."
UTXO_ID=$(cardano-cli query utxo --address $ALICE_ADDR --testnet-magic $TESTNET_MAGIC --output-json | jq -r 'keys[0]')

if [ -z "$UTXO_ID" ] || [ "$UTXO_ID" == "null" ]; then
  echo "❌ Ví Alice rỗng, không có gì để commit!"
  exit 1
fi
echo "✅ Chọn UTxO: $UTXO_ID"

# 3. Lấy thông tin chi tiết UTxO đó
echo "📦 Đang lấy dữ liệu UTxO..."
UTXO_JSON=$(cardano-cli query utxo --tx-in $UTXO_ID --testnet-magic $TESTNET_MAGIC --output-json)

# 4. Gửi yêu cầu Commit sang Hydra Node
echo "📝 Gửi request sang Hydra Node..."
jq -n --argjson u "$UTXO_JSON" '$u' > alice-payload.json

# Gọi API commit
curl -s -X POST \
  --data @alice-payload.json \
  http://127.0.0.1:4001/commit \
  > alice-tx.json

# Kiểm tra lỗi từ Hydra
if grep -q "Error" alice-tx.json; then
  echo "❌ Lỗi từ Hydra Node:"
  cat alice-tx.json
  exit 1
fi

# 5. Ký giao dịch
echo "✍️  Ký giao dịch..."
jq -r '.cborHex' alice-tx.json > alice-tx.cbor

cat > alice-envelope.json << EOT
{
    "type": "Tx ConwayEra",
    "description": "",
    "cborHex": "$(cat alice-tx.cbor)"
}
EOT

# Ký bằng CẢ 2 CHÌA KHÓA (Funds + Node)
# Dùng $CREDENTIALS_PATH để trỏ đúng file
cardano-cli conway transaction sign \
  --tx-body-file alice-envelope.json \
  --signing-key-file $CREDENTIALS_PATH/alice-funds.sk \
  --signing-key-file $CREDENTIALS_PATH/alice-node.sk \
  --out-file alice-signed.json

# 6. Gửi giao dịch
echo "📤 Submit giao dịch..."
cardano-cli conway transaction submit \
  --tx-file alice-signed.json \
  --testnet-magic $TESTNET_MAGIC \
  --socket-path $CARDANO_NODE_SOCKET_PATH

echo "🎉 THÀNH CÔNG! Alice đã commit."
