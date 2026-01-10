import {
  BlockfrostProvider,
  MeshWallet,
  MeshTxBuilder,
  PlutusScript,
  serializePlutusScript,
  applyParamsToScript,
  resolveScriptHash,
  mConStr0,
  mConStr2,
  deserializeDatum,
} from '@meshsdk/core';
import blueprint from '../../plutus.json';

// ============================================================================
// CONFIGURATION
// ============================================================================

const blockchainProvider = new BlockfrostProvider(
  process.env.BLOCKFROST_API_KEY || 'preprodx5cQKfPVxM066Svrll0DLWjl1Zh4IBeE'
);

const wallet = new MeshWallet({
  networkId: 0,
  fetcher: blockchainProvider,
  submitter: blockchainProvider,
  key: {
    type: 'mnemonic',
    words: [
      'void', 'veteran', 'resist', 'invest', 'virtual', 'stomach',
      'accident', 'lock', 'toddler', 'guitar', 'video', 'short',
      'lock', 'adult', 'zoo', 'require', 'ten', 'dose',
      'eagle', 'shuffle', 'employ', 'parrot', 'slogan', 'timber'
    ],
  },
});

// ============================================================================
// CONFIG - CẬP NHẬT THÔNG TIN POOL CỦA BẠN
// ============================================================================

const POOL_CONFIG = {
  policyId: '4c300520bc731cd1467d63642f61312b2c4e5a17d8dba3d3fa95e258',
  tokenName: 'PUMP',
  scriptAddress: 'addr_test1wpxrqpfqh3e3e52x043kgtmpxy4jcnj6zlvdhg7nl227ykq3jq7sv',
  // UTXO được dùng khi tạo pool (one-shot parameters)
  utxoTxHash: '13181542efaa356afae7ef83d87e85801412f89056fc9814df39baf6a8ddec9f',
  utxoOutputIndex: 1,
};

// Số lượng token muốn bán
const AMOUNT_TO_SELL = 3;

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

interface PoolDatum {
  token_policy: string;
  token_name: string;
  slope: number;
  current_supply: number;
  creator: string;
}

function parsePoolDatum(datum: any): PoolDatum {
  // Datum có cấu trúc: {constructor: 0, fields: [{bytes}, {bytes}, {int}, {int}, {bytes}]}
  const fields = datum.fields;
  return {
    token_policy: fields[0].bytes,
    token_name: Buffer.from(fields[1].bytes, 'hex').toString('utf8'),
    slope: fields[2].int,
    current_supply: fields[3].int,
    creator: fields[4].bytes,
  };
}

// Tính tiền nhận được khi bán token (refund)
// Formula: Cost = Slope * (supply_end^2 - supply_start^2) / 2
// Khi bán: supply_start = current_supply - amount, supply_end = current_supply
function calculateRefund(slope: number, currentSupply: number, amount: number): number {
  const supplyStart = currentSupply - amount;
  const supplyEnd = currentSupply;
  const endSquared = supplyEnd * supplyEnd;
  const startSquared = supplyStart * supplyStart;
  return Math.floor(slope * (endSquared - startSquared) / 2);
}

function getPumpScript(utxoParams: { txHash: string; outputIndex: number }) {
  const { txHash, outputIndex } = utxoParams;

  // Lấy validator từ blueprint
  const pumpValidator = blueprint.validators.find(
    (v) => v.title === 'pump.pump.spend'
  );

  if (!pumpValidator) {
    throw new Error('❌ Pump spend validator not found in plutus.json');
  }

  // Apply parameters (txHash, outputIndex)
  const scriptCbor = applyParamsToScript(pumpValidator.compiledCode, [
    txHash,
    outputIndex,
  ]);

  // Get policy ID (minting policy)
  const mintValidator = blueprint.validators.find(
    (v) => v.title === 'pump.pump.mint'
  );
  if (!mintValidator) {
    throw new Error('❌ Pump mint validator not found');
  }

  const mintScriptCbor = applyParamsToScript(mintValidator.compiledCode, [
    txHash,
    outputIndex,
  ]);

  // Get policy ID from script hash
  const policyId = resolveScriptHash(mintScriptCbor, 'V3');

  const script: PlutusScript = {
    code: scriptCbor,
    version: 'V3',
  };

  const { address: scriptAddress } = serializePlutusScript(script, undefined, 0);

  return { script, policyId, scriptAddress };
}

