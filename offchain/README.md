# 🚀 Pump.fun Offchain - Bonding Curve DEX

Offchain code để tương tác với Pump.fun validator trên Cardano.

## 📦 Cài Đặt

```bash
npm install
```

## 🎯 Sử Dụng

### 1. Mint Pool & Token

```bash
npm run mint
```

Tạo pool mới với 1 triệu token và khóa trong pool với bonding curve.

**Output:**

- Policy ID
- Script Address
- Transaction Hash

**⚠️ LƯU LẠI:** Policy ID và Script Address để dùng cho bước tiếp theo!

### 2. Mua Token (Buy)

```bash
npm run buy
```

**Trước khi chạy:** Cập nhật `POOL_CONFIG` trong `src/buy-tokens.ts`:

```typescript
const POOL_CONFIG = {
  policyId: "YOUR_POLICY_ID",
  tokenName: "PUMP",
  scriptAddress: "YOUR_SCRIPT_ADDRESS",
  utxoTxHash: "YOUR_UTXO_HASH",
  utxoOutputIndex: 1,
};
```

### 3. Bán Token (Sell)

```bash
npm run sell
```

**Trước khi chạy:** Cập nhật `POOL_CONFIG` trong `src/sell-tokens.ts` tương tự Buy.

## 💡 Bonding Curve

### Công Thức

```
Price = Slope × Supply
Cost = Slope × (end² - start²) / 2
```

### Ví Dụ (Slope = 1,000,000 lovelace)

| Token # | Giá     | Chi Phí Tích Lũy |
| ------- | ------- | ---------------- |
| 1       | 1 ADA   | 0.5 ADA          |
| 10      | 10 ADA  | 50 ADA           |
| 100     | 100 ADA | 5,000 ADA        |

**Mua token từ 0→10:**

```
Cost = 1,000,000 × (10² - 0²) / 2 = 50 ADA
```

## 🔐 Security Features

✅ **Asset Swap Protection** - Không thể tráo token  
✅ **Supply Cap** - Giới hạn 1 tỷ token  
✅ **Free Token Prevention** - Cost > 0  
✅ **Rug Pull Protection** - Reserve calculation  
✅ **Slippage Protection** - 5% tolerance  
✅ **Min-ADA Enforcement** - Luôn ≥ 2 ADA

## 📁 Cấu Trúc

```
offchain/
├── src/
│   ├── mint-tokens.ts    # Tạo pool
│   ├── buy-tokens.ts     # Mua token
│   └── sell-tokens.ts    # Bán token
├── package.json
└── README.md
```

## 🔗 Links

- **Validator:** [../validators/pump.ak](../validators/pump.ak)
- **Aiken:** https://aiken-lang.org/
- **MeshJS:** https://meshjs.dev/
- **Cardano Preprod:** https://preprod.cardanoscan.io/

## 🐛 Troubleshooting

### "No UTxOs available"

- Thêm tADA từ faucet: https://docs.cardano.org/cardano-testnet/tools/faucet/

### "No pool UTXO found"

- Chạy `npm run mint` để tạo pool trước

