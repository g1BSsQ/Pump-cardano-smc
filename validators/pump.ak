// ============================================================================
// PUMP.FUN VALIDATOR - Bonding Curve DEX trên Cardano
// ============================================================================
// Chương trình này quản lý pool token với giá theo đường cong tăng dần
// Giá = Slope × Số lượng token đã bán
// Ví dụ: Token thứ 1 giá 1 ADA, token thứ 2 giá 2 ADA, token thứ 3 giá 3 ADA...
// ============================================================================

// Import các thư viện cần thiết
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, ada_asset_name, ada_policy_id, flatten, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// ----------------------------------------------------------------------------
// REDEEMER: Các hành động người dùng có thể thực hiện
// ----------------------------------------------------------------------------
// Redeemer giống như "lệnh" gửi đến smart contract
// Nó cho biết bạn muốn làm gì: mint, mua, bán, hay rút tiền
pub type Action {
  MintInitial                                // Tạo token lần đầu (chỉ 1 lần duy nhất)
  Buy { amount: Int, max_cost: Int }         // Mua token, max_cost = giá tối đa chấp nhận
  Sell { amount: Int, min_refund: Int }      // Bán token, min_refund = tiền tối thiểu nhận lại
  AdminWithdraw { ada_amount: Int }          // Creator rút tiền dư thừa (nếu có)
}

// ----------------------------------------------------------------------------
// DATUM: Dữ liệu lưu trữ tại UTXO của pool
// ----------------------------------------------------------------------------
// Datum giống như "biến toàn cục" lưu trạng thái của pool
// Mỗi khi ai đó mua/bán, datum sẽ được cập nhật

pub type PoolDatum {
  token_policy: PolicyId,    // ID duy nhất của token (như số CMND)
  token_name: ByteArray,     // Tên token (PUMP, DOGE, ...)
  slope: Int,                // Hệ số độ dốc của đường cong giá (càng cao = giá tăng càng nhanh)
  current_supply: Int,       // Đã bán bao nhiêu token (nếu bán 100 token, giá trị này = 100)
  creator: ByteArray,        // Địa chỉ của người tạo pool (chỉ người này mới rút được tiền)
}

// ----------------------------------------------------------------------------
// HẰNG SỐ: Các giá trị cố định trong hệ thống
// ----------------------------------------------------------------------------

// Pool phải giữ ít nhất 2 ADA (luật Cardano: mọi UTXO cần ADA tối thiểu)
const min_ada_in_pool: Int = 2_000_000  // 2 triệu lovelace = 2 ADA

// Giới hạn tối đa 1 tỷ token (chống tấn công DoS)
const max_supply: Int = 1_000_000_000

// ----------------------------------------------------------------------------
// HÀM TÍNH GIÁ: Bonding Curve
// ----------------------------------------------------------------------------
// Công thức: Chi phí = Slope × (end² - start²) / 2
// Ví dụ: Mua token thứ 0 đến 10 với slope=1000
//   Chi phí = 1000 × (10² - 0²) / 2 = 1000 × 100 / 2 = 50,000 lovelace
fn calculate_cost(slope: Int, supply_start: Int, supply_end: Int) -> Int {
  let end_squared = supply_end * supply_end      // Bình phương số cuối
  let start_squared = supply_start * supply_start // Bình phương số đầu
  slope * ( end_squared - start_squared ) / 2     // Áp dụng công thức tích phân
}

// ============================================================================
// VALIDATOR CHÍNH: Nơi kiểm tra mọi giao dịch
// ============================================================================
// Validator giống như "nhân viên bảo vệ" kiểm tra mọi giao dịch có hợp lệ không
// Nếu vi phạm bất kỳ quy tắc nào → Giao dịch bị từ chối
//
// Tham số:
// - required_tx_hash: UTXO bắt buộc phải tiêu thụ khi mint (one-shot)
// - required_output_index: Vị trí của UTXO đó

