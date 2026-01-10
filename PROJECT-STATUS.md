# ✅ Pump.fun Project - Ready to Use

## 📦 Files Còn Lại (Clean)

### 🔧 Smart Contract

- `validators/pump.ak` - Validator với bonding curve và security features

### 💻 Offchain Code

- `offchain/src/mint-tokens.ts` - Tạo pool và mint token
- `offchain/src/buy-tokens.ts` - Mua token từ pool
- `offchain/src/sell-tokens.ts` - Bán token về pool

### 📄 Configuration

- `offchain/package.json` - Scripts: mint, buy, sell
- `offchain/README.md` - Hướng dẫn sử dụng
- `plutus.json` - Compiled validator
- `aiken.toml` - Aiken config

## 🚀 Quick Start

```bash
# 1. Install
cd offchain
npm install

# 2. Mint pool
npm run mint
# → Lưu lại: Policy ID, Script Address, UTXO Hash

# 3. Update POOL_CONFIG trong buy-tokens.ts và sell-tokens.ts

# 4. Mua token
npm run buy

# 5. Bán token
npm run sell
```

## ✅ Đã Test & Hoạt Động

### Mint ✅

- One-shot minting policy
- Tạo pool với 1M tokens
- Lock token trong pool UTXO
- Output: Policy ID + Script Address

### Buy ✅

- Bonding curve calculation
- Slippage protection (5%)
- Supply update
- ADA/token balance changes

### Sell ✅

- Refund calculation
- Slippage protection (5%)
- Min-ADA enforcement
- Token return to pool

## 🔐 Security Features (Đã Implement)

✅ Asset Swap Protection  
✅ Supply Cap (1 tỷ)  
✅ Free Token Prevention (cost > 0)  
✅ Rug Pull Protection (reserve check)  
✅ Slippage Protection (5%)  
✅ Min-ADA (2 ADA)  
✅ UTXO Bloat Prevention  
✅ Dust Output Handling

## 📊 Bonding Curve

```
Price = Slope × Supply
Cost = Slope × (end² - start²) / 2
```

**Ví dụ (Slope = 1M):**

- Token #1: 1 ADA
- Token #10: 10 ADA
- Mua 0→10: 50 ADA

## 🎯 Status

**READY TO USE** ✅

Tất cả core features (mint, buy, sell) đã được test và hoạt động đúng.
