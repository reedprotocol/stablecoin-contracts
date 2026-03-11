use aiken/bytearray
use aiken/list
use aiken/math
use aiken/transaction.{InlineDatum, Input}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value

use orcfax/feed_id
use orcfax/rational

pub fn find_unique_ref_input_by_asset(
  ref_inputs: List<Input>,
  pid: ByteArray,
  tn: ByteArray,
) -> Input {
  let matches =
    list.filter(
      ref_inputs,
      fn(i) { value.quantity_of(i.output.value, pid, tn) == 1 },
    )
  when matches is {
    [x] -> x
    _ -> fail @"ER: Expected exactly one matching reference input"
  }
}

pub fn get_inline_datum(i: Input) -> Data {
  when i.output.datum is {
    InlineDatum(d) -> d
    _ -> fail @"ER: Expected inline datum"
  }
}

pub fn check_prefix(prefix: ByteArray) -> Bool {
  let l = bytearray.length(prefix)
  expect l > 0
  expect bytearray.drop(prefix, l - 1) == "/"
  True
}

pub fn expect_fs_ref_input_for_prefix(
  fs_hash: ByteArray,
  fs_inputs: List<Input>,
  expected_prefix: ByteArray,
) -> rational.RationalStatement {
  let matches =
    list.filter_map(
      fs_inputs,
      fn(i) {
        expect ScriptCredential(h) =
          i.output.address.payment_credential
        expect h == fs_hash
        let d = get_inline_datum(i)
        expect parsed: rational.RationalFsDat = d
        let st = parsed.statement
        if feed_id.starts_with(st.feed_id, expected_prefix) {
          Some(st)
        } else {
          None
        }
      },
    )
  when matches is {
    [s] -> s
    _ -> fail @"ER: Expected exactly one FS input for prefix"
  }
}

pub fn check_created_at(
  created_at: Int,
  ub: Int,
  max_age_ms: Int,
) -> Bool {
  expect created_at >= 0
  expect ub >= 0
  expect created_at <= ub
  expect ub - created_at <= max_age_ms
  True
}

pub fn check_pos_rational(num: Int, denom: Int) -> Bool {
  let max_component = 1_000_000_000_000_000_000
  expect num > 0
  expect denom > 0
  expect num <= max_component
  expect denom <= max_component
  True
}

pub fn reduce_fraction(num: Int, denom: Int) -> (Int, Int) {
  let g = math.gcd(num, denom)
  (num / g, denom / g)
}

pub fn eq_fraction(
  a_num: Int,
  a_denom: Int,
  b_num: Int,
  b_denom: Int,
) -> Bool {
  a_num * b_denom == a_denom * b_num
}

pub fn within_divergence_bps(
  a_num: Int,
  a_denom: Int,
  b_num: Int,
  b_denom: Int,
  max_bps: Int,
) -> Bool {
  let a = a_num * b_denom
  let b = b_num * a_denom
  let (lo, hi) =
    if a < b {
      (a, b)
    } else {
      (b, a)
    }
  lo * (10_000 + max_bps) >= hi * 10_000
}

// ── Tests ──

test test_within_divergence_exact() {
  within_divergence_bps(100, 100, 100, 100, 0)
}

test test_within_divergence_1pct_pass() {
  within_divergence_bps(100, 100, 101, 100, 100)
}

test test_within_divergence_1pct_boundary() {
  within_divergence_bps(1000, 1000, 1010, 1000, 100)
}

test test_within_divergence_1pct_fail() {
  !within_divergence_bps(100, 100, 1011, 1000, 100)
}

test test_within_divergence_5pct_pass() {
  within_divergence_bps(100, 100, 105, 100, 500)
}

test test_within_divergence_5pct_fail() {
  !within_divergence_bps(100, 100, 1051, 1000, 500)
}

test test_within_divergence_symmetric() {
  and {
    within_divergence_bps(105, 100, 100, 100, 500),
    within_divergence_bps(100, 100, 105, 100, 500),
  }
}

test test_eq_fraction_basic() {
  eq_fraction(1, 2, 2, 4)
}

test test_eq_fraction_large() {
  eq_fraction(333, 1000, 999, 3000)
}

test test_eq_fraction_unequal() {
  !eq_fraction(1, 2, 2, 3)
}

test test_reduce_fraction() {
  reduce_fraction(6, 4) == (3, 2)
}

test test_reduce_fraction_coprime() {
  reduce_fraction(7, 3) == (7, 3)
}
