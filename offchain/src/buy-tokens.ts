import {
  BlockfrostProvider,
  MeshWallet,
  MeshTxBuilder,
  PlutusScript,
  serializePlutusScript,
  applyParamsToScript,
  mConStr0,
  mConStr1,
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

// Số lượng token muốn mua
const AMOUNT_TO_BUY = 5; // Giảm từ 100 xuống 10

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Get Pump script with parameters
 */
function getPumpScript(utxoTxHash: string, utxoOutputIndex: number): PlutusScript {
  const validator = blueprint.validators.find(
    (v: any) => v.title === 'pump.pump.spend'
  );

  if (!validator) {
    throw new Error('pump.pump.spend validator not found');
  }

  const scriptCbor = applyParamsToScript(validator.compiledCode, [
    utxoTxHash,
    utxoOutputIndex,
  ]);

  return {
    code: scriptCbor,
    version: 'V3',
  };
}

/**
 * Calculate bonding curve cost
 * Cost = Slope × (supply_end² - supply_start²) / 2
 */
function calculateCost(slope: number, supplyStart: number, supplyEnd: number): number {
  const endSquared = supplyEnd * supplyEnd;
  const startSquared = supplyStart * supplyStart;
  return Math.floor((slope * (endSquared - startSquared)) / 2);
}

/**
 * Parse PoolDatum from chain
 */
function parsePoolDatum(datum: any) {
  const fields = datum.fields;
  return {
    token_policy: fields[0].bytes,
    token_name: Buffer.from(fields[1].bytes, 'hex').toString('utf8'),
    slope: fields[2].int,
    current_supply: fields[3].int,
    creator: fields[4].bytes,
  };
}

/**
 * Build new PoolDatum
 */
function buildPoolDatum(
  policyId: string,
  tokenName: string,
  slope: number,
  currentSupply: number,
  creator: string
) {
  return {
    constructor: 0,
    fields: [
      { bytes: policyId },
      { bytes: Buffer.from(tokenName, 'utf8').toString('hex') },
      { int: slope },
      { int: currentSupply },
      { bytes: creator },
    ],
  };
}

// ============================================================================
// MAIN FUNCTION
// ============================================================================

async function buyTokens() {
  try {
    console.log('\n💰 === Buying Tokens from Pump Pool ===\n');

    const walletAddress = await wallet.getChangeAddress();
    console.log('📍 Buyer Address:', walletAddress);
    console.log('🎯 Amount to buy:', AMOUNT_TO_BUY.toLocaleString());

    // 1. Get pool UTXO
    console.log('\n🔍 Fetching pool UTXO...');
    const scriptUtxos = await blockchainProvider.fetchAddressUTxOs(POOL_CONFIG.scriptAddress);
    
    if (scriptUtxos.length === 0) {
      throw new Error('❌ No pool UTXO found');
    }

    const poolUtxo = scriptUtxos[0];
    console.log('✅ Pool UTXO found:', poolUtxo.input.txHash.substring(0, 16) + '...');

    // 2. Parse pool datum
    const datumCbor = poolUtxo.output.plutusData as string;
    const datum = deserializeDatum(datumCbor);
    const poolDatum = parsePoolDatum(datum);
    console.log('\n📊 Current Pool State:');
    console.log(`   Token: ${poolDatum.token_name}`);
    console.log(`   Current Supply (sold): ${poolDatum.current_supply.toLocaleString()}`);
    console.log(`   Slope: ${poolDatum.slope.toLocaleString()} lovelace`);

    // 3. Calculate cost and new supply
    const newSupply = poolDatum.current_supply + AMOUNT_TO_BUY;
    const cost = calculateCost(poolDatum.slope, poolDatum.current_supply, newSupply);

    console.log('\n💹 Transaction Details:');
    console.log(`   New Supply: ${newSupply.toLocaleString()}`);
    console.log(`   Cost: ${cost.toLocaleString()} lovelace (${(cost / 1_000_000).toFixed(6)} ADA)`);
    console.log(`   Average Price: ${((cost / AMOUNT_TO_BUY) / 1_000_000).toFixed(6)} ADA per token`);

    // 4. Get current pool balances
    const assetName = Buffer.from(POOL_CONFIG.tokenName, 'utf8').toString('hex');
    const assetId = POOL_CONFIG.policyId + assetName;

    const currentAda = parseInt(
      poolUtxo.output.amount.find((a: any) => a.unit === 'lovelace')?.quantity || '0'
    );
    const currentTokens = parseInt(
      poolUtxo.output.amount.find((a: any) => a.unit === assetId)?.quantity || '0'
    );

    console.log('\n📦 Pool Balances:');
    console.log(`   ADA: ${currentAda.toLocaleString()} → ${(currentAda + cost).toLocaleString()}`);
    console.log(`   Tokens: ${currentTokens.toLocaleString()} → ${(currentTokens - AMOUNT_TO_BUY).toLocaleString()}`);

    // 5. Calculate slippage protection (5% tolerance)
    const slippageTolerance = 0.05; // 5%
    const maxCost = Math.floor(cost * (1 + slippageTolerance));
    
    console.log(`\n🛡️  Slippage Protection:`);
    console.log(`   Expected Cost: ${cost.toLocaleString()} lovelace`);
    console.log(`   Max Cost (5% slippage): ${maxCost.toLocaleString()} lovelace`);

    // 6. Build new datum
    const newDatum = mConStr0([
      poolDatum.token_policy,
      Buffer.from(poolDatum.token_name, 'utf8').toString('hex'),
      poolDatum.slope,
      newSupply,
      poolDatum.creator,
    ]);

    // 7. Get script
    const script = getPumpScript(POOL_CONFIG.utxoTxHash, POOL_CONFIG.utxoOutputIndex);

    // 8. Get wallet UTXOs and collateral
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
    console.log('\n🔨 Building transaction...');

    const txBuilder = new MeshTxBuilder({
      fetcher: blockchainProvider,
      submitter: blockchainProvider,
    });

    // Buy redeemer với slippage protection
    const buyRedeemer = mConStr1([AMOUNT_TO_BUY, maxCost]);

    await txBuilder
      // Spend pool UTXO
      .spendingPlutusScriptV3()
      .txIn(
        poolUtxo.input.txHash,
        poolUtxo.input.outputIndex,
        poolUtxo.output.amount,
        poolUtxo.output.address
      )
      .txInScript(script.code)
      .txInRedeemerValue(buyRedeemer)
      .txInInlineDatumPresent()
      // Add collateral
      .txInCollateral(
        collateralUtxo.input.txHash,
        collateralUtxo.input.outputIndex,
        collateralUtxo.output.amount,
        collateralUtxo.output.address
      )
      // Pool continuing output (more ADA, less tokens)
      .txOut(POOL_CONFIG.scriptAddress, [
        { unit: 'lovelace', quantity: (currentAda + cost).toString() },
        { unit: assetId, quantity: (currentTokens - AMOUNT_TO_BUY).toString() },
      ])
      .txOutInlineDatumValue(newDatum)
      // Buyer receives tokens
      .txOut(walletAddress, [
        { unit: assetId, quantity: AMOUNT_TO_BUY.toString() },
      ])
      .changeAddress(walletAddress)
      .selectUtxosFrom(utxos)
      .complete();

    console.log('✅ Transaction built');

    // 9. Sign and submit
    console.log('✍️  Signing transaction...');
    const signedTx = await wallet.signTx(txBuilder.txHex);

    console.log('📤 Submitting transaction...');
    const txHash = await wallet.submitTx(signedTx);

    console.log('\n🎉 === Purchase Successful! ===\n');
    console.log('📝 Transaction Hash:', txHash);
    console.log('🔗 View on Cardanoscan:');
    console.log(`   https://preprod.cardanoscan.io/transaction/${txHash}`);
    console.log(`\n💰 You received: ${AMOUNT_TO_BUY.toLocaleString()} ${POOL_CONFIG.tokenName}`);
    console.log(`💸 You paid: ${(cost / 1_000_000).toFixed(6)} ADA`);
    console.log(`\n📊 New Pool State:`);
    console.log(`   Supply: ${poolDatum.current_supply.toLocaleString()} → ${newSupply.toLocaleString()}`);
    console.log(`   Current Price: ${((poolDatum.slope * newSupply) / 1_000_000).toFixed(6)} ADA per token`);

  } catch (error) {
    console.error('\n❌ Error:', error);
    throw error;
  }
}

// ============================================================================
// RUN
// ============================================================================

buyTokens()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
