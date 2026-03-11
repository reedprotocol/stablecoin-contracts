use aiken/bytearray
use aiken/list
use aiken/math
use aiken/transaction.{
  ScriptContext, Transaction, WithdrawFrom,
}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value

use reed/er_common as ec
use reed/types as t

use orcfax/feed_id
use orcfax/rational
use orcfax/tokens as ot
use orcfax/validity_range

pub type ErParams {
  fsp_pid: ByteArray,
  fsp_script_hash: ByteArray,
  ada_usd_prefix: ByteArray,
  ree_ada_prefix: ByteArray,
  max_age_ms: Int,
  max_skew_ms: Int,
  max_tx_range_ms: Int,
}

validator(params: ErParams) {
  fn er(red: t.Er2Red, ctx: ScriptContext) {
    when ctx.purpose is {
      WithdrawFrom(_own_cred) -> {
        // ── Parameter validation ──

        expect bytearray.length(params.fsp_pid) == 28
        expect bytearray.length(params.fsp_script_hash) == 28

        expect params.max_tx_range_ms > 0
        expect params.max_age_ms > 0
        expect params.max_skew_ms >= 0

        let max_age_cap_ms = 3_600_000
        let max_skew_cap_ms = 4_500_000
        let max_tx_range_cap_ms = 1_800_000

        expect params.max_age_ms <= max_age_cap_ms
        expect params.max_skew_ms <= max_skew_cap_ms
        expect params.max_tx_range_ms <= max_tx_range_cap_ms

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

        // ── Orcfax: both feeds ──

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

        let (usd_opt, ree_opt) =
          list.foldr(
            fs_inputs,
            (None, None),
            fn(i, acc) {
              expect ScriptCredential(h) =
                i.output.address.payment_credential
              expect h == fs_hash
              let d = ec.get_inline_datum(i)
              expect parsed: rational.RationalFsDat = d
              let st = parsed.statement
              let (usd_acc, ree_acc) = acc
              if feed_id.starts_with(st.feed_id, params.ada_usd_prefix) {
                when usd_acc is {
                  None -> (Some(st), ree_acc)
                  Some(_) ->
                    fail @"ER: Duplicate FS input for ada_usd_prefix"
                }
              } else if feed_id.starts_with(st.feed_id, params.ree_ada_prefix) {
                when ree_acc is {
                  None -> (usd_acc, Some(st))
                  Some(_) ->
                    fail @"ER: Duplicate FS input for ree_ada_prefix"
                }
              } else {
                acc
              }
            },
          )

        expect Some(usd_st) = usd_opt
        expect Some(ree_st) = ree_opt

        // ── Freshness ──

        expect ec.check_created_at(
          usd_st.created_at, ub, params.max_age_ms,
        )
        expect ec.check_created_at(
          ree_st.created_at, ub, params.max_age_ms,
        )

        // ── Skew between feeds ──

        expect
          math.abs(
            usd_st.created_at - ree_st.created_at,
          ) <= params.max_skew_ms

        // ── Extract and validate rates ──

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

        let (u_num_o, u_denom_o) =
          ec.reduce_fraction(usd_denom, usd_num)
        expect ec.check_pos_rational(u_num_o, u_denom_o)

        // ── Validate redeemer matches oracle ──

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
