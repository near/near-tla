//! Gas that depends on more than the call's arguments: the trie-node charge
//! of storage writes and removes, which grows with the depth of the trie at
//! the key, while reads and `has_key` pay none (docs/SEMANTICS.md, G6); and
//! the per-byte cost of reading a promise result (C4).
//! Each test prints what it observed; `cargo test --test gas -- --nocapture`
//! shows it.
//!
//! nearcore references are at the pinned rev bc4e9e8 (README, "Pins"):
//! `runtime/runtime/src/ext.rs:163-178` (`storage_set` looks the key up with
//! `KeyLookupMode::MemOrTrie` and charges the nodes it touched),
//! `:248-264` (`storage_remove`, the same), `:200-203` (`storage_get` looks
//! it up with `MemOrFlatOrTrie`), `core/store/src/trie/mod.rs:1533` (only a
//! `MemOrTrie` lookup counts nodes), `core/parameters/res/runtime_configs/82.yaml:5-11`
//! (2.28 Ggas per node). The contract is the WAT module `KV` below.
use near_contract_sim::prelude::*;

const ALICE: &str = "alice.near";
const W: &str = "w-kv.near";

/// `wasm_touching_trie_node` at 88, gas per node.
const TTN: u64 = 2_280_000_000;

/// `put`, `get`, `has` and `del` take the key as their whole input; `put`
/// writes the one-byte value "v".
const KV: &str = r#"
(module
  (import "env" "input" (func $input (param i64)))
  (import "env" "register_len" (func $register_len (param i64) (result i64)))
  (import "env" "read_register" (func $read_register (param i64 i64)))
  (import "env" "storage_write" (func $write (param i64 i64 i64 i64 i64) (result i64)))
  (import "env" "storage_read" (func $read (param i64 i64 i64) (result i64)))
  (import "env" "storage_remove" (func $remove (param i64 i64 i64) (result i64)))
  (import "env" "storage_has_key" (func $has (param i64 i64) (result i64)))
  (memory 1)
  (export "memory" (memory 0))
  (data (i32.const 0) "v")
  ;; The key, read to offset 1024; returns its length.
  (func $key (result i64)
    (call $input (i64.const 0))
    (call $read_register (i64.const 0) (i64.const 1024))
    (call $register_len (i64.const 0)))
  (func (export "put")
    (drop (call $write (call $key) (i64.const 1024) (i64.const 1) (i64.const 0) (i64.const 1))))
  (func (export "get")
    (drop (call $read (call $key) (i64.const 1024) (i64.const 1))))
  (func (export "has")
    (drop (call $has (call $key) (i64.const 1024))))
  (func (export "del")
    (drop (call $remove (call $key) (i64.const 1024) (i64.const 1)))))
"#;

fn world() -> Sim {
    Fixture::new()
        .account(ALICE, Balance::from_near(1000))
        .contract(W, wat::parse_str(KV).unwrap())
        .build()
}

/// One call of `m` with key `key`, in its own transaction; the gas its
/// receipt burnt.
fn burnt(sim: &mut Sim, m: &str, key: &[u8]) -> u64 {
    let o = sim.tx(ALICE, W).call(m).args(key.to_vec()).transact();
    let r = o.first_call().unwrap();
    assert!(r.is_success(), "{o}");
    r.gas_burnt.as_gas()
}

/// The keys that deepen the trie at `k`: for each byte of `k`, one key that
/// agrees with `k` up to that byte's high nibble and one up to its low
/// nibble, then differs. Each puts a branch node on `k`'s path.
fn siblings(k: &[u8]) -> Vec<Vec<u8>> {
    (0..k.len())
        .flat_map(|j| [0x10u8, 0x01].map(|flip| [&k[..j], &[k[j] ^ flip]].concat()))
        .collect()
}

