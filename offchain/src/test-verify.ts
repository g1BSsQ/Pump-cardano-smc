import { applyParamsToScript, resolveScriptHash, BlockfrostProvider } from '@meshsdk/core';
import blueprint from '../../plutus.json'; // Đường dẫn đến plutus.json từ root project

// Khởi tạo Blockfrost provider
const blockchainProvider = new BlockfrostProvider(
  process.env.BLOCKFROST_API_KEY || 'preprodx5cQKfPVxM066Svrll0DLWjl1Zh4IBeE' // Thay bằng API key thật
);

/**
 * Hàm check token có được mint từ script của chúng ta không
 * Sử dụng cả tính toán từ script code và query Blockfrost
 */
async function checkMintedToken(
  referenceUtxo: { txHash: string; outputIndex: number },
  assetId: string
): Promise<{ isValid: boolean; reason: string }> {
  try {
    console.log('🔍 Bắt đầu verify token...');

    // 1. Lấy ScriptCode từ plutus.json
    const validator = blueprint.validators.find(
      (v: any) => v.title === 'pump.pump.mint'
    );
    if (!validator) {
      return { isValid: false, reason: 'Validator không tìm thấy trong plutus.json' };
    }
    const scriptCode = validator.compiledCode;
    console.log('✅ Đã load ScriptCode từ plutus.json');

    // 2. Áp dụng params (từ user input)
    const params = [referenceUtxo.txHash, referenceUtxo.outputIndex];
    console.log('🔧 Áp dụng params:', params);
    const scriptCbor = applyParamsToScript(scriptCode, params);

    // 3. Tính Policy ID từ script
    const calculatedPolicyId = resolveScriptHash(scriptCbor, 'V3');
    console.log('🧮 Policy ID tính được:', calculatedPolicyId);

    // 4. Lấy Policy ID từ Asset ID (56 ký tự đầu)
    const assetPolicyId = assetId.slice(0, 56);
    console.log('📋 Policy ID từ Asset ID:', assetPolicyId);

    // 5. Check khớp
    if (calculatedPolicyId !== assetPolicyId) {
      return { isValid: false, reason: 'Policy ID không khớp' };
    }
    console.log('✅ Policy ID khớp!');

    // 6. Query Blockfrost để confirm asset tồn tại
    console.log('🌐 Query Blockfrost để check asset...');
    try {
      // Sử dụng fetch trực tiếp vì MeshSDK có thể không có fetchAssetInfo
      const apiKey = process.env.BLOCKFROST_API_KEY || 'preprodx5cQKfPVxM066Svrll0DLWjl1Zh4IBeE';
      const response = await fetch(`https://cardano-preprod.blockfrost.io/api/v0/assets/${assetId}`, {
        headers: { 'project_id': apiKey }
      });
      if (!response.ok) {
        throw new Error(`Blockfrost API error: ${response.status}`);
      }
      const assetInfo = await response.json() as { quantity: string };
      console.log('📊 Asset info từ Blockfrost:', assetInfo);

      if (!assetInfo || assetInfo.quantity === '0') {
        return { isValid: false, reason: 'Asset không tồn tại hoặc quantity = 0' };
      }

      console.log('✅ Asset tồn tại và có quantity > 0');
    } catch (queryError) {
      console.error('❌ Lỗi query Blockfrost:', queryError);
      return { isValid: false, reason: 'Không thể query asset từ blockchain' };
    }

    console.log('🎉 Verify thành công!');
    return { isValid: true, reason: 'Token hợp lệ' };
  } catch (error) {
    console.error('❌ Lỗi trong quá trình verify:', error);
    return { isValid: false, reason: `Lỗi: ${(error as Error).message}` };
  }
}

// ============================================================================
// TEST HÀM
// ============================================================================

async function testCheck() {
  // Giả sử data từ user (thay bằng data thật)
  const testReferenceUtxo = {
    txHash: 'c40cd55cec6ebd6fbc8575d51dc0a0f92c19f426b4cef60da85cb8b4bbb35fe7', // Thay bằng txHash thật
    outputIndex: 1
  };
  const testAssetId = '8d557aa6f5625f23caed3c8e3145839ee9b67d5cec77bd7bcb96a743' + Buffer.from('PUMP').toString('hex'); // Thay bằng assetId thật

  const result = await checkMintedToken(testReferenceUtxo, testAssetId);
  console.log('Kết quả check:', result);
}

// Chạy test
testCheck();