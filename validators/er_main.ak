use aiken/bytearray
use aiken/list
use aiken/pairs
use aiken/transaction.{
  ScriptContext, Transaction, WithdrawFrom,
}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value

use reed/er_common as ec
use reed/types as t

use orcfax/rational
use orcfax/tokens as ot
use orcfax/validity_range

pub type ErParams {
  fsp_pid: ByteArray,
  fsp_script_hash: ByteArray,
  ada_usd_prefix: ByteArray,
  ree_ada_prefix: ByteArray,
  c3_script_hash: ByteArray,
  c3_nft_pid: ByteArray,
  c3_nft_tn: ByteArray,
  c3_price_denom: Int,
  c3_invert: Bool,
  c3_max_age_ms: Int,
  calm_threshold_bps: Int,
  moderate_threshold_bps: Int,
  calm_max_age_ms: Int,
  moderate_max_age_ms: Int,
  volatile_max_age_ms: Int,
  max_oracle_divergence_bps: Int,
  ree_ada_max_age_ms: Int,
  max_tx_range_ms: Int,
}

// ── Charli3 datum types ──

type PriceMap =
  Pairs<Int, Int>

type PriceData {
  SharedData
  ExtendedData
  GenericData { price_map: PriceMap }
}

type OracleDatum {
  price_data: PriceData,
}

fn get_c3_price_info(
  price_data: PriceData,
) -> (Int, Int, Int) {
  when price_data is {
    GenericData { price_map } ->
      when pairs.get_first(price_map, 0) is {
        Some(price) ->
          when pairs.get_first(price_map, 1) is {
            Some(timestamp) ->
              when pairs.get_first(price_map, 2) is {
                Some(expiry) -> (price, timestamp, expiry)
                _ ->
                  fail @"ER: C3 price_map missing expiry"
              }
            _ ->
              fail @"ER: C3 price_map missing timestamp"
          }
        _ -> fail @"ER: C3 price_map missing price"
      }
    SharedData ->
      fail @"ER: C3 SharedData not supported"
    ExtendedData ->
      fail @"ER: C3 ExtendedData not supported"
  }
}

// ── Validator ──

