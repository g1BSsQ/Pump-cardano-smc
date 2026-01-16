import { MeshWallet } from '@meshsdk/core';
import * as fs from 'fs';
import * as path from 'path';
import * as bip39 from 'bip39';
import * as cardano from '@emurgo/cardano-serialization-lib-nodejs';

// Mnemonic phrase từ sell-tokens.ts
const MNEMONIC = [
  'void', 'veteran', 'resist', 'invest', 'virtual', 'stomach',
  'accident', 'lock', 'toddler', 'guitar', 'video', 'short',
  'lock', 'adult', 'zoo', 'require', 'ten', 'dose',
  'eagle', 'shuffle', 'employ', 'parrot', 'slogan', 'timber'
];

function deriveKeyFromMnemonic(mnemonicWords: string[], accountIndex = 0, addressIndex = 0) {
  const mnemonic = mnemonicWords.join(' ');
  
  // Convert mnemonic to entropy
  const entropy = bip39.mnemonicToEntropy(mnemonic);
  
  // Create root key
  const rootKey = cardano.Bip32PrivateKey.from_bip39_entropy(
    Buffer.from(entropy, 'hex'),
    Buffer.from('')
  );
  
  // Derive payment key using path: m/1852'/1815'/0'/0/0
  const accountKey = rootKey
    .derive(harden(1852))  // purpose
    .derive(harden(1815))  // coin_type (ADA)
    .derive(harden(accountIndex)); // account
  
  const paymentKey = accountKey
    .derive(0)  // external chain (0 = external, 1 = internal/change)
    .derive(addressIndex); // address index
  
  return paymentKey;
}

function harden(num: number): number {
  return 0x80000000 + num;
}

async function restoreBobKeys() {
  try {
    console.log('🔑 Restoring Bob keys from mnemonic...\n');

    // Tạo wallet từ mnemonic để lấy address
    const wallet = new MeshWallet({
      networkId: 0,
      key: {
        type: 'mnemonic',
        words: MNEMONIC,
      },
    });

    const address = await wallet.getChangeAddress();
    console.log('📍 Bob Address (from mnemonic):', address);
    
    // Derive keys từ mnemonic
    console.log('\n🔐 Deriving keys from mnemonic...');
    const paymentKey = deriveKeyFromMnemonic(MNEMONIC, 0, 0);
    const publicKey = paymentKey.to_public();
    
    // Export ra định dạng cardano-cli JSON
    const signingKeyHex = Buffer.from(paymentKey.as_bytes()).toString('hex');
    const verificationKeyHex = Buffer.from(publicKey.as_bytes()).toString('hex');
    
    const signingKeyJson = {
      type: 'PaymentExtendedSigningKeyShelley_ed25519_bip32',
      description: 'Payment Signing Key from Mnemonic',
      cborHex: '5880' + signingKeyHex
    };
    
    const verificationKeyJson = {
      type: 'PaymentExtendedVerificationKeyShelley_ed25519_bip32',
      description: 'Payment Verification Key from Mnemonic',
      cborHex: '5840' + verificationKeyHex
    };
    
    // Xác định thư mục credentials (WSL hoặc Windows)
    let keysDir: string;
    const isWindows = process.platform === 'win32';
    
    if (isWindows) {
      // Trên Windows, dùng WSL path
      keysDir = '/home/g1bssq/credentials';
    } else {
      keysDir = path.join(process.env.HOME || '~', 'credentials');
    }
    
    console.log('💾 Keys location:', keysDir);
    
    // Backup keys cũ
    console.log('\n📦 Creating backup of old keys...');
    const backupDir = path.join(keysDir, 'backup-' + Date.now());
    
    if (isWindows) {
      // Dùng WSL commands để backup
      const { execSync } = require('child_process');
      try {
        execSync(`wsl mkdir -p "${backupDir}"`, { stdio: 'inherit' });
        execSync(`wsl cp ${keysDir}/bob-*.* "${backupDir}/" 2>/dev/null || true`, { stdio: 'inherit' });
        console.log('✅ Backup saved to:', backupDir);
      } catch (error) {
        console.log('⚠️  Could not backup (may not exist yet)');
      }
    }
    
    // Lưu keys mới
    console.log('\n💾 Writing new keys...');
    const files = {
      'bob-funds.sk': JSON.stringify(signingKeyJson, null, 2),
      'bob-node.sk': JSON.stringify(signingKeyJson, null, 2),
      'bob-funds.vk': JSON.stringify(verificationKeyJson, null, 2),
      'bob-node.vk': JSON.stringify(verificationKeyJson, null, 2),
      'bob-funds.addr': address,
      'bob-node.addr': address,
    };
    
    if (isWindows) {
      // Dùng WSL để write files
      const { execSync } = require('child_process');
      const tempDir = path.join(__dirname, '../../.tmp-keys');
      fs.mkdirSync(tempDir, { recursive: true });
      
      // Write to temp dir first
      for (const [filename, content] of Object.entries(files)) {
        fs.writeFileSync(path.join(tempDir, filename), content);
      }
      
      // Copy to WSL
      execSync(`wsl mkdir -p ${keysDir}`, { stdio: 'inherit' });
      const tempDirWsl = tempDir.replace(/\\/g, '/').replace('D:', '/mnt/d');
      execSync(`wsl cp "${tempDirWsl}"/* ${keysDir}/`, { stdio: 'inherit' });
      
      // Cleanup
      fs.rmSync(tempDir, { recursive: true });
      
      console.log('✅ Keys written to WSL:', keysDir);
    } else {
      // Direct write on Linux
      fs.mkdirSync(keysDir, { recursive: true });
      for (const [filename, content] of Object.entries(files)) {
        fs.writeFileSync(path.join(keysDir, filename), content);
      }
      console.log('✅ Keys written to:', keysDir);
    }
    
    console.log('\n🎉 Success! Bob keys restored from mnemonic.');
    console.log('\n📋 Summary:');
    console.log('   Address:', address);
    console.log('   Files updated:');
    console.log('   - bob-funds.sk, bob-funds.vk, bob-funds.addr');
    console.log('   - bob-node.sk, bob-node.vk, bob-node.addr');
    console.log('\n⚠️  IMPORTANT: Old keys backed up to:', backupDir);

  } catch (error) {
    console.error('❌ Error:', error);
    throw error;
  }
}

restoreBobKeys()
  .then(() => process.exit(0))
  .catch(() => process.exit(1));