/// A write's and a remove's gas grow by 2.28 Ggas per trie node on the
/// key's path. The shallow trie holds one other key of the account; the
/// deep one also a sibling key at every nibble of the 8-byte key (16 keys,
/// each written in its own transaction, so in the trie the next chunk
/// starts from). Under the account's prefix the key's path is then an
/// extension, a branch per nibble and a leaf, against one leaf (absent key)
/// or an extension, one branch and a leaf (present key) in the shallow trie:
/// 16 more nodes for the write of a new key (its lookup ends at the leaf of
/// the sibling at the 15th nibble, which it will split), 15 for an overwrite
/// and a remove. Reading the key and `has_key` cost the same in both tries.
#[test]
fn trie_depth_storage_gas() {
    let key = b"k0123456";
    let shallow = {
        let mut s = world();
        burnt(&mut s, "put", b"seed");
        s
    };
    let deep = {
        let mut s = shallow.clone();
        for k in siblings(key) {
            burnt(&mut s, "put", &k);
        }
        s
    };
    let measure = |base: &Sim| -> Vec<(&'static str, u64)> {
        let mut s = base.clone();
        let new = burnt(&mut s, "put", key);
        let over = burnt(&mut s, "put", key);
        let get = burnt(&mut s, "get", key);
        let has = burnt(&mut s, "has", key);
        let del = burnt(&mut s, "del", key);
        vec![("put (new key)", new), ("put (overwrite)", over), ("get", get), ("has", has), ("del", del)]
    };
    let (a, b) = (measure(&shallow), measure(&deep));
    let mut nodes = Vec::new();
    for ((op, x), (_, y)) in a.iter().zip(&b) {
        let d = y.checked_sub(*x).unwrap_or_else(|| panic!("{op}: deep {y} < shallow {x}"));
        assert_eq!(d % TTN, 0, "{op}: the difference {d} is not a whole number of trie nodes");
        println!("{op:16} shallow {x:>15} gas, deep {y:>15} gas: {} more trie nodes", d / TTN);
        nodes.push(d / TTN);
    }
    // put (new key), put (overwrite), del: about one node per sibling; get, has: none.
    assert_eq!(nodes, [16, 15, 0, 0, 15]);
}

/// A key the same receipt already wrote costs no trie nodes the second time
/// (the lookup finds it in the pending changes, `core/store/src/trie/update.rs:126-128`):
/// two writes of one key in one receipt cost the same in a shallow and a
/// deep trie beyond the first write's nodes. Shown with a batch of two `put`
/// calls on one receipt: the second sees the first's change.
#[test]
fn trie_nodes_not_charged_twice_in_a_receipt() {
    let key = b"k0123456";
    let mut shallow = world();
    burnt(&mut shallow, "put", b"seed");
    let mut deep = shallow.clone();
    for k in siblings(key) {
        burnt(&mut deep, "put", &k);
    }
    let two = |s: &Sim| -> u64 {
        let mut s = s.clone();
        let o = s
            .tx(ALICE, W)
            .call("put")
            .args(key.to_vec())
            .call("put")
            .args(key.to_vec())
            .transact();
        let r = o.first_call().unwrap();
        assert!(r.is_success(), "{o}");
        r.gas_burnt.as_gas()
    };
    let (x, y) = (two(&shallow), two(&deep));
    println!("two puts of one key in one receipt: shallow {x} gas, deep {y} gas: {} more trie nodes", (y - x) / TTN);
    assert_eq!(y - x, 16 * TTN, "only the first write pays the deeper path");
}

const R: &str = "r-read.near";

