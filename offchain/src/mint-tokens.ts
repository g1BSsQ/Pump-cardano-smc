import {
  BlockfrostProvider,
  MeshWallet,
  MeshTxBuilder,
  PlutusScript,
  serializePlutusScript,
  applyParamsToScript,
  mConStr0,
  resolveScriptHash,
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
  networkId: 0, // 0 = Testnet (Preview/Preprod)
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
// HELPER FUNCTIONS
// ============================================================================

/**
 * Get Pump validator script with UTXO parameters
 */
function getPumpScript(utxoRef: { txHash: string; outputIndex: number }) {
  const validator = blueprint.validators.find(
    (v: any) => v.title === 'pump.pump.mint'
  );
  
  if (!validator) {
    throw new Error('pump.pump.mint validator not found in plutus.json');
  }

  console.log('🔧 Applying parameters:', {
    txHash: utxoRef.txHash,
    outputIndex: utxoRef.outputIndex,
  });

  // Apply parameters: required_tx_hash (ByteArray) and required_output_index (Int)
  const params = [
    utxoRef.txHash,
    utxoRef.outputIndex
  ];

  const scriptCbor = applyParamsToScript(validator.compiledCode, params);
  
  // Get policy ID from script hash (for minting)
  const policyId = resolveScriptHash(scriptCbor, 'V3');
  
  // Get script address (for pool)
  const script: PlutusScript = {
    code: scriptCbor,
    version: "V3",
  };
  const { address: scriptAddress } = serializePlutusScript(script, undefined, 0);

  return { scriptCbor, policyId, scriptAddress };
}

// ============================================================================
// MAIN MINT FUNCTION
// ============================================================================

async function createPumpPool() {
  try {
    console.log('\n🚀 Creating Pump.fun Pool with Bonding Curve...\n');

    // 1. Get wallet address and UTxOs
    const walletAddress = await wallet.getChangeAddress();
    console.log('📍 Wallet Address:', walletAddress);

    const utxos = await wallet.getUtxos();
    if (utxos.length === 0) {
      throw new Error('❌ No UTxOs available. Please fund your wallet first.');
    }

    // 2. Select UTxO to consume (this makes it one-shot)
    const referenceUtxo = utxos[0];
    console.log('🔐 Consuming UTxO:', {
      txHash: referenceUtxo.input.txHash,
      outputIndex: referenceUtxo.input.outputIndex,
      lovelace: referenceUtxo.output.amount.find(a => a.unit === 'lovelace')?.quantity
    });

    // 3. Get Pump script with UTXO parameters
    const { scriptCbor, policyId, scriptAddress } = getPumpScript({
      txHash: referenceUtxo.input.txHash,
      outputIndex: referenceUtxo.input.outputIndex,
    });

    console.log('🔑 Policy ID:', policyId);
    console.log('🏊 Pool Address (Script):', scriptAddress);

    // 4. Define token to mint
    const tokenName = 'PUMP';
    const tokenQuantity = '1000000'; // 1M tokens
    const assetName = Buffer.from(tokenName).toString('hex');

    console.log(`🪙 Minting ${parseInt(tokenQuantity).toLocaleString()}x ${tokenName}...`);
    
    // Get wallet owner pubkey hash
    const ownerPubKeyHash = deserializeAddress(walletAddress).pubKeyHash;
    
    // Create Pool Datum
    // PoolDatum { token_policy, token_name, slope, current_supply, creator }
    const slope = 1_000_000; // 1 ADA per unit supply
    const initialSupply = 0; // Pool starts with 0 supply (nothing sold yet)
    
    const poolDatum = mConStr0([
      policyId,           // token_policy (PolicyId)
      assetName,          // token_name (ByteArray hex)
      slope,              // slope (Int)
      initialSupply,      // current_supply (Int) - starts at 0
      ownerPubKeyHash,    // creator (ByteArray)
    ]);
    
    console.log('📊 Pool Configuration:');
    console.log(`   Total Supply: ${parseInt(tokenQuantity).toLocaleString()}`);
    console.log(`   Initial Circulating: 0 (all locked in pool)`);
    console.log(`   Slope: ${slope.toLocaleString()} lovelace`);
    console.log(`   Formula: Price = ${(slope / 1_000_000)} ADA × Supply`);

    // 5. Build transaction
    console.log('\n🔨 Building transaction...');

    const txBuilder = new MeshTxBuilder({
      fetcher: blockchainProvider,
      submitter: blockchainProvider,
    });

    // Mint redeemer: MintInitial (constructor 0, no fields)
    const mintRedeemer = mConStr0([]);

    // Select a collateral UTxO (must be pure ADA, no tokens)
    const collateralUtxo = utxos.find(
      (u) => {
        const lovelace = u.output.amount.find((a: any) => a.unit === 'lovelace');
        const hasOnlyAda = u.output.amount.length === 1 && lovelace;
        const hasEnoughAda = lovelace && Number(lovelace.quantity) >= 5000000;
        return hasOnlyAda && hasEnoughAda;
      }
    );
    
    if (!collateralUtxo) {
      throw new Error('No suitable collateral UTxO found (need pure ADA UTxO with at least 5 ADA)');
    }

    console.log('💰 Using collateral:', {
      txHash: collateralUtxo.input.txHash.substring(0, 16) + '...',
      lovelace: collateralUtxo.output.amount.find((a: any) => a.unit === 'lovelace')?.quantity
    });

    // Build transaction
    await txBuilder
      // Select UTxOs from wallet
      .selectUtxosFrom(utxos)
      // Consume the required UTxO (this enables one-shot minting)
      .txIn(
        referenceUtxo.input.txHash,
        referenceUtxo.input.outputIndex,
        referenceUtxo.output.amount,
        referenceUtxo.output.address
      )
      // Mint the token
      .mintPlutusScriptV3()
      .mint(tokenQuantity, policyId, assetName)
      .mintingScript(scriptCbor)
      .mintRedeemerValue(mintRedeemer)
      // Add collateral
      .txInCollateral(
        collateralUtxo.input.txHash,
        collateralUtxo.input.outputIndex,
        collateralUtxo.output.amount,
        collateralUtxo.output.address
      )
      // Send all minted tokens to pool with 5 ADA minimum
      .txOut(scriptAddress, [
        { unit: 'lovelace', quantity: '5000000' },  // 5 ADA minimum
        { unit: policyId + assetName, quantity: tokenQuantity }  // All minted tokens
      ])
      .txOutInlineDatumValue(poolDatum)
      .changeAddress(walletAddress)
      .complete();
      
    console.log('✅ Transaction built successfully');

    // 6. Sign transaction
    console.log('✍️  Signing transaction...');
    const signedTx = await wallet.signTx(txBuilder.txHex);

    // 7. Submit transaction
    console.log('📤 Submitting transaction...');
    const txHash = await wallet.submitTx(signedTx);

    console.log('\n✅ SUCCESS!');
    console.log('📝 Transaction Hash:', txHash);
    console.log('🔗 View on Cardanoscan:');
    console.log(`   https://preprod.cardanoscan.io/transaction/${txHash}`);
    console.log('\n🎉 Pump Pool Created!');
    console.log(`   Policy ID: ${policyId}`);
    console.log(`   Token Name: ${tokenName}`);
    console.log(`   Total Supply: ${parseInt(tokenQuantity).toLocaleString()}`);
    console.log(`   Asset ID: ${policyId}${assetName}`);
    console.log(`\n🏊 Pool Address (Buy/Sell here):`);
    console.log(`   ${scriptAddress}`);
    console.log(`\n💹 Bonding Curve Formula: Price = ${slope / 1_000_000} ADA × Supply`);
    console.log(`   Token #100 price: ${(slope * 100 / 1_000_000).toFixed(2)} ADA`);
    console.log(`   Token #1000 price: ${(slope * 1000 / 1_000_000).toFixed(2)} ADA`);
    console.log(`   Token #10000 price: ${(slope * 10000 / 1_000_000).toFixed(2)} ADA`);

  } catch (error) {
    console.error('\n❌ Error:', error);
    throw error;
  }
}

// ============================================================================
// RUN
// ============================================================================

createPumpPool()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
