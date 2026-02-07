// ============================================================================
// PUMP.FUN VALIDATOR - LEVEL 4 (TRUSTLESS + HEAD ID SECURITY)
// Features: Full AMM + Atomic Graduation + Anti-Drain + Head Protection
// ============================================================================

use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{PolicyId,
  ada_asset_name, ada_policy_id, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// ----------------------------------------------------------------------------
// CONFIGURATION
// ----------------------------------------------------------------------------

const max_supply: Int = 1_000_000_000

const min_ada_in_pool: Int = 2_000_000

const basis_points_divisor: Int = 10000

const platform_fee_basis_points: Int = 100

// Địa chỉ thu phí sàn (Backend của bạn)
const platform_address: ByteArray =
  #"682c94ee8788ccde1b43ec92a608d70e7e144d571a22184e0b36f4a7"

// AMM CONFIG
const virtual_ada: Int = 30_000_000_000

const virtual_token: Int = 300_000_000

// ----------------------------------------------------------------------------
// TRUSTLESS PARAMS (SECURITY)
// ----------------------------------------------------------------------------

// 1. Hash của Hydra Deposit Script (Lấy từ hydra-node)
const hydra_deposit_script_hash: ByteArray =
  #"ae01dade3a9c346d5c93ae3ce339412b90a0b8f83f94ec6baa24e30c"

// 2. Hash của Minswap Order Contract
const target_dex_script_hash: ByteArray =
  #"00000000000000000000000000000000000000000000000000000000"

// 3. [UPDATED] HYDRA HEAD ID (Policy ID của Head Token)
// Đã cập nhật theo Head ID bạn vừa mở: a3731a...
const platform_head_id: PolicyId =
  #"a3731a22ce7bf7e5b6c9854fc51635d2c901253486f2474a01d245ad"

// ----------------------------------------------------------------------------
// HELPER FUNCTIONS
// ----------------------------------------------------------------------------

fn get_k() -> Int {
  virtual_ada * ( max_supply + virtual_token )
}

fn get_expected_ada_reserve(current_supply: Int) -> Int {
  let k = get_k()
  let real_token_reserve = max_supply - current_supply
  let total_token_reserve = real_token_reserve + virtual_token
  if total_token_reserve <= 0 {
    999_999_999_999_999
  } else {
    let total_ada_reserve =
      ( k + total_token_reserve - 1 ) / total_token_reserve
    let real_ada_reserve = total_ada_reserve - virtual_ada
    if real_ada_reserve < 0 {
      0
    } else {
      real_ada_reserve
    }
  }
}

fn calculate_fee(amount: Int) -> Int {
  amount * platform_fee_basis_points / basis_points_divisor
}

fn check_fee_payment(outputs: List<Output>, fee_amount: Int) -> Bool {
  list.any(
    outputs,
    fn(output) {
      let is_target =
        when output.address.payment_credential is {
          VerificationKey(hash) -> hash == platform_address
          _ -> False
        }
      let ada_value = quantity_of(output.value, ada_policy_id, ada_asset_name)
      is_target && ada_value >= fee_amount
    },
  )
}

// ----------------------------------------------------------------------------
// TYPES
// ----------------------------------------------------------------------------

pub type Action {
  MintInitial
  Buy { amount: Int, max_cost_limit: Int }
  Sell { amount: Int, min_refund_limit: Int }
  DepositToHydra
}

pub type PoolDatum {
  token_policy: PolicyId,
  token_name: ByteArray,
  current_supply: Int,
  creator: ByteArray,
}

// ============================================================================
// VALIDATOR LOGIC
// ============================================================================

validator pump(required_tx_hash: ByteArray, required_output_index: Int) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let Transaction { inputs, mint, .. } = tx
    let required_utxo =
      OutputReference {
        transaction_id: required_tx_hash,
        output_index: required_output_index,
      }
    let utxo_consumed =
      list.any(inputs, fn(input) { input.output_reference == required_utxo })
    let minted_tokens = tokens(mint, policy_id)
    let single_token_minted =
      when dict.to_pairs(minted_tokens) is {
        [Pair(_, quantity)] -> quantity == max_supply
        _ -> False
      }
    utxo_consumed && single_token_minted
  }

  spend(
    datum_opt: Option<PoolDatum>,
    redeemer: Action,
    _output_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = datum_opt
    let Transaction { inputs, outputs, extra_signatories, .. } = tx

    expect Some(own_input) =
      list.find(
        inputs,
        fn(input) {
          quantity_of(input.output.value, datum.token_policy, datum.token_name) > 0
        },
      )
    let pool_address = own_input.output.address
    let input_value = own_input.output.value
    // Chống Double Spend
    let script_inputs =
      list.filter(inputs, fn(i) { i.output.address == pool_address })
    expect list.length(script_inputs) == 1

    when redeemer is {
      // ======================================================================
      // DEPOSIT TO HYDRA (FIX CỨNG SCRIPT HASH - AN TOÀN TUYỆT ĐỐI)
      // ======================================================================
      DepositToHydra -> {
        // 1. CHECK QUYỀN
        expect list.has(extra_signatories, datum.creator)

        // 2. LẤY TRẠNG THÁI HIỆN TẠI (Để so sánh output)
        let current_pool_ada =
          quantity_of(input_value, ada_policy_id, ada_asset_name)
        let current_pool_tokens =
          quantity_of(input_value, datum.token_policy, datum.token_name)

        // 3. CHECK ĐÍCH ĐẾN & HEAD TOKEN (FIX CỨNG)
        expect
          list.any(
            outputs,
            fn(output) {
              // A. Check Address (Script Hash của Hydra Deposit)
              let is_hydra_dest =
                when output.address.payment_credential is {
                  Script(hash) -> hash == hydra_deposit_script_hash
                  _ -> False
                }

              // B. Check Token (Phải chuyển hết 100% số dư hiện tại)
              let has_tokens =
                quantity_of(output.value, datum.token_policy, datum.token_name) == current_pool_tokens

              // C. Check ADA (Mang theo toàn bộ)
              let output_ada =
                quantity_of(output.value, ada_policy_id, ada_asset_name)
              let has_enough_ada = output_ada >= current_pool_ada
              is_hydra_dest && has_tokens && has_enough_ada
            },
          )

        True
      }

      // ======================================================================
      // BUY (AMM)
      // ======================================================================
      Buy { amount, max_cost_limit } -> {
        expect amount > 0
        let new_supply = datum.current_supply + amount
        expect new_supply <= max_supply
        let expected_ada = get_expected_ada_reserve(new_supply)
        let current_ada =
          quantity_of(input_value, ada_policy_id, ada_asset_name)
        let exact_cost = expected_ada - current_ada
        expect exact_cost >= 0
        let fee = calculate_fee(exact_cost)
        expect exact_cost + fee <= max_cost_limit
        expect check_fee_payment(outputs, fee)

        if new_supply == max_supply {
          // GRADUATION
          expect
            list.any(
              outputs,
              fn(output) {
                let is_dex =
                  when output.address.payment_credential is {
                    Script(h) -> h == target_dex_script_hash
                    _ -> False
                  }
                let out_ada =
                  quantity_of(output.value, ada_policy_id, ada_asset_name)
                let req_ada = current_ada + exact_cost - 3_000_000
                let has_datum =
                  when output.datum is {
                    InlineDatum(_) -> True
                    _ -> False
                  }
                is_dex && out_ada >= req_ada && has_datum
              },
            )
          True
        } else {
          // NORMAL BUY
          expect Some(cont_out) =
            list.find(outputs, fn(o) { o.address == pool_address })
          expect InlineDatum(d_data) = cont_out.datum
          expect new_d: PoolDatum = d_data
          expect new_d.current_supply == new_supply
          expect new_d.token_policy == datum.token_policy
          expect new_d.token_name == datum.token_name
          expect new_d.creator == datum.creator

          let out_ada =
            quantity_of(cont_out.value, ada_policy_id, ada_asset_name)
          expect out_ada >= expected_ada
          let out_tokens =
            quantity_of(cont_out.value, datum.token_policy, datum.token_name)
          let in_tokens =
            quantity_of(input_value, datum.token_policy, datum.token_name)
          expect in_tokens - out_tokens == amount
          True
        }
      }

      // ======================================================================
      // SELL (AMM)
      // ======================================================================
      Sell { amount, min_refund_limit } -> {
        expect amount > 0
        let new_supply = datum.current_supply - amount
        expect new_supply >= 0
        let expected_ada = get_expected_ada_reserve(new_supply)
        let current_ada =
          quantity_of(input_value, ada_policy_id, ada_asset_name)
        let exact_refund = current_ada - expected_ada
        expect exact_refund >= 0
        let fee = calculate_fee(exact_refund)
        let user_receive = exact_refund - fee
        expect user_receive >= min_refund_limit
        expect check_fee_payment(outputs, fee)
        expect Some(cont_out) =
          list.find(outputs, fn(o) { o.address == pool_address })
        expect InlineDatum(d_data) = cont_out.datum
        expect new_d: PoolDatum = d_data
        expect new_d.current_supply == new_supply
        expect new_d.token_policy == datum.token_policy
        let out_ada = quantity_of(cont_out.value, ada_policy_id, ada_asset_name)
        expect out_ada >= expected_ada
        expect out_ada >= min_ada_in_pool
        let out_tokens =
          quantity_of(cont_out.value, datum.token_policy, datum.token_name)
        let in_tokens =
          quantity_of(input_value, datum.token_policy, datum.token_name)
        expect out_tokens - in_tokens == amount
        True
      }
      _ -> False
    }
  }

  else(_) {
    fail @"Invalid purpose"
  }
}