validator(params: ErParams) {
  fn er(red: t.Er2Red, ctx: ScriptContext) {
    when ctx.purpose is {
      WithdrawFrom(_own_cred) -> {
        trace @"er_main: WithdrawFrom"

        // ── Parameter validation ──

        expect bytearray.length(params.fsp_pid) == 28
        expect bytearray.length(params.fsp_script_hash) == 28
        expect bytearray.length(params.c3_script_hash) == 28
        expect bytearray.length(params.c3_nft_pid) == 28
        expect bytearray.length(params.c3_nft_tn) <= 32
        expect params.c3_price_denom > 0

        // Thresholds: calm < moderate < circuit breaker
        expect params.calm_threshold_bps > 0
        expect params.calm_threshold_bps <= 200
        expect params.moderate_threshold_bps >
          params.calm_threshold_bps
        expect params.moderate_threshold_bps <= 400
        expect params.max_oracle_divergence_bps >
          params.moderate_threshold_bps
        expect params.max_oracle_divergence_bps <= 500

        // Age windows: volatile < moderate < calm
        expect params.volatile_max_age_ms > 0
        expect params.volatile_max_age_ms <= 1_200_000
        expect params.moderate_max_age_ms >=
          params.volatile_max_age_ms
        expect params.moderate_max_age_ms <= 1_800_000
        expect params.calm_max_age_ms >=
          params.moderate_max_age_ms
        expect params.calm_max_age_ms <= 3_600_000

        expect params.ree_ada_max_age_ms > 0
        expect params.ree_ada_max_age_ms <= 3_600_000
        expect params.c3_max_age_ms > 0
        expect params.c3_max_age_ms <= 21_600_000
        expect params.max_tx_range_ms > 0
        expect params.max_tx_range_ms <= 1_800_000

        expect ec.check_prefix(params.ada_usd_prefix)
        expect ec.check_prefix(params.ree_ada_prefix)

        // ── Transaction context ──

        let Transaction {
          reference_inputs,
          validity_range: tx_range,
          ..
        } = ctx.transaction

        let (lb, ub) =
          validity_range.get_bounds(tx_range)
        expect lb <= ub
        expect ub - lb <= params.max_tx_range_ms

        // ── Charli3: latest ADA/USD (non-cherry-pickable anchor) ──

        let c3_input =
          ec.find_unique_ref_input_by_asset(
            reference_inputs,
            params.c3_nft_pid,
            params.c3_nft_tn,
          )

        expect ScriptCredential(c3_hash) =
          c3_input.output.address.payment_credential
        expect c3_hash == params.c3_script_hash

        let c3_d = ec.get_inline_datum(c3_input)
        expect c3_od: OracleDatum = c3_d

        let (c3_price, c3_ts, c3_exp) =
          get_c3_price_info(c3_od.price_data)

        expect ec.check_created_at(
          c3_ts, ub, params.c3_max_age_ms,
        )
        expect c3_exp > 0
        expect c3_ts <= c3_exp
        expect ub <= c3_exp

        let (c3_num, c3_denom) =
          if params.c3_invert {
            ec.reduce_fraction(
              params.c3_price_denom, c3_price,
            )
          } else {
            ec.reduce_fraction(
              c3_price, params.c3_price_denom,
            )
          }

        expect ec.check_pos_rational(c3_num, c3_denom)

        // ── Orcfax: ADA/USD and REE/ADA feeds ──

        let fsp =
          ec.find_unique_ref_input_by_asset(
            reference_inputs,
            params.fsp_pid,
            ot.fsp_vali(),
          )

        expect ScriptCredential(fsp_hash) =
          fsp.output.address.payment_credential
        expect fsp_hash == params.fsp_script_hash

        let fsp_d = ec.get_inline_datum(fsp)
        expect fs_hash: ByteArray = fsp_d
        expect bytearray.length(fs_hash) == 28

        let fs_inputs =
          list.filter(
            reference_inputs,
            fn(i) {
              value.quantity_of(
                i.output.value,
                fs_hash,
                ot.fs(),
              ) == 1
            },
          )

        expect list.length(fs_inputs) >= 2

        let usd_st =
          ec.expect_fs_ref_input_for_prefix(
            fs_hash, fs_inputs, params.ada_usd_prefix,
          )

        let ree_st =
          ec.expect_fs_ref_input_for_prefix(
            fs_hash, fs_inputs, params.ree_ada_prefix,
          )

        let rational.Rational {
          num: usd_num,
          denom: usd_denom,
        } = usd_st.body

        let rational.Rational {
          num: ree_num,
          denom: ree_denom,
        } = ree_st.body

        expect ec.check_pos_rational(usd_num, usd_denom)
        expect ec.check_pos_rational(ree_num, ree_denom)

        // ── Three-tier adaptive freshness (ADA/USD) ──

        let orcfax_usd_age = ub - usd_st.created_at
        expect orcfax_usd_age >= 0

        let (usd_num_r, usd_denom_r) =
          ec.reduce_fraction(usd_num, usd_denom)
        expect ec.check_pos_rational(
          usd_num_r, usd_denom_r,
        )

        let (u_num_o, u_denom_o) =
          ec.reduce_fraction(usd_denom_r, usd_num_r)
        expect ec.check_pos_rational(u_num_o, u_denom_o)

        let is_calm =
          ec.within_divergence_bps(
            c3_num,
            c3_denom,
            u_num_o,
            u_denom_o,
            params.calm_threshold_bps,
          )

        let effective_max_age =
          if is_calm {
            params.calm_max_age_ms
          } else {
            let is_moderate =
              ec.within_divergence_bps(
                c3_num,
                c3_denom,
                u_num_o,
                u_denom_o,
                params.moderate_threshold_bps,
              )
            if is_moderate {
              params.moderate_max_age_ms
            } else {
              params.volatile_max_age_ms
            }
          }

        expect orcfax_usd_age <= effective_max_age

        // Circuit breaker
        expect
          ec.within_divergence_bps(
            c3_num,
            c3_denom,
            u_num_o,
            u_denom_o,
            params.max_oracle_divergence_bps,
          )

        // ── REE/ADA: simple age check ──

        expect ec.check_created_at(
          ree_st.created_at,
          ub,
          params.ree_ada_max_age_ms,
        )

        // ── Validate redeemer matches oracle output ──

        let t.Er2Red { r_num, r_denom, u_num, u_denom } =
          red

        expect ec.check_pos_rational(r_num, r_denom)
        expect ec.check_pos_rational(u_num, u_denom)

        expect ec.eq_fraction(
          u_num, u_denom, u_num_o, u_denom_o,
        )
        expect ec.eq_fraction(
          r_num, r_denom, ree_num, ree_denom,
        )

        True
      }
      _ -> fail @"ER: Expected WithdrawFrom"
    }
  }
}
