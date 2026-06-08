use aiken/bytearray
use aiken/list
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

pub type ErOrcfaxParams {
  fsp_pid: ByteArray,
  fsp_script_hash: ByteArray,
  ada_usd_prefix: ByteArray,
  ree_ada_prefix: ByteArray,
  stablecoin_prefixes: List<ByteArray>,
  admin_pks: List<ByteArray>,
  fresh_usd_max_age_ms: Int,
  stablecoin_fresh_max_age_ms: Int,
  absolute_max_age_ms: Int,
  fresh_divergence_bps: Int,
  semi_stale_divergence_bps: Int,
  max_tx_range_ms: Int,
}

fn valid_fresh(
  u: rational.RationalStatement,
  s: rational.RationalStatement,
  ub: Int,
  params: ErOrcfaxParams,
) -> Bool {
  let u_age = ub - u.created_at
  let s_age = ub - s.created_at
  and {
    u_age >= 0,
    s_age >= 0,
    u_age <= params.fresh_usd_max_age_ms,
    s_age <= params.absolute_max_age_ms,
    ec.within_divergence_bps(
      u.body.num, u.body.denom,
      s.body.num, s.body.denom,
      params.fresh_divergence_bps,
    ),
  }
}

fn valid_semi_stale(
  u: rational.RationalStatement,
  s: rational.RationalStatement,
  ub: Int,
  params: ErOrcfaxParams,
) -> Bool {
  let u_age = ub - u.created_at
  let s_age = ub - s.created_at
  and {
    u_age >= 0,
    s_age >= 0,
    u_age <= params.absolute_max_age_ms,
    s_age <= params.stablecoin_fresh_max_age_ms,
    s.created_at > u.created_at,
    ec.within_divergence_bps(
      u.body.num, u.body.denom,
      s.body.num, s.body.denom,
      params.semi_stale_divergence_bps,
    ),
  }
}

fn valid_admin(
  u: rational.RationalStatement,
  ub: Int,
  params: ErOrcfaxParams,
) -> Bool {
  let u_age = ub - u.created_at
  and {
    u_age >= 0,
    u_age <= params.absolute_max_age_ms,
  }
}

validator(params: ErOrcfaxParams) {
  fn er(red: t.Er2Red, ctx: ScriptContext) {
    when ctx.purpose is {
      WithdrawFrom(_own_cred) -> {
        expect params.fresh_usd_max_age_ms <= 3_600_000
        expect params.stablecoin_fresh_max_age_ms <= 900_000
        expect params.absolute_max_age_ms <= 4_500_000
        expect
          params.fresh_usd_max_age_ms <= params.absolute_max_age_ms
        expect
          params.stablecoin_fresh_max_age_ms <= params.absolute_max_age_ms

        expect params.fresh_divergence_bps <= 500
        expect params.semi_stale_divergence_bps <= 300
        expect
          params.semi_stale_divergence_bps <= params.fresh_divergence_bps

        expect params.max_tx_range_ms <= 1_800_000
        expect params.max_tx_range_ms <= params.fresh_usd_max_age_ms

        expect ec.check_prefix(params.ada_usd_prefix)
        expect ec.check_prefix(params.ree_ada_prefix)
        expect list.all(params.stablecoin_prefixes, ec.check_prefix)
        expect !list.any(
          params.stablecoin_prefixes,
          fn(p) {
            feed_id.starts_with(params.ada_usd_prefix, p) ||
              feed_id.starts_with(p, params.ada_usd_prefix) ||
              feed_id.starts_with(params.ree_ada_prefix, p) ||
              feed_id.starts_with(p, params.ree_ada_prefix)
          },
        )

        let Transaction {
          reference_inputs,
          validity_range: tx_range,
          extra_signatories,
          ..
        } = ctx.transaction

        let (lb, ub) = validity_range.get_bounds(tx_range)
        expect lb <= ub
        expect ub - lb <= params.max_tx_range_ms

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
              value.quantity_of(i.output.value, fs_hash, ot.fs()) == 1
            },
          )

        let (usd_opt, ree_opt, stable_opt) =
          list.foldr(
            fs_inputs,
            (None, None, None),
            fn(i, acc) {
              expect ScriptCredential(h) =
                i.output.address.payment_credential
              expect h == fs_hash
              let d = ec.get_inline_datum(i)
              expect parsed: rational.RationalFsDat = d
              let st = parsed.statement
              let (usd_acc, ree_acc, stable_acc) = acc
              if feed_id.starts_with(st.feed_id, params.ada_usd_prefix) {
                when usd_acc is {
                  None -> (Some(st), ree_acc, stable_acc)
                  Some(_) ->
                    fail @"ER: Duplicate FS input for ada_usd_prefix"
                }
              } else if feed_id.starts_with(st.feed_id, params.ree_ada_prefix) {
                when ree_acc is {
                  None -> (usd_acc, Some(st), stable_acc)
                  Some(_) ->
                    fail @"ER: Duplicate FS input for ree_ada_prefix"
                }
              } else if list.any(
                params.stablecoin_prefixes,
                fn(p) { feed_id.starts_with(st.feed_id, p) },
              ) {
                when stable_acc is {
                  None -> (usd_acc, ree_acc, Some(st))
                  Some(_) ->
                    fail @"ER: Duplicate FS input for stablecoin_prefix"
                }
              } else {
                acc
              }
            },
          )

        expect Some(usd_st) = usd_opt
        expect Some(ree_st) = ree_opt

        expect usd_st.created_at >= 0

        expect ec.check_created_at(
          ree_st.created_at, ub, params.absolute_max_age_ms,
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

        let (u_num_o, u_denom_o) =
          ec.reduce_fraction(usd_denom, usd_num)
        expect ec.check_pos_rational(u_num_o, u_denom_o)

        let is_admin_signed =
          list.any(
            params.admin_pks,
            fn(admin_pk) {
              list.any(extra_signatories, fn(pk) { pk == admin_pk })
            },
          )
        let is_admin =
          is_admin_signed && valid_admin(usd_st, ub, params)

        let path_ok = when stable_opt is {
          Some(stable_st) -> {
            expect stable_st.created_at >= 0

            let rational.Rational {
              num: stable_num,
              denom: stable_denom,
            } = stable_st.body
            expect ec.check_pos_rational(stable_num, stable_denom)

            let is_fresh = valid_fresh(usd_st, stable_st, ub, params)
            let is_semi_stale = valid_semi_stale(usd_st, stable_st, ub, params)

            when (is_fresh, is_semi_stale, is_admin) is {
              (True, _, _) -> True
              (_, True, _) -> True
              (_, _, True) -> True
              _ -> fail @"ER: No valid oracle path"
            }
          }
          None -> {
            expect is_admin
            True
          }
        }

        expect path_ok

        let t.Er2Red { r_num, r_denom, u_num, u_denom } = red

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
