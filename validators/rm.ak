use aiken/dict
use aiken/list
use aiken/transaction.{Input, Mint, OutputReference, ScriptContext, Transaction}
use aiken/transaction/value
use reed/constants as c
use reed/tokens

pub type Rm2Red {
  Rm2Mint
  Rm2Burn
}

validator(params: OutputReference) {
  pub fn rm2(red: Rm2Red, ctx: ScriptContext) {
    let ScriptContext { transaction, purpose } = ctx
    trace @"2Args: purpose is mint only"
    expect Mint(own_pid) = purpose
    let Transaction { inputs, mint, .. } = transaction
    expect [Pair(ree_asset_name, ree_amt)] =
      dict.to_pairs(value.tokens(value.from_minted_value(mint), own_pid))
    when red is {
      Rm2Mint -> {
        trace @"**Rm2Mint**:"
        trace @"1. `RmParams` is spent"
        expect list.any(inputs, fn(i) { i.output_reference == params })
        trace @"2. Own mint is `[(ree, TOTAL_REE)]`"
        expect tokens.ree() == ree_asset_name
        expect c.total_ree() == ree_amt
        True
      }
      Rm2Burn -> {
        False
      }
    }
  }
}
