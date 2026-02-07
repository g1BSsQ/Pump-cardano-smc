// ============================================================================
// PUMP.FUN CONFIGURATION
// ============================================================================
// Tất cả các biến cấu hình tập trung ở đây để dễ quản lý và deploy

// ----------------------------------------------------------------------------
// ADMIN & PLATFORM CONFIG
// ----------------------------------------------------------------------------

// Thay bằng PubKeyHash ví Admin của bạn (Người chịu trách nhiệm bấm nút List Sàn)
// Format: 28 bytes hex (56 ký tự)
pub const admin_pkh: ByteArray =
  #"00000000000000000000000000000000000000000000000000000000"

// Platform fee address (Địa chỉ nhận phí giao dịch)
// Format: 28 bytes hex (56 ký tự)
// Lưu ý: Đây là PKH, không phải address đầy đủ
pub const platform_pkh: ByteArray =
  #"00000000000000000000000000000000000000000000000000000000"

// ----------------------------------------------------------------------------
// TOKENOMICS CONFIG
// ----------------------------------------------------------------------------

// Tổng cung token (1 tỷ token)
pub const max_supply: Int = 1_000_000_000

// Min ADA phải giữ trong pool (2 ADA = 2,000,000 lovelace)
pub const min_ada_in_pool: Int = 2_000_000

// Phí giao dịch (basis points)
// 100 = 1%, 50 = 0.5%, 10 = 0.1%
pub const default_fee_basis_points: Int = 100

// 1%

// Divisor cho basis points (không thay đổi)
pub const basis_points_divisor: Int = 10000

// ----------------------------------------------------------------------------
// AMM CURVE CONFIG (BONDING CURVE PARAMETERS)
// ----------------------------------------------------------------------------

// Virtual ADA Reserve (30,000 ADA = 30,000,000,000 lovelace)
// Càng cao thì giá khởi điểm càng cao, MarketCap ban đầu càng lớn
// Recommend: 20,000 - 50,000 ADA
pub const virtual_ada: Int = 30_000_000_000

// Virtual Token Reserve (300 triệu token)
// Thường là 20-30% tổng cung để đường cong mượt
// Recommend: 200,000,000 - 500,000,000
pub const virtual_token: Int = 300_000_000

// ----------------------------------------------------------------------------
// DEX MIGRATION CONFIG (Optional - Nếu có hardcode DEX address)
// ----------------------------------------------------------------------------

// Minswap Router Address (Script Hash)
// Uncomment và cập nhật nếu muốn enforce DEX address trong Migrate
// pub const minswap_router_script: ByteArray =
//   #"0000000000000000000000000000000000000000000000000000000000000000"

// Spectrum Router Address (Script Hash)  
// pub const spectrum_router_script: ByteArray =
//   #"0000000000000000000000000000000000000000000000000000000000000000"

// ----------------------------------------------------------------------------
// HELPER FUNCTION - Tính Constant Product K
// ----------------------------------------------------------------------------

pub fn get_k() -> Int {
  virtual_ada * ( max_supply + virtual_token )
}
