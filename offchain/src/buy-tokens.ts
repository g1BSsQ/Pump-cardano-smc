import {
  BlockfrostProvider,
  MeshWallet,
  MeshTxBuilder,
  PlutusScript,
  applyParamsToScript,
  mConStr0,
  mConStr1,
  deserializeDatum,
  deserializeAddress,
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
// AMM CONSTANTS (Must match smart contract)
// ============================================================================

const MAX_SUPPLY = 1_000_000_000; // 1B tokens
const VIRTUAL_ADA = 30_000_000_000; // 30B lovelace
const VIRTUAL_TOKEN = 300_000_000; // 300M tokens
const PLATFORM_FEE_BASIS_POINTS = 100; // 1%
const PLATFORM_ADDRESS = 'addr_test1vpvzw8hw8c30svltxx37pfzrq0gpws28w9z3zsqtqqskxscahns3q';

// ============================================================================
// POOL CONFIG - CẬP NHẬT THÔNG TIN POOL CỦA BẠN
// ============================================================================

const POOL_CONFIG = {
  policyId: '6351797c3ac7d53ddb1fffc70bb2598e7eea9e69336cf5a5e6a12cd5',
  tokenName: 'PUMP',
  scriptAddress: 'addr_test1wp34z7tu8tra20wmrlluwzajtx88a657dyekead9u6sje4gt2e58c',
  // UTXO được dùng khi tạo pool (one-shot parameters)
  utxoTxHash: 'f82e55143acc1a7d68cf634562fe56c1a231d10ba7b13003a7747ad28f10895d',
  utxoOutputIndex: 0,
};

// Số lượng token muốn mua
const AMOUNT_TO_BUY = 1000000; // 1M tokens

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
 * Calculate expected ADA reserve using AMM formula
 * Formula: expected_ada = (k / (max_supply - current_supply + virtual_token)) - virtual_ada
 * Where k = virtual_ada * (max_supply + virtual_token)
 */
function getExpectedAdaReserve(currentSupply: number): number {
  const k = VIRTUAL_ADA * (MAX_SUPPLY + VIRTUAL_TOKEN);
  const realTokenReserve = MAX_SUPPLY - currentSupply;
  const totalTokenReserve = realTokenReserve + VIRTUAL_TOKEN;
  
  if (totalTokenReserve <= 0) {
    return 999_999_999_999_999;
  }
  
  const totalAdaReserve = Math.floor(k / totalTokenReserve);
  const realAdaReserve = totalAdaReserve - VIRTUAL_ADA;
  
  return realAdaReserve < 0 ? 0 : realAdaReserve;
}

/**
 * Calculate buy cost
 * cost = expected_ada(new_supply) - expected_ada(current_supply)
 */
function calculateBuyCost(currentSupply: number, amount: number): {
  exactCost: number;
  fee: number;
  totalCost: number;
} {
  const newSupply = currentSupply + amount;
  const currentAdaReserve = getExpectedAdaReserve(currentSupply);
  const newAdaReserve = getExpectedAdaReserve(newSupply);
  const exactCost = newAdaReserve - currentAdaReserve;
  const fee = Math.floor((exactCost * PLATFORM_FEE_BASIS_POINTS) / 10000);
  const totalCost = exactCost + fee;
  
  return { exactCost, fee, totalCost };
}

/**
 * Parse PoolDatum from chain (NEW FORMAT)
 * PoolDatum { token_policy, token_name, current_supply, creator }
 */
function parsePoolDatum(datum: any) {
  const fields = datum.fields;
  return {
    token_policy: fields[0].bytes,
    token_name: Buffer.from(fields[1].bytes, 'hex').toString('utf8'),
    current_supply: Number(fields[2].int),
    creator: fields[3].bytes,
  };
}

// ============================================================================
// MAIN FUNCTION
// ============================================================================

async function buyTokens() {
  try {
    console.log('\n💰 === Buying Tokens from Pump Pool (AMM) ===\n');

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
    console.log(`   Current Supply (sold): ${poolDatum.current_supply.toLocaleString()} / ${MAX_SUPPLY.toLocaleString()}`);
    console.log(`   Remaining: ${(MAX_SUPPLY - poolDatum.current_supply).toLocaleString()}`);

    // 3. Calculate cost using AMM
    const newSupply = poolDatum.current_supply + AMOUNT_TO_BUY;
    
    if (newSupply > MAX_SUPPLY) {
      throw new Error(`❌ Cannot buy ${AMOUNT_TO_BUY.toLocaleString()} tokens. Only ${(MAX_SUPPLY - poolDatum.current_supply).toLocaleString()} remaining!`);
    }
    
    const { exactCost, fee, totalCost } = calculateBuyCost(poolDatum.current_supply, AMOUNT_TO_BUY);

    console.log('\n💹 AMM Calculation:');
    console.log(`   New Supply: ${newSupply.toLocaleString()}`);
    console.log(`   Exact Cost: ${exactCost.toLocaleString()} lovelace (${(exactCost / 1_000_000).toFixed(6)} ADA)`);
    console.log(`   Platform Fee (1%): ${fee.toLocaleString()} lovelace (${(fee / 1_000_000).toFixed(6)} ADA)`);
    console.log(`   Total Cost: ${totalCost.toLocaleString()} lovelace (${(totalCost / 1_000_000).toFixed(6)} ADA)`);
    console.log(`   Average Price: ${((totalCost / AMOUNT_TO_BUY) / 1_000_000).toFixed(9)} ADA per token`);

    // 4. Get current pool balances
    const assetName = Buffer.from(POOL_CONFIG.tokenName, 'utf8').toString('hex');
    const assetId = POOL_CONFIG.policyId + assetName;

    const currentAda = parseInt(
      poolUtxo.output.amount.find((a: any) => a.unit === 'lovelace')?.quantity || '0'
    );
    const currentTokens = parseInt(
      poolUtxo.output.amount.find((a: any) => a.unit === assetId)?.quantity || '0'
    );

    console.log('\n📦 Pool Balance Changes:');
    console.log(`   ADA: ${currentAda.toLocaleString()} → ${(currentAda + exactCost).toLocaleString()}`);
    console.log(`   Tokens: ${currentTokens.toLocaleString()} → ${(currentTokens - AMOUNT_TO_BUY).toLocaleString()}`);

    // 5. Calculate slippage protection (2% tolerance)
    const slippageTolerance = 0.02; // 2%
    const maxCostLimit = Math.floor(totalCost * (1 + slippageTolerance));
    
    console.log(`\n🛡️  Slippage Protection:`);
    console.log(`   Expected Total: ${totalCost.toLocaleString()} lovelace`);
    console.log(`   Max Cost Limit (2% slippage): ${maxCostLimit.toLocaleString()} lovelace`);

    // 6. Build new datum (NEW FORMAT - no slope)
    const newDatum = mConStr0([
      poolDatum.token_policy,
      Buffer.from(poolDatum.token_name, 'utf8').toString('hex'),
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

    // Buy redeemer: Buy { amount: Int, max_cost_limit: Int }
    const buyRedeemer = mConStr1([AMOUNT_TO_BUY, maxCostLimit]);

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
      // Pool continuing output (more ADA, fewer tokens)
      .txOut(POOL_CONFIG.scriptAddress, [
        { unit: 'lovelace', quantity: (currentAda + exactCost).toString() },
        { unit: assetId, quantity: (currentTokens - AMOUNT_TO_BUY).toString() },
      ])
      .txOutInlineDatumValue(newDatum)
      // Platform fee output
      .txOut(PLATFORM_ADDRESS, [
        { unit: 'lovelace', quantity: fee.toString() },
      ])
      // Buyer receives tokens
      .txOut(walletAddress, [
        { unit: assetId, quantity: AMOUNT_TO_BUY.toString() },
      ])
      .changeAddress(walletAddress)
      .selectUtxosFrom(utxos)
      .complete();

    console.log('✅ Transaction built');

    // 10. Sign and submit
    console.log('✍️  Signing transaction...');
    const signedTx = await wallet.signTx(txBuilder.txHex);

    console.log('📤 Submitting transaction...');
    const txHash = await wallet.submitTx(signedTx);

    console.log('\n🎉 === Purchase Successful! ===\n');
    console.log('📝 Transaction Hash:', txHash);
    console.log('🔗 View on Cardanoscan:');
    console.log(`   https://preprod.cardanoscan.io/transaction/${txHash}`);
    console.log(`\n💰 You received: ${AMOUNT_TO_BUY.toLocaleString()} ${POOL_CONFIG.tokenName}`);
    console.log(`💸 You paid: ${(totalCost / 1_000_000).toFixed(6)} ADA (including ${(fee / 1_000_000).toFixed(6)} ADA fee)`);
    console.log(`\n📊 New Pool State:`);
    console.log(`   Supply: ${poolDatum.current_supply.toLocaleString()} → ${newSupply.toLocaleString()}`);
    
    // Calculate new price
    const nextCost = calculateBuyCost(newSupply, 1);
    console.log(`   Current Price: ${(nextCost.totalCost / 1_000_000).toFixed(9)} ADA per token`);

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