// ============================================================================
// MAIN SELL FUNCTION
// ============================================================================

async function sellTokens() {
  try {
    console.log('\n💰 === Selling Tokens to Pump Pool ===\n');

    // 1. Get wallet address
    const walletAddress = await wallet.getChangeAddress();
    console.log('📍 Seller Address:', walletAddress);
    console.log(`🎯 Amount to sell: ${AMOUNT_TO_SELL}\n`);

    // 2. Get pool script
    const { script, policyId } = getPumpScript({
      txHash: POOL_CONFIG.utxoTxHash,
      outputIndex: POOL_CONFIG.utxoOutputIndex,
    });

    // 3. Fetch pool UTXO from script address
    console.log('🔍 Fetching pool UTXO...');
    const poolUtxos = await blockchainProvider.fetchAddressUTxOs(
      POOL_CONFIG.scriptAddress
    );

    if (poolUtxos.length === 0) {
      throw new Error('❌ No pool UTXO found at script address');
    }

    // Lấy UTXO đầu tiên (should only be one)
    const poolUtxo = poolUtxos[0];
    console.log('✅ Pool UTXO found:', poolUtxo.input.txHash.substring(0, 16) + '...\n');

    // 4. Parse pool datum
    const datumCbor = poolUtxo.output.plutusData;
    if (!datumCbor) {
      throw new Error('❌ Pool UTXO has no inline datum');
    }

    const datumJson = deserializeDatum(datumCbor);
    const poolDatum = parsePoolDatum(datumJson);

    console.log('📊 Current Pool State:');
    console.log(`   Token: ${poolDatum.token_name}`);
    console.log(`   Current Supply (sold): ${poolDatum.current_supply}`);
    console.log(`   Slope: ${poolDatum.slope.toLocaleString()} lovelace\n`);

    // Validate có đủ supply để bán không
    if (poolDatum.current_supply < AMOUNT_TO_SELL) {
      throw new Error(`❌ Cannot sell ${AMOUNT_TO_SELL} tokens. Current supply is only ${poolDatum.current_supply}`);
    }

    // 5. Calculate refund
    const refund = calculateRefund(poolDatum.slope, poolDatum.current_supply, AMOUNT_TO_SELL);
    const newSupply = poolDatum.current_supply - AMOUNT_TO_SELL;
    const avgPrice = refund / AMOUNT_TO_SELL / 1_000_000;

    console.log('💹 Transaction Details:');
    console.log(`   New Supply: ${newSupply}`);
    console.log(`   Refund: ${refund.toLocaleString()} lovelace (${(refund / 1_000_000).toFixed(6)} ADA)`);
    console.log(`   Average Price: ${avgPrice.toFixed(6)} ADA per token\n`);

    // 5.5 Calculate slippage protection (5% tolerance)
    const slippageTolerance = 0.05; // 5%
    const minRefund = Math.floor(refund * (1 - slippageTolerance));
    
    console.log(`🛡️  Slippage Protection:`);
    console.log(`   Expected Refund: ${refund.toLocaleString()} lovelace`);
    console.log(`   Min Refund (5% slippage): ${minRefund.toLocaleString()} lovelace\n`);

    // 6. Calculate pool balances
    const assetId = policyId + Buffer.from(poolDatum.token_name).toString('hex');
    console.log('🔍 Debug - Asset ID:', assetId);
    console.log('🔍 Debug - Pool amounts:', JSON.stringify(poolUtxo.output.amount, null, 2));
    
    const currentAda = Number(
      poolUtxo.output.amount.find((a) => a.unit === 'lovelace')?.quantity || '0'
    );
    const currentTokens = Number(
      poolUtxo.output.amount.find((a) => a.unit === assetId)?.quantity || '0'
    );

    console.log('📦 Pool Balances:');
    console.log(`   ADA: ${currentAda.toLocaleString()} → ${(currentAda - refund).toLocaleString()}`);
    console.log(`   Tokens: ${currentTokens.toLocaleString()} → ${(currentTokens + AMOUNT_TO_SELL).toLocaleString()}\n`);

    // 7. Build new pool datum
    const newDatum = mConStr0([
      poolDatum.token_policy,
      Buffer.from(poolDatum.token_name, 'utf8').toString('hex'),
      poolDatum.slope,
      newSupply,
      poolDatum.creator,
    ]);

    // 8. Get collateral
    const utxos = await wallet.getUtxos();
    const collateralUtxo = utxos.find((u) => {
      const lovelace = u.output.amount.find((a: any) => a.unit === 'lovelace');
      const hasOnlyAda = u.output.amount.length === 1 && lovelace;
      const hasEnoughAda = lovelace && Number(lovelace.quantity) >= 5000000;
      return hasOnlyAda && hasEnoughAda;
    });

    if (!collateralUtxo) {
      throw new Error('❌ No suitable collateral found (need pure ADA UTXO with ≥5 ADA)');
    }

    // 9. Build transaction
    console.log('🔨 Building transaction...');

    const txBuilder = new MeshTxBuilder({
      fetcher: blockchainProvider,
      submitter: blockchainProvider,
    });

    // Sell redeemer với slippage protection
    const sellRedeemer = mConStr2([AMOUNT_TO_SELL, minRefund]);

    await txBuilder
      // Select UTxOs from wallet (to get tokens to sell)
      .selectUtxosFrom(utxos)
      // Spend pool UTXO
      .spendingPlutusScriptV3()
      .txIn(
        poolUtxo.input.txHash,
        poolUtxo.input.outputIndex,
        poolUtxo.output.amount,
        poolUtxo.output.address
      )
      .txInScript(script.code)
      .txInRedeemerValue(sellRedeemer)
      .txInInlineDatumPresent()
      // Add collateral
      .txInCollateral(
        collateralUtxo.input.txHash,
        collateralUtxo.input.outputIndex,
        collateralUtxo.output.amount,
        collateralUtxo.output.address
      )
      // Pool continuing output (less ADA, more tokens)
      .txOut(POOL_CONFIG.scriptAddress, [
        { unit: 'lovelace', quantity: (currentAda - refund).toString() },
        { unit: assetId, quantity: (currentTokens + AMOUNT_TO_SELL).toString() },
      ])
      .txOutInlineDatumValue(newDatum)
      // Seller receives ADA refund (handled by change)
      .changeAddress(walletAddress)
      .complete();

    console.log('✅ Transaction built');

    // 10. Sign transaction
    console.log('✍️  Signing transaction...');
    const signedTx = await wallet.signTx(txBuilder.txHex);

    // 11. Submit transaction
    console.log('📤 Submitting transaction...');
    const txHash = await wallet.submitTx(signedTx);

    // 12. Success!
    console.log('\n🎉 === Sale Successful! ===\n');
    console.log('📝 Transaction Hash:', txHash);
    console.log('🔗 View on Cardanoscan:');
    console.log(`   https://preprod.cardanoscan.io/transaction/${txHash}\n`);
    console.log(`💰 You sold: ${AMOUNT_TO_SELL} PUMP`);
    console.log(`💸 You received: ${(refund / 1_000_000).toFixed(6)} ADA\n`);
    console.log('📊 New Pool State:');
    console.log(`   Supply: ${poolDatum.current_supply} → ${newSupply}`);
    console.log(`   Current Price: ${(newSupply * poolDatum.slope / 1_000_000).toFixed(6)} ADA per token`);

  } catch (error) {
    console.error('\n❌ Error:', error);
    throw error;
  }
}

// ============================================================================
// EXECUTE
// ============================================================================

sellTokens()
  .then(() => process.exit(0))
  .catch(() => process.exit(1));