validator pump(required_tx_hash: ByteArray, required_output_index: Int) {
  // --------------------------------------------------------------------------
  // PHẦN 1: MINT POLICY - Kiểm tra việc tạo token
  // --------------------------------------------------------------------------
  // Chức năng: Chỉ cho phép mint token MỘT LẦN DUY NHẤT (one-shot)
  // Cách hoạt động: Phải tiêu thụ 1 UTXO cụ thể để mint
  // Sau khi UTXO đó bị dùng, không thể mint thêm nữa
  mint(redeemer: Action, policy_id: PolicyId, tx: Transaction) {
    when redeemer is {
      MintInitial -> {
        // Lấy danh sách các input (UTXO đang được tiêu thụ) và token đang mint
        let Transaction { inputs, mint, .. } = tx
        
        // Tạo địa chỉ UTXO bắt buộc từ tham số validator
        let required_utxo =
          OutputReference {
            transaction_id: required_tx_hash,
            output_index: required_output_index,
          }
        
        // Kiểm tra: UTXO bắt buộc có nằm trong danh sách inputs không?
        // list.any = "có ít nhất 1 phần tử thỏa mãn điều kiện"
        let utxo_consumed =
          list.any(
            inputs,
            fn(input: Input) {  // fn = function (hàm nặc danh)
              let Input { output_reference, .. } = input
              output_reference == required_utxo
            },
          )
        
        // Lấy danh sách token đang được mint
        let minted_tokens = tokens(mint, policy_id)
        let minted_assets = dict.to_pairs(minted_tokens)
        
        // Kiểm tra: Chỉ được mint ĐÚNG 1 LOẠI token với số lượng > 0
        // when...is = switch-case trong các ngôn ngữ khác
        let single_token_minted =
          when minted_assets is {
            [Pair(_, quantity)] -> quantity > 0  // Nếu chỉ có 1 loại và số lượng > 0
            _ -> False                           // Mọi trường hợp khác đều sai
          }
        
        // Kết luận: Mint hợp lệ khi VÀ (&&) 2 điều kiện đàng đúng
        utxo_consumed && single_token_minted
      }
      _ -> False  // Không cho phép mint bằng các redeemer khác
    }
  }
  
  // --------------------------------------------------------------------------
  // PHẦN 2: SPEND VALIDATOR - Quản lý pool (mua/bán/rút tiền)
  // --------------------------------------------------------------------------
  // Chức năng: Kiểm tra mọi giao dịch sử dụng UTXO của pool
  // Khi ai đó mua/bán token, họ "tiêu thụ" UTXO cũ và tạo UTXO mới
  // Validator kiểm tra UTXO mới có hợp lệ không
  spend(
    datum_opt: Option<PoolDatum>,  // Dữ liệu cũ của pool
    redeemer: Action,               // Lệnh người dùng muốn thực hiện
    _output_ref: OutputReference,   // Tham số bắt buộc nhưng không dùng (_ = ignore)
    tx: Transaction,                // Thông tin toàn bộ giao dịch
  ) {
    // expect = "kiểm tra và giải nén", nếu sai → giao dịch fail
    expect Some(datum) = datum_opt  // Pool UTXO phải có datum
    
    // Lấy danh sách inputs (UTXO đang tiêu thụ) và outputs (UTXO mới tạo ra)
    let Transaction { inputs, outputs, .. } = tx
    
    // TÌM POOL UTXO HIỆN TẠI (input)
    // list.find = tìm phần tử đầu tiên thỏa mãn điều kiện
    expect Some(own_input) =
      list.find(
        inputs,
        fn(input: Input) {
          let Input { output, .. } = input
          let Output { address, .. } = output
          let Address { payment_credential, .. } = address
          // Kiểm tra: Address có phải là Script (smart contract) không?
          when payment_credential is {
            Script(_) -> True  // Đúng: đây là pool UTXO
            _ -> False         // Sai: đây là ví thường
          }
        },
      )
    
    // Giải nén thông tin từ pool UTXO hiện tại
    let Input { output: own_output, .. } = own_input
    let Output { value: input_value, address: pool_address, .. } = own_output
    
    // TÌM POOL UTXO MỚI (đầu ra / continuing output)
    // Pool UTXO mới phải có cùng address với UTXO cũ
    expect Some(continuing_output) =
      list.find(
        outputs,
        fn(output: Output) {
          let Output { address, .. } = output
          address == pool_address  // Cùng address = cùng pool
        },
      )
    
    // Giải nén thông tin từ pool UTXO mới
    let Output { value: output_value, datum: output_datum_inline, .. } =
      continuing_output
    
    // Giải nén datum mới (dữ liệu mới của pool)
    expect InlineDatum(output_datum_data) = output_datum_inline
    expect new_datum: PoolDatum = output_datum_data
    
    // ------------------------------------------------------------------------
    // BẢO MẬT: Kiểm tra không có token rác trong pool
    // ------------------------------------------------------------------------
    // flatten = chuyển Value thành list [(policy, name, amount), ...]
    // Chuyển Value thành list assets để đếm
    let output_assets = flatten(output_value)
    let output_tokens_count = quantity_of(output_value, datum.token_policy, datum.token_name)
    
    // Pool UTXO chỉ được chứa: 1) ADA và 2) Token chính
    // Nếu token = 0 (bán hết) thì chỉ còn ADA (length = 1)
    let expected_asset_count = if output_tokens_count == 0 { 1 } else { 2 }
    expect list.length(output_assets) == expected_asset_count
    
    // Xác minh token ID chính xác (chống asset swap)
    // Nếu còn token trong pool, phải đúng là token đã khai báo trong datum
    let asset_check = if output_tokens_count > 0 {
      list.any(
        output_assets,
        fn(asset) {
          let (policy, name, _) = asset
          policy == datum.token_policy && name == datum.token_name
        },
      )
    } else {
      True  // Nếu hết token thì không cần kiểm tra
    }
    expect asset_check
    
    // Kiểm tra các field KHÔNG ĐƯỢC THAY ĐỔI
    // Chỉ có current_supply được phép thay đổi khi mua/bán
    let datum_unchanged =
      new_datum.token_policy == datum.token_policy && new_datum.token_name == datum.token_name && new_datum.slope == datum.slope && new_datum.creator == datum.creator
    
    // ------------------------------------------------------------------------
    // XỬ LÝ TỮNG LOẠI HÀNH ĐỘNG
    // ------------------------------------------------------------------------
    when redeemer is {
      // ======================================================================
      // HÀNH ĐỘNG 1: MUA TOKEN (Buy)
      // ======================================================================
      // Người dùng gửi ADA vào pool, nhận token ra
      // Ví dụ: Mua 10 token, gửi 50 ADA, nhận 10 token
      Buy { amount, max_cost } -> {
        // BƯỚC 1: Kiểm tra cơ bản
        // Kiểm tra amount > 0
        expect amount > 0
        
        // BƯỚC 2: Tính giá
        // Tính chi phí ADA cần thiết
        let old_supply = datum.current_supply       // Số token đã bán (hiện tại)
        let new_supply = old_supply + amount        // Số token sẽ bán (sau khi mua)
        
        // Bảo vệ: Không cho mua quá giới hạn
        expect new_supply <= max_supply
        
        // Tính chi phí theo công thức bonding curve
        let cost = calculate_cost(datum.slope, old_supply, new_supply)
        
        // Bảo vệ: Chi phí phải > 0 (tránh lấy token miễn phí do làm tròn)
        expect cost > 0
        
        // Bảo vệ: Slippage protection (chống front-running)
        // Nếu giá vượt quá max_cost người dùng chấp nhận → hủy giao dịch
        expect cost <= max_cost
        
        // BƯỚC 3: Kiểm tra datum mới
        // Kiểm tra supply mới được cập nhật đúng
        expect new_datum.current_supply == new_supply
        
        // BƯỚC 4: Kiểm tra ADA vào pool
        // Kiểm tra ADA vào pool tăng đúng cost
        let input_ada = quantity_of(input_value, ada_policy_id, ada_asset_name)
        let output_ada =
          quantity_of(output_value, ada_policy_id, ada_asset_name)
        let ada_paid = output_ada - input_ada       // ADA tăng thêm trong pool
        expect ada_paid == cost                     // Phải bằng đúng chi phí tính được
        
        // BƯỚC 5: Kiểm tra token ra khỏi pool
        // Đếm số token ra/vào pool
        let input_tokens =
          quantity_of(input_value, datum.token_policy, datum.token_name)
        let output_tokens =
          quantity_of(output_value, datum.token_policy, datum.token_name)
        let tokens_sent = input_tokens - output_tokens  // Token giảm trong pool
        expect tokens_sent == amount                    // Phải bằng số lượng mua
        
        // KếT LUẬN: Giao dịch hợp lệ nếu datum không thay đổi (ngoại trừ supply)
        datum_unchanged
      }
      
      // ======================================================================
      // HÀNH ĐỘNG 2: BÁN TOKEN (Sell)
      // ======================================================================
      // Người dùng gửi token vào pool, nhận ADA ra
      // Ví dụ: Bán 10 token, gửi 10 token, nhận 50 ADA
      Sell { amount, min_refund } -> {
        // BƯỚC 1: Kiểm tra cơ bản
        // Kiểm tra amount > 0
        expect amount > 0
        
        // BƯỚC 2: Tính giá
        // Tính ADA nhận được khi bán
        let old_supply = datum.current_supply       // Số token đã bán (hiện tại)
        let new_supply = old_supply - amount        // Số token sẽ bán (sau khi bán)
        // Không cho bán quá supply hiện tại
        expect new_supply >= 0
        
        // Tính tiền hoàn lại theo bonding curve
        // (Bán từ new_supply lên old_supply = Mua ngược lại)
        let refund = calculate_cost(datum.slope, new_supply, old_supply)
        
        // Bảo vệ: Slippage protection
        // Nếu tiền hoàn < min_refund người dùng chấp nhận → hủy giao dịch
        expect refund >= min_refund
        
        // BƯỚC 3: Kiểm tra datum mới
        // Kiểm tra supply mới được cập nhật đúng
        expect new_datum.current_supply == new_supply
        
        // Kiểm tra ADA ra khỏi pool giảm đúng refund
        let input_ada = quantity_of(input_value, ada_policy_id, ada_asset_name)
        let output_ada =
          quantity_of(output_value, ada_policy_id, ada_asset_name)
        let ada_returned = input_ada - output_ada
        expect ada_returned == refund
        
        // MIN-ADA LOGIC: Luôn giữ min_ada để tuân thủ Cardano ledger rules
        // (Nếu muốn burn pool hoàn toàn thì cần logic riêng)
        expect output_ada >= min_ada_in_pool
        
        // Kiểm tra token vào pool tăng đúng amount
        let input_tokens =
          quantity_of(input_value, datum.token_policy, datum.token_name)
        let output_tokens =
          quantity_of(output_value, datum.token_policy, datum.token_name)
        let tokens_returned = output_tokens - input_tokens
        expect tokens_returned == amount
        
        datum_unchanged
      }
      
      // ======================================================================
      // HÀNH ĐỘNG 3: RÚT TIỀN DƯ THỮA (AdminWithdraw)
      // ======================================================================
      // Chỉ creator mới được rút ADA dư thừa (ví dụ: ai đó gửi nhầm)
      // KHÔNG được rút Reserve (tiền bảo đảm cho token đã bán)
      AdminWithdraw { ada_amount } -> {
        // BƯỚC 1: Kiểm tra quyền
        expect ada_amount > 0
        
        // Xác minh chữ ký của creator
        // extra_signatories = danh sách người ký giao dịch
        let Transaction { extra_signatories, .. } = tx
        expect list.has(extra_signatories, datum.creator)  // Creator phải ký
        
        // BƯỚC 2: Kiểm tra supply không đổi
        // Rút tiền KHÔNG được ảnh hưởng đến bonding curve
        expect new_datum.current_supply == datum.current_supply
                // Tính số ADA thực tế đang rút
        let input_ada = quantity_of(input_value, ada_policy_id, ada_asset_name)
        let output_ada = quantity_of(output_value, ada_policy_id, ada_asset_name)
        let ada_withdrawn = input_ada - output_ada  // ADA giảm trong pool
        expect ada_withdrawn == ada_amount          // Phải đúng số muốn rút
        
        // BƯỚC 3: Tính Reserve (tiền bảo đảm)
        // Tính reserve lý thuyết bằng bonding curve từ 0 đến supply hiện tại
        // Reserve = Tổng tiền cần thiết để mua lại tất cả token đã bán
        let theoretical_reserve = calculate_cost(datum.slope, 0, datum.current_supply)
        
        // BƯỚC 4: Tính phần dư được phép rút
        // Chỉ cho rút phần dư thừa (do làm tròn tích lũy)
        // Ví dụ: Pool có 110 ADA, reserve = 100 ADA, min = 2 ADA
        //         → Rút được tối đa: 110 - 100 - 2 = 8 ADA
        let max_withdrawable = 
          if input_ada > theoretical_reserve + min_ada_in_pool {
            input_ada - (theoretical_reserve + min_ada_in_pool)
          } else {
            0  // Không có tiền dư thừa để rút
          }
        
        // Bảo vệ: KHÔNG cho rút quá phần dư
        expect ada_amount <= max_withdrawable
        
        // BƯỚC 5: Kiểm tra token không đổi
        // Rút tiền KHÔNG được lấy token
        let input_tokens = quantity_of(input_value, datum.token_policy, datum.token_name)
        let output_tokens = quantity_of(output_value, datum.token_policy, datum.token_name)
        expect input_tokens == output_tokens  // Token phải giữ nguyên
        
        // KếT LUẬN: Giao dịch hợp lệ nếu datum không thay đổi
        datum_unchanged
      }
      
      // ======================================================================
      // MỌI TRƯờNG HỢP KHÁC: KHÔNG HỢP LỆ
      // ======================================================================
      _ -> False  // Không cho phép các hành động khác trong spend
    }
  }

  else(_) {
    fail
  }
}
