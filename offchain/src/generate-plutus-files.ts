import {
  applyParamsToScript,
  serializePlutusScript,
  PlutusScript,
  BlockfrostProvider,
} from '@meshsdk/core';
import * as fs from 'fs';
import * as path from 'path';
import blueprint from '../../plutus.json';

// ============================================================================
// CONFIG - Auto-load UTXO from file
// ============================================================================

async function generatePlutusFiles() {
  console.log('🔨 Generating Plutus script files for cardano-cli...\n');

  // Auto-load UTXO parameters from file
  const utxoParamsPath = path.join(__dirname, '../../utxo-params.json');
  
  if (!fs.existsSync(utxoParamsPath)) {
    throw new Error(`❌ UTXO params file not found: ${utxoParamsPath}\n\nPlease run mint script first to generate utxo-params.json`);
  }

  const utxoParams = JSON.parse(fs.readFileSync(utxoParamsPath, 'utf-8'));
  
  console.log('📌 Loaded UTXO parameters from file:');
  console.log(`   TxHash: ${utxoParams.utxoTxHash}`);
  console.log(`   Index: ${utxoParams.utxoOutputIndex}\n`);

  const outputDir = path.join(__dirname, '../../plutus-scripts');
  fs.mkdirSync(outputDir, { recursive: true });

  // 1. SPEND VALIDATOR (Script Address)
  console.log('📝 Processing spend validator...');
  const spendValidator = blueprint.validators.find(
    (v) => v.title === 'pump.pump.spend'
  );

  if (!spendValidator) {
    throw new Error('❌ Spend validator not found');
  }

  const spendScriptCbor = applyParamsToScript(
    spendValidator.compiledCode,
    [utxoParams.utxoTxHash, utxoParams.utxoOutputIndex]
  );

  const spendPlutusFile = {
    type: 'PlutusScriptV3',
    description: 'Pump Spend Validator',
    cborHex: spendScriptCbor,
  };

  const spendFilePath = path.join(outputDir, 'pump-spend.plutus');
  fs.writeFileSync(spendFilePath, JSON.stringify(spendPlutusFile, null, 2));
  console.log('✅ Spend script:', spendFilePath);

  // 2. MINT VALIDATOR (Policy Script)
  console.log('📝 Processing mint validator...');
  const mintValidator = blueprint.validators.find(
    (v) => v.title === 'pump.pump.mint'
  );

  if (!mintValidator) {
    throw new Error('❌ Mint validator not found');
  }

  const mintScriptCbor = applyParamsToScript(
    mintValidator.compiledCode,
    [utxoParams.utxoTxHash, utxoParams.utxoOutputIndex]
  );

  const mintPlutusFile = {
    type: 'PlutusScriptV3',
    description: 'Pump Minting Policy',
    cborHex: mintScriptCbor,
  };

  const mintFilePath = path.join(outputDir, 'pump-mint.plutus');
  fs.writeFileSync(mintFilePath, JSON.stringify(mintPlutusFile, null, 2));
  console.log('✅ Mint script:', mintFilePath);

  // 3. Generate script address using MeshSDK
  console.log('\n🏠 Generating script address...');
  const script: PlutusScript = {
    code: spendScriptCbor,
    version: 'V3',
  };

  const { address: scriptAddress } = serializePlutusScript(
    script,
    undefined,
    0 // networkId 0 = preprod testnet
  );

  const addressFilePath = path.join(outputDir, 'pump-script.addr');
  fs.writeFileSync(addressFilePath, scriptAddress);
  console.log('✅ Script address:', addressFilePath);

  // 4. Create shell script for cardano-cli usage
  console.log('\n📜 Creating cardano-cli example script...');
  
  const shellScript = `#!/bin/bash

# ============================================================================
# Cardano CLI Script Address Generation
# ============================================================================

CARDANO_TESTNET_MAGIC=1  # 1 = Preprod, 2 = Preview

# Generate mint policy ID
echo "🏦 Generating mint policy ID..."
cardano-cli transaction policyid \\
  --script-file pump-mint.plutus

# Generate spend script address  
echo ""
echo "🏠 Generating spend script address..."
cardano-cli address build \\
  --payment-script-file pump-spend.plutus \\
  --testnet-magic $CARDANO_TESTNET_MAGIC \\
  --out-file pump-script-cli.addr

echo ""
echo "✅ Generated addresses:"
echo "   MeshSDK address: $(cat pump-script.addr)"
echo "   CLI address:     $(cat pump-script-cli.addr)"
echo ""
echo "📝 These should match your pool address!"
`;

  const shellScriptPath = path.join(outputDir, 'generate-address.sh');
  fs.writeFileSync(shellScriptPath, shellScript);
  fs.chmodSync(shellScriptPath, '755');
  console.log('✅ Shell script:', shellScriptPath);

  // Summary
  console.log('\n🎉 Done! Files generated:\n');
  console.log('📁 Directory:', outputDir);
  console.log('   📄 pump-spend.plutus    - Spend validator script');
  console.log('   📄 pump-mint.plutus     - Minting policy script');
  console.log('   📄 pump-script.addr     - Script address (MeshSDK)');
  console.log('   📄 generate-address.sh  - Cardano CLI example\n');
  console.log('📍 Script Address (from MeshSDK):', scriptAddress);
  console.log('\n💡 Usage with cardano-cli:');
  console.log('   cd plutus-scripts');
  console.log('   ./generate-address.sh');
  console.log('\n✅ This address should match your pool!');
}

// ============================================================================
// EXECUTE
// ============================================================================

generatePlutusFiles()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('❌ Error:', error);
    process.exit(1);
  });
