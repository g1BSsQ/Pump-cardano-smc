import { serializePlutusScript, PlutusScript, resolveScriptHash } from '@meshsdk/core';
import * as fs from 'fs';
import * as path from 'path';

// Read the plutus files
const spendPlutusPath = path.join(__dirname, '../../plutus-scripts/pump-spend.plutus');
const mintPlutusPath = path.join(__dirname, '../../plutus-scripts/pump-mint.plutus');

const spendPlutus = JSON.parse(fs.readFileSync(spendPlutusPath, 'utf-8'));
const mintPlutus = JSON.parse(fs.readFileSync(mintPlutusPath, 'utf-8'));

// Create script objects
const spendScript: PlutusScript = {
  code: spendPlutus.cborHex,
  version: 'V3',
};

const mintScript: PlutusScript = {
  code: mintPlutus.cborHex,
  version: 'V3',
};

// Calculate hashes
const spendHash = resolveScriptHash(spendPlutus.cborHex, 'V3');
const mintHash = resolveScriptHash(mintPlutus.cborHex, 'V3');

console.log('🔍 Script Hashes:\n');
console.log('📝 Spend Script Hash:', spendHash);
console.log('🪙 Mint Script Hash:', mintHash);
console.log('\n💡 The spend hash should match the expected one!');
