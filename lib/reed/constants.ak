pub type Rational =
  (Int, Int)

pub fn short_time() -> Int {
  30 * 60 * 1000
}

pub fn million() -> Int {
  1_000_000
}

pub fn total_ree() {
  100 * million() * million()
}

pub fn fee_rate() -> Rational {
  (1, 100)
}

pub fn minimal_collateral_ratio() -> Rational {
  (130, 100)
}

pub fn critical_collateral_ratio() -> Rational {
  (102, 100)
}

pub fn treasury_top_up() -> Rational {
  (105, 100)
}

pub fn max_debt_amount() -> Int {
  5 * million() * million()
}

pub fn min_debt_amount() -> Int {
  500 * million()
}

pub fn min_redeem_amount() -> Int {
  1_000 * million()
}

pub fn max_treasury_utxo() -> Int {
  10_000 * million()
}

pub fn position_metadata_prefix() -> ByteArray {
  #"a4446e616d65557265656420706f736974696f6e2023"
}

pub fn metadata_suffix() -> ByteArray {
  #"45696d6167655835697066733a2f2f516d5871736d654d6d4b766167577933506b59695a7a61314b777a73635654686e61346e52564c61674832684663496d65646961547970654d696d6167652f7376672b786d6c4b6465736372697074696f6e5f58404b657920746f206d616e6167652c207472616e73666572206f7220636c6f73652074686520756e6465726c79696e6720706f736974696f6e2e205375626a656358407420746f20726564656d7074696f6e7320616e64206c69717569646174696f6e2e204966206f727068616e65642c206275726e207669612070726f746f636f6c412eff"
}