/// `go_full`, `go_len`, `go_none`: call `big` on this account with the
/// input, which returns it, then a callback that gets the result with
/// `promise_result` and reads it into memory (`cb_full`), takes only its
/// length (`cb_len`, what a bounded read of a too-long result does), or
/// neither (`cb_none`).
const READ: &str = r#"
(module
  (import "env" "input" (func $input (param i64)))
  (import "env" "register_len" (func $register_len (param i64) (result i64)))
  (import "env" "read_register" (func $read_register (param i64 i64)))
  (import "env" "value_return" (func $value_return (param i64 i64)))
  (import "env" "promise_create" (func $create (param i64 i64 i64 i64 i64 i64 i64 i64) (result i64)))
  (import "env" "promise_then" (func $then (param i64 i64 i64 i64 i64 i64 i64 i64 i64) (result i64)))
  (import "env" "promise_result" (func $result (param i64 i64) (result i64)))
  (memory 128)
  (export "memory" (memory 0))
  (data (i32.const 0) "r-read.near")
  (data (i32.const 32) "big")
  (data (i32.const 48) "cb_full")
  (data (i32.const 64) "cb_len")
  (data (i32.const 80) "cb_none")
  ;; the input, read to offset 4096; returns its length
  (func $payload (result i64)
    (call $input (i64.const 0))
    (call $read_register (i64.const 0) (i64.const 4096))
    (call $register_len (i64.const 0)))
  (func (export "big") (call $value_return (call $payload) (i64.const 4096)))
  ;; big(input) with 150 Tgas, then the callback at $m ($mlen bytes) with 20 Tgas
  (func $go (param $m i64) (param $mlen i64)
    (local $n i64)
    (local.set $n (call $payload))
    (drop (call $then
      (call $create (i64.const 11) (i64.const 0) (i64.const 3) (i64.const 32)
                    (local.get $n) (i64.const 4096) (i64.const 128) (i64.const 150000000000000))
      (i64.const 11) (i64.const 0) (local.get $mlen) (local.get $m)
      (i64.const 0) (i64.const 0) (i64.const 128) (i64.const 20000000000000))))
  (func (export "go_full") (call $go (i64.const 48) (i64.const 7)))
  (func (export "go_len") (call $go (i64.const 64) (i64.const 6)))
  (func (export "go_none") (call $go (i64.const 80) (i64.const 7)))
  (func (export "cb_full")
    (drop (call $result (i64.const 0) (i64.const 1)))
    (call $read_register (i64.const 1) (i64.const 4096)))
  (func (export "cb_len")
    (drop (call $result (i64.const 0) (i64.const 1)))
    (drop (call $register_len (i64.const 1))))
  (func (export "cb_none")
    (drop (call $result (i64.const 0) (i64.const 1)))))
"#;

/// Reading a promise result costs `read_register_byte` + `write_memory_byte`
/// (98,562 + 2,723,772 = 2,822,334 gas) per byte at 88, and getting it
/// (`promise_result`) nothing per byte: a callback that reads a result of
/// `n` bytes burns `2,822,334 n` more, plus fixed costs, than one that takes
/// only its length, and that one burns the same at every size, as does one
/// that only gets it (`runtime/near-vm-runner/src/logic/host.rs:4616-4646`,
/// `promise_result` with `set_rc_data`, `runtime/near-vm-runner/src/logic/vmstate.rs:87-121`;
/// `host.rs:407-417` and `:201-210`, `read_register` and `write_memory`).
#[test]
fn result_read_gas_per_byte() {
    const PER_BYTE: u64 = 98_562 + 2_723_772;
    let base = Fixture::new()
        .account(ALICE, Balance::from_near(1000))
        .contract(R, wat::parse_str(READ).unwrap())
        .build();
    let cb = |go: &str, n: usize| -> u64 {
        let mut s = base.clone();
        let o = s.tx(ALICE, R).call(go).args(vec![b'x'; n]).gas(Gas::from_teragas(300)).transact();
        let r = o
            .receipts
            .iter()
            .find(|r| r.method_names.iter().any(|m| m.starts_with("cb_")))
            .unwrap_or_else(|| panic!("no callback: {o}"));
        assert!(r.is_success(), "{o}");
        r.gas_burnt.as_gas()
    };
    let sizes = [1_000usize, 100_000, 1_000_000];
    let mut prev: Option<(usize, u64)> = None;
    for n in sizes {
        let (full, len, none) = (cb("go_full", n), cb("go_len", n), cb("go_none", n));
        println!("result of {n:>9} bytes: callback reads it {full:>15} gas, takes its length {len:>15}, gets it {none:>15}");
        assert_eq!(len, cb("go_len", sizes[0]), "taking the length does not depend on the size");
        assert_eq!(none, cb("go_none", sizes[0]), "promise_result does not depend on the size");
        if let Some((m, d)) = prev {
            let slope = (full - len - d) / (n - m) as u64;
            assert_eq!((full - len - d) % (n - m) as u64, 0);
            println!("  read cost per byte between {m} and {n} bytes: {slope} gas");
            assert_eq!(slope, PER_BYTE);
        }
        prev = Some((n, full - len));
    }
}
