----------------------------- MODULE NearAsync -----------------------------
(***************************************************************************)
(* NEAR receipt-execution semantics, with gas either abstract ("fault") or *)
(* a bounded quantity ("gas").  A contract model EXTENDS this module,      *)
(* supplies handlers that return an outcome record, and runs them with     *)
(* Exec (or Commit / FailP / FailOOG directly).                            *)
(*                                                                         *)
(* nearcore citations are `path:line` at the reference revision b7b4737    *)
(* (2.14.0-rc.5); see docs/SEMANTICS.md.                                   *)
(*                                                                         *)
(* Semantics                                                               *)
(*  - One atomic step per receipt execution.                               *)
(*  - A failed receipt (panic, action error, out of gas) reverts only its  *)
(*    own state and its own emitted receipts                               *)
(*    (runtime/runtime/src/lib.rs:535-541 set_error, :1078-1088 rollback); *)
(*    earlier receipts of the same transaction stay committed.  Its        *)
(*    attached deposit is refunded by a separate refund receipt to the     *)
(*    refund account: the predecessor unless `refund_to` was set           *)
(*    (lib.rs:1303, :1402-1406; core/primitives/src/receipt.rs:428-430).   *)
(*    A waiting callback gets a Failed data receipt (lib.rs:1172-1176).    *)
(*  - Callbacks always run: a postponed receipt runs when its input data   *)
(*    arrives, Successful or Failed (lib.rs:1449-1493, :1708; a missing    *)
(*    value is PromiseResult::Failed, lib.rs:895).                         *)
(*  - Joint callbacks (promise_and(..).then, AndThen) wait on several      *)
(*    inputs and see their results in promise_and order (lib.rs:861-899).  *)
(*  - Yields (promise_yield_create, YieldRcpt) wait on one resume          *)
(*    (OResume) or time out with Failed (lib.rs:1554-1622, :3113-3221);    *)
(*    the block height blk is advanced by BlockTick.                       *)
(*  - Data receipts are separate in-flight objects: anything may           *)
(*    interleave between a receipt's commit and its callback.              *)
(*  - Returning a promise forwards the caller's output receivers to the    *)
(*    returned receipt (lib.rs:1152-1168); the contract wires              *)
(*    `tail.cb := r.cb`.                                                   *)
(*  - The transaction signer is inherited by every receipt of the tree     *)
(*    (runtime/runtime/src/function_call.rs:172-174) and exposed to the    *)
(*    contract next to the predecessor (function_call.rs:259-262).         *)
(*  - Delegate actions (NEP-366) are a receipt kind here (DELEG) and run   *)
(*    in NearKeys (ExecDelegate): the relayer's transaction tree, so the   *)
(*    inner call's signer is the relayer, its predecessor the user.        *)
(*  - Local receipts: a transaction whose signer is its receiver produces  *)
(*    a local receipt, executed in the same chunk before delayed and       *)
(*    incoming receipts (lib.rs:2316-2324, :2800-2821).  Receipts created  *)
(*    by a receipt (self-calls included) are outgoing and run in a later   *)
(*    chunk (lib.rs:1222-1234).  See LocalPriorityOK.                      *)
(*  - Account types (named / NEAR-implicit / eth-implicit): a Transfer to  *)
(*    a missing implicit account creates it; to a missing named account it *)
(*    fails and refunds (runtime/runtime/src/actions.rs:842-850,           *)
(*    :929-946, :221-290).  Refunds never create accounts (:930-933); a    *)
(*    refund to a missing account is burnt (lib.rs:1046-1054, `burnt`).    *)
(*  - A function call to a missing account, or to one without code (see    *)
(*    Contracts), fails before any code runs (actions.rs:874-887;          *)
(*    function_call.rs:309-312).                                           *)
(*  - Native NEAR: liquid per account, plus locked / proposal for one      *)
(*    staking account.  Stake failures follow actions.rs:58-109; only the  *)
(*    account itself may stake (actions.rs:755-801).  The storage check    *)
(*    after a receipt uses liquid + locked (verifier.rs:48-84): against a  *)
(*    fixed StorageFloor, or per byte (StoragePerByte, stor).              *)
(*                                                                         *)
(* Gas.  The constant GasMode selects:                                     *)
(*  "fault"  gas is abstract: only the forced-fault switch (MayFail /      *)
(*           MaxFails) can fail a receipt for gas.                         *)
(*  "gas"    gas is a bounded quantity in Ggas (1 Tgas = 1000 Ggas):       *)
(*    * a transaction's first receipt carries the prepaid gas (WithGas);   *)
(*    * every function-call action of a receipt carries its own gas        *)
(*      (r.g, a sequence; a batch has several), static part r.gs and       *)
(*      unused-gas weight r.gw, set by the creating handler (defaults from *)
(*      GasCall, overridable per child);                                   *)
(*    * executing r needs                                                  *)
(*         Need = Burn(key, size) + SUM over created children c of         *)
(*                (c.gf + SUM c.gs)                                        *)
(*      Burn is the contract's calibrated per-(method, path) burn, affine  *)
(*      in a size; c.gf is the gas the child costs its creator besides its *)
(*      static gas.  Function-call children: c.gf = the child's prepaid    *)
(*      exec fee (GasCall[..].fee); their send fees are in the creator's   *)
(*      burn.  Action-only children (Transfer, Stake, key actions): c.gf = *)
(*      send + exec fee of the receipt base and its action from NearFees,  *)
(*      receiver-type dependent, because both are charged to the creating  *)
(*      receipt                                                            *)
(*      (runtime/near-vm-runner/src/logic/host.rs:3621-3661;               *)
(*      core/parameters/src/cost.rs:774-848).  Need is nearcore's gas_used *)
(*      at the end of the call.                                            *)
(*    * Need > attached gas  =>  the receipt runs out of gas, with the     *)
(*      same revert scope as any failure.  This also covers "gas checked   *)
(*      at promise creation": nothing the receipt would create exists.     *)
(*    * otherwise U = attached - Need is split over the children's         *)
(*      function-call actions with weight > 0: each gets floor(U*w/W);     *)
(*      W = 0 distributes nothing (runtime/runtime/src/receipt_manager.rs: *)
(*      414, :679-721).  nearcore also gives the last weighted action the  *)
(*      remainder, in gas units.  Under NearFees.FeeRounding = "up" (the   *)
(*      default) the model drops its whole-Ggas remainder, so every share  *)
(*      is a lower bound of nearcore's where the model's U is (see Share   *)
(*      for the premises); under "nearest" the last action in creation    *)
(*      order gets it.                                                     *)
(*    * a receipt with several function-call actions may give per-action   *)
(*      accounting in the outcome (`pa`): each action's leftover is split  *)
(*      over the children it created (function_call.rs:61, :343-345);      *)
(*      without `pa` the whole receipt is one action.                      *)
(*    * a created function call left with 0 gas fails the creating receipt *)
(*      (action_validation.rs:350-351, applied at lib.rs:968-978).  Under  *)
(*      "up" the model cannot always tell 0 gas from a little: it then     *)
(*      keeps both outcomes (ZeroGasKid, ZeroGasMaybe; Verdict "either").  *)
(*    * a panic is labelled out-of-gas when its explicit panic-path burn   *)
(*      (OPanicKey) plus the children created before it exceeds the        *)
(*      attached gas (gas_counter.rs:136-141, :155-174, :205-213).         *)
(*    * action-only receipts never run out of gas.                         *)
(*    * opt-in (TrieGasWorst): a storage write or remove the outcome       *)
(*      declares (OWriteKey) may also cost its worst-case trie-node gas;   *)
(*      Exec takes both (docs/SEMANTICS.md, G6).                           *)
(*  The forced switch is kept in both modes: a receipt whose method is in  *)
(*  MayFail may fail, at most MaxFails times; counted in `fails`.  A real  *)
(*  out-of-gas is recorded in `oog`.                                       *)
(*                                                                         *)
(* Account actions (CreateAccount, DeleteAccount, DeployContract) run in   *)
(* ACCOUNT receipts (ExecAcct) or with a call (HasAc, Exec): see          *)
(* "Account lifecycle" below (docs/SEMANTICS.md A6-A9).  A lone            *)
(* DeleteAccount created by a receipt is instant (InstantFirst, S5).       *)
(* Global contracts (DeployGlobalContract, UseGlobalContract, NEP-591)     *)
(* run the same way; a deploy publishes through a distribution receipt     *)
(* (GDIST, ExecGDist) and users resolve a by-account contract when each    *)
(* receipt runs (A10).                                                     *)
(*                                                                         *)
(* What is not modelled is listed in docs/SEMANTICS.md, "Not modelled":    *)
(* among others congestion (a local receipt that does not fit the chunk's  *)
(* compute limit is delayed, lib.rs:2513-2521), gas price and gas refunds  *)
(* in NEAR, cross-shard distribution of global contracts, gas keys, and    *)
(* one receipt feeding several callbacks (cb is one id).                   *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences, TLC

\* The fee table, as a named instance so its helper names do not enter the
\* models' namespace.  A model that wants the fee operators unqualified can
\* EXTENDS NearFees itself.
NearFeeTable == INSTANCE NearFees

\* The fee table's self-checks (NearFees, "Self-checks"), including that
\* FeeRounding is "nearest" or "up". TLC ignores the ASSUMEs of an INSTANCEd
\* module, so NearFees' own ASSUME never runs here; this one does, with the
\* run's FeeRounding and FeeProtocol.
ASSUME NearFeeTable!FeeSelfChecks

CONSTANTS
    Accounts,        \* all accounts that hold native NEAR in the model
    StakingAcct,     \* the one account that stakes
    MinStake,        \* epoch_info_provider.minimum_stake (scaled)
    StorageFloor,    \* [Accounts -> Nat]: liquid that must remain (LackBalanceForState)
    MayFail,         \* forced-fault switch: methods whose receipt may fail nondeterministically
    MaxFails,        \* bound on forced failures per behaviour
    MaxEpoch,        \* bound on epoch ticks
    MaxReward,       \* max reward per epoch tick
    Exists,          \* accounts that exist initially
    GasMode,         \* "fault" | "gas"
    GasCall,         \* [key -> [st |-> Seq(Nat), wt |-> Seq(Nat), fee |-> Nat]]
                     \*   defaults for a receipt that calls key ("acct.method" or "method")
    GasBurn,         \* [key -> [base |-> Nat, per |-> Nat]]; burn = base + per * size (Ggas, size in KB)
    LogOn            \* keep the per-receipt outcome log `rlog` (conformance runs)

VARIABLES
    rq,        \* set of ready (non-postponed) action receipts
    post,      \* set of postponed callback receipts (each waits on InIds; a yield also on its timeout)
    data,      \* set of in-flight data receipts [to, ok, v, sz, len, tx]
    near,      \* [Accounts -> Nat] liquid balance
    locked,    \* locked balance of StakingAcct
    proposal,  \* latest stake proposal of StakingAcct
    epoch,     \* current epoch height
    nid,       \* next receipt id
    fails,     \* number of FORCED failures so far
    paid,      \* ghost: [tx -> [Accounts -> Nat]] native NEAR credited by transfer/refund receipts
    minted,    \* ghost: total epoch rewards created
    oog,       \* ghost: set of <<tx, method>> that ran out of their real gas
    rlog,      \* ghost: per-receipt outcomes (only if LogOn)
    txsig,     \* [tx -> [a |-> signer account, k |-> signer key id]], set by Submit
    created,   \* accounts created at run time (implicit-account Transfer)
    burnt,     \* ghost: NEAR burnt by refunds to missing accounts
    blk,       \* block height, env::block_height() (BlockTick); stays 0 unless MaxBlk > 0
    stor,      \* [Accounts -> Int] storage usage in bytes; stays StorageInit unless StoragePerByte
    deleted,   \* accounts deleted by DeleteAccount and not created again since
    code,      \* code deployed at run time: a partial function account -> code tag (CodeOf)
    gcode,     \* published global contracts: a partial function identifier -> code tag (A10)
    guse,      \* accounts on a global contract: a partial function account -> identifier
    gnonce,    \* per identifier, the nonce of the last distribution applied (absent: 0)
    ofail      \* ghost: failed receipts the model marked owed or detached (OwedOK, DetachedVoided); with TrieGasWorst also unmarked ones (k = {})
\* Every platform variable must be initialised: use PlatformInit /
\* PlatformInitStaked, or conjoin PlatformInitExtra to an older Init.  TLC's
\* "current state is not a legal state" on the initial state, with a
\* platform variable such as txsig, blk, stor, deleted, code or gcode shown as null,
\* means PlatformInitExtra (or its parts PlatformInitSigner /
\* PlatformInitAccounts / PlatformInitClock / PlatformInitStorage) is missing.

platformVars == <<rq, post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog, rlog,
                  txsig, created, burnt, blk, stor, deleted, code, gcode, guse, gnonce, ofail>>

----------------------------------------------------------------------------
(* Overridable definitions.  Override in the cfg with `Name <- MyDef`      *)
(* (or a [run.constants] entry); the defaults keep the behaviour of models *)
(* that do not mention them.                                               *)

\* Accounts with deployed code.  A function call to an account outside this
\* set, or to a missing account, fails.  Default: every account has code.
Contracts == Accounts

\* TRUE: a function call fails unless its receiver exists and has code
\* (actions.rs:874-879 AccountDoesNotExist; function_call.rs:309-312
\* CodeDoesNotExist).  FALSE: calls run whatever the receiver (older models).
CallsNeedCode == TRUE

\* TRUE: Submit records the transaction's signer in txsig (needed by SignerOf,
\* Signer, SignerKey and NearKeys).  Settled transactions keep their entry, so
\* a model that never reads the signer pays for it in states (up to about 17%
\* in measured models); TrackSigner <- FALSE leaves txsig unchanged.  Reading
\* the signer with FALSE is a TLC error, not a wrong value.
TrackSigner == TRUE

\* TRUE: a refund to a missing account is burnt (lib.rs:1046-1054).  FALSE:
\* it stays pending (older models).
BurnLostRefunds == TRUE

\* Gas mode: a receipt with several function calls (Len(r.g) > 1) whose
\* outcome has no pa would pool their gas, unlike nearcore (function_call.rs:61).
\* FALSE: that is an Assert.  TRUE: pool silently (older models).
PooledGasOK == FALSE

\* Account type by id pattern: "named", "near_implicit" (64 hex chars),
\* "eth_implicit" ("0x" + 40 hex chars), "deterministic" ("0s" + 40 hex) or
\* "universal" ("0u" + 52 base32).  Toy ids cannot match the real patterns,
\* so the model states the type.  Default: every account is named.
AcctKind == [a \in Accounts |-> "named"]
\* Helper for overrides: AcctKind <- MyKinds, MyKinds == AcctKinds({"0xe"}, {}).
AcctKinds(eth, nearImp) ==
    [a \in Accounts |-> IF a \in eth THEN "eth_implicit"
                        ELSE IF a \in nearImp THEN "near_implicit" ELSE "named"]
KindOf(a) == IF a \in DOMAIN AcctKind THEN AcctKind[a] ELSE "named"
\* Kinds a Transfer may create (actions.rs:929-946): NEAR-implicit,
\* eth-implicit and deterministic accounts when the Transfer is the receipt's
\* only action; universal accounts (from protocol 87) also inside a batch.
\* A refund never creates an account.  The model's Transfer receipts are
\* single-action, so all of them qualify.
\* UniversalOn: universal accounts exist (the protocol-87 `universal_accounts`
\* feature, core/primitives-core/src/version.rs:639).  A behaviour switch,
\* independent of NearFees.FeeProtocol (which selects fees only): TRUE is the
\* pinned protocol 88's rule.  Overridable (`UniversalOn <- FALSE` for the
\* rules before 87, where a universal id is an ordinary named id:
\* get_account_type, runtime/runtime/src/actions.rs:918-924).
UniversalOn == TRUE
IsImplicit(a) ==
    \/ KindOf(a) \in {"near_implicit", "eth_implicit", "deterministic"}
    \/ KindOf(a) = "universal" /\ UniversalOn
\* An uninitialised universal account: created by a Transfer and waiting for
\* its state init (actions.rs:276-282).  Every action but a Transfer fails on
\* it with AccountNotInitialized (:880-887).  Without UniversalOn a 0u id is
\* named, and an account with it is an ordinary one.
UninitUniversal(a) == UniversalOn /\ KindOf(a) = "universal" /\ a \in created

\* Key id used by Submit(r), which carries no key information.
DefaultKey == "default"

\* Block clock and yield timeouts.  blk is env::block_height(), advanced only
\* by BlockTick, which a model adds to its Next.
\* MaxBlk: bound on blk; 0 = no clock (blk stays 0).  A bound, not an
\* abstraction: behaviours that need a later height are not explored (an
\* under-approximation for a model that reads blk; see ClockHorizonOK).
\* YieldTicks: a yield's timeout in ticks.  nearcore: the creating receipt's
\* block height + yield_timeout_length_in_blocks (200 at protocol 88,
\* runtime/runtime/src/function_call.rs:160-170;
\* core/parameters/res/runtime_configs/parameters.yaml:320).
\* With the defaults every pending yield may time out at any moment.
\* TickAnytime: TRUE lets BlockTick run whenever blk < MaxBlk.  FALSE only
\* while some yield's deadline is ahead: fewer states, but exact only for a
\* model whose handlers never read blk or BlockTs.
\* TsOf(h): env::block_timestamp() at height h, in model units; any strictly
\* increasing function (nearcore timestamps increase per block, not by a
\* fixed step).
MaxBlk      == 0
YieldTicks  == 0
TickAnytime == TRUE
TsOf(h)     == h

\* Storage staking (docs/SEMANTICS.md, B2).  After a receipt's actions
\* succeed, nearcore requires the receiver's liquid + locked to cover
\* storage_usage x storage_amount_per_byte, and otherwise fails the whole
\* receipt with LackBalanceForState (runtime/runtime/src/lib.rs:1008-1031;
\* check_storage_stake, runtime/runtime/src/verifier.rs:48-84).  Two
\* encodings of that one check:
\*  StoragePerByte = FALSE (the default, the 0.1.0 rule): liquid + locked
\*    must cover the fixed StorageFloor[a] after a function call.  stor
\*    stays StorageInit and outcome byte deltas (OStor) are ignored.
\*  StoragePerByte = TRUE: stor[a] is a's storage usage in bytes, which the
\*    library keeps (OStor deltas, AddKey / DeleteKey, implicit-account
\*    creation).  Liquid + locked must cover stor[a] bytes at
\*    StorageByteCost unless stor[a] <= ZeroBalanceBytes (NEP-448 zero-
\*    balance accounts, verifier.rs:25, :77-79, :88-90).  StorageFloor is
\*    not checked: it encodes the same rule.  A transaction whose deposit
\*    would leave its signer uncovered cannot be submitted (CanSubmit).
\* StorageInit: bytes per account at the start (domain Accounts).  With
\*   StoragePerByte give each account its real usage: the account record,
\*   keys, code and data.  Every entry at or below 770 bytes is exempt.
\* StorageByteCost = <<num, den>>: one byte costs num/den model NEAR units.
\*   nearcore: 1e19 yocto per byte at 88
\*   (core/parameters/res/runtime_configs/parameters.yaml:35), so <<1, 100000>>
\*   when 1 unit = 1 NEAR and <<1, 100>> when 1 unit = 1 milliNEAR.  The
\*   comparison is exact (bal * den >= bytes * num): keep both products
\*   below 2^31.
StoragePerByte   == FALSE
StorageInit      == [a \in Accounts |-> 0]
StorageByteCost  == <<1, 100000>>
ZeroBalanceBytes == 770
\* Byte counts (core/parameters/res/runtime_configs/parameters.yaml:36-37).
AccountBytes     == 100   \* storage_num_bytes_account: an account record
RecordExtraBytes == 40    \* storage_num_extra_bytes_record: per trie record
\* storage_write of a new key adds key + value + 40 bytes; an overwrite adds
\* len(new) - len(old); storage_remove frees key + value + 40
\* (runtime/near-vm-runner/src/logic/host.rs:5041-5070, :5198-5208).
RecordBytes(k, v) == k + v + RecordExtraBytes
\* A full-access ed25519 key: its 33-byte trie id, the borsh AccessKey
\* (nonce 8 + permission tag 1) and 40 (runtime/runtime/src/access_keys.rs:17-29;
\* core/crypto/src/signature.rs:332-338).
FullKeyBytes == 33 + 9 + RecordExtraBytes
\* An account created by a Transfer (actions.rs:221-288): NEAR-implicit 100
\* + its full-access key (182); eth-implicit 100 + the 32-byte global
\* contract hash (132); deterministic and universal 100.  All are exempt.
CreatedBytes(a) == CASE KindOf(a) = "near_implicit" -> AccountBytes + FullKeyBytes
                     [] KindOf(a) = "eth_implicit"  -> AccountBytes + 32
                     [] OTHER                       -> AccountBytes

----------------------------------------------------------------------------
(* Promise results.  A callback sees r.res = [ok, v, sz, len]:             *)
(*   ok = FALSE           Failed                                           *)
(*   v >= 0               Successful, a well-formed JSON number            *)
(*   v = EMPTY            Successful, empty bytes (Transfer, `()` return)  *)
(*   v = MAL              Successful, malformed / unparsable bytes         *)
(*   v = NONEMPTY         Successful, other bytes (a JSON object, null...) *)
(*   v = NOPR             the receipt has no promise results at all        *)
(*                        (promise_results_count() = 0,                    *)
(*                        runtime/near-vm-runner/src/logic/host.rs:4583)   *)
(*   sz                   result size in KB (rounded up); 0 when unknown   *)
(*   len                  result size in bytes; 0 when not stated (then    *)
(*                        sz is all the model knows)                       *)
EMPTY    == -1
MAL      == -2
NONEMPTY == -3
NOPR     == -4

NoRes == [ok |-> TRUE, v |-> NOPR, sz |-> 0, len |-> 0]

IsNum(res)    == res.ok /\ res.v >= 0
IsEmpty(res)  == res.ok /\ res.v = EMPTY
IsFailed(res) == ~res.ok
NoResults(res) == res.ok /\ res.v = NOPR
\* The "parse a U128 or fall back" pattern: Failed or not a number => dflt.
NumOr(res, dflt) == IF IsNum(res) THEN res.v ELSE dflt
\* Bounded reads.  near-sdk's env::promise_result_checked(idx, max_len) fails
\* with PromiseError::TooLong when the result is longer than max_len bytes
\* (read_register_bounded: `len > max_len`; near-sdk 5.28.1
\* src/environment/env.rs:129-137, :1833-1837, as read).  ResMinBytes is the
\* smallest byte length the record allows: len when stated, else what sz
\* implies (n KB, rounded up, is at least 1000 * (n - 1) + 1 bytes, so
\* sz = 1 is at least 1 byte; sz = 0 says nothing).  max < 0 means an
\* unbounded read.
ResMinBytes(res) ==
    IF "len" \in DOMAIN res /\ res.len > 0 THEN res.len
    ELSE IF res.sz > 0 THEN 1000 * (res.sz - 1) + 1
    ELSE 0
ResTooLong(res, max) == res.ok /\ max >= 0 /\ ResMinBytes(res) > max
\* NumOr after a bounded read: a too-long result counts as unparsable.
NumOrChecked(res, max, dflt) == IF ResTooLong(res, max) THEN dflt ELSE NumOr(res, dflt)
\* Result-read gas (docs/SEMANTICS.md, C4).  promise_result puts the result
\* in a register without a per-byte charge; reading it into memory costs
\* read_register_byte + write_memory_byte = 2,822,334 gas per byte (88),
\* which a bounded read of a too-long result skips (register_len first).
\* OReadRes(O, res, max) declares that the call reads res with bound max
\* bytes (max < 0: unbounded), so Need adds ReadGas(O): the bytes read
\* (ResMaxBytes, the most the record allows; none when Failed or too long;
\* at most max) at 2823 Kgas per byte, rounded up to whole Ggas.  Only the
\* host's copy: parsing the bytes is the contract's burn (GasBurn per with
\* OSz).  The calibrated burn already holds the read of the measured result,
\* so a stated small result is counted twice, by a Ggas or so.
\* ResultReadGas <- FALSE drops the charge.  Not on a panic path, nor per
\* action (pa).
ResultReadGas == TRUE
ResMaxBytes(res) == IF "len" \in DOMAIN res /\ res.len > 0 THEN res.len ELSE 1000 * res.sz
ResReadBytes(res, max) ==
    IF ~res.ok \/ ResTooLong(res, max) THEN 0
    ELSE IF max >= 0 /\ ResMaxBytes(res) > max THEN max
    ELSE ResMaxBytes(res)
ReadBytes(O) == IF "rdb" \in DOMAIN O THEN O.rdb ELSE 0
OReadRes(O, res, max) == [rdb |-> ReadBytes(O) + ResReadBytes(res, max)] @@ O
\* Ggas; below 700,000 bytes per byte (2823 Kgas), above per KB (2823 Mgas),
\* to stay within TLC's integers.
ReadGas(O) ==
    LET b == ReadBytes(O) IN
    IF ~ResultReadGas \/ b = 0 THEN 0
    ELSE IF b <= 700000 THEN (b * 2823 + 999999) \div 1000000
    ELSE (((b + 999) \div 1000) * 2823 + 999) \div 1000

\* Built-in (non function-call) receipt kinds.
XFER  == "XFER"     \* Transfer action (may carry a callback)
REFND == "REFUND"   \* system refund receipt
STAKE == "STAKE"    \* Stake action on StakingAcct; a.x1 = amount
ADDK  == "ADDKEY"   \* AddKey action (executed by NearKeys)
DELK  == "DELKEY"   \* DeleteKey action (executed by NearKeys)
DELEG == "DELEGATE" \* Delegate action, NEP-366 (executed by NearKeys.ExecDelegate)
ACCT  == "ACCOUNT"  \* CreateAccount / DeleteAccount, with Transfer and AddKey (ExecAcct, NearKeys.ExecAcctK)
GDIST == "GDIST"    \* global contract distribution (A10; ExecGDist);
                    \* a = [g |-> identifier, t |-> code tag]
IsBuiltin(r) == r.m \in {XFER, REFND, STAKE, GDIST}
IsKeyRcpt(r) == r.m \in {ADDK, DELK}
IsDeleg(r)   == r.m = DELEG
IsAcctRcpt(r) == r.m = ACCT
\* A function-call receipt (the rest).
IsCall(r)    == ~IsBuiltin(r) /\ ~IsKeyRcpt(r) /\ ~IsDeleg(r) /\ ~IsAcctRcpt(r)

----------------------------------------------------------------------------
(* Receipt records.  All receipts have the same fields.                    *)
(*   id tx to fr m a dep rto cb   id, transaction, receiver, predecessor,  *)
(*                                method, args, deposit, refund account,   *)
(*                                callback id waiting on the output (0: none)*)
(*   res                          promise result (callbacks), else NoRes   *)
(*   gs gw g gf                   gas: static / weight / attached per call,*)
(*                                and the creator-side fee                 *)
(*   loc                          a local receipt (set by Submit)          *)
NoGas == [st |-> <<>>, wt |-> <<>>, fee |-> 0]
\* "acct.method" overrides "method", so two contracts can differ for a shared method name.
CallKey(to, m) == to \o "." \o m
HasCallDef(to, m) == CallKey(to, m) \in DOMAIN GasCall \/ m \in DOMAIN GasCall
CallDef2(to, m) == IF CallKey(to, m) \in DOMAIN GasCall THEN GasCall[CallKey(to, m)]
                   ELSE IF m \in DOMAIN GasCall THEN GasCall[m] ELSE NoGas
CallDef(m) == IF m \in DOMAIN GasCall THEN GasCall[m] ELSE NoGas

\* Gas an action-only child costs its creator: send + exec of the receipt
\* base and of its action, by the receiver's account type (NearFees).
XferFee(fr, to)  == NearFeeTable!TransferFeeTotal(fr = to, KindOf(to))
StakeFee(fr, to) == NearFeeTable!OneActionReceiptFee("stake", fr = to, KindOf(to))
BuiltinFee(fr, to, m) ==
    IF GasMode # "gas" THEN 0
    ELSE CASE m = XFER  -> XferFee(fr, to)
           [] m = STAKE -> StakeFee(fr, to)
           [] OTHER     -> 0
\* A GasCall entry for the receiver/method wins over the fee table.
DefaultFee(to, fr, m) ==
    IF HasCallDef(to, m) \/ m \notin {XFER, STAKE} THEN CallDef2(to, m).fee
    ELSE BuiltinFee(fr, to, m)

Rcpt(id, tx, to, fr, m, a, dep, rto, cb) ==
    LET d == CallDef2(to, m) IN
    [id |-> id, tx |-> tx, to |-> to, fr |-> fr, m |-> m, a |-> a,
     dep |-> dep, rto |-> rto, cb |-> cb, res |-> NoRes,
     gs |-> d.st, gw |-> d.wt, gf |-> DefaultFee(to, fr, m), g |-> <<>>, loc |-> FALSE]

\* Per-child overrides used by handlers.
WithStatic(r, s) == [r EXCEPT !.gs = s]          \* s: one static per function call
WithWeight(r, w) == [r EXCEPT !.gw = w]
WithCall(r, s, w) == [r EXCEPT !.gs = s, !.gw = w]
WithFee(r, f)    == [r EXCEPT !.gf = f]
WithGas(r, p)    == [r EXCEPT !.g = <<p>>]       \* a transaction's first receipt: prepaid gas

\* Owed and detached receipts (docs/SEMANTICS.md, F2).  A model marks the
\* receipts whose failure is a bug in itself, and the library records each
\* failure of a marked receipt, with its cause, in the ghost ofail (FailWhyL;
\* OwedOK and DetachedVoided below check it).  Unmarked receipts leave
\* ofail empty, so a model that marks nothing has the state space it had.
\*  owed      a callback the contract scheduled to complete or undo a state
\*            change an earlier receipt committed (a resolver, a rollback):
\*            it must not fail, whatever the cause.  nearcore does not retry
\*            or revert anything for it: a failed receipt reverts only its
\*            own state (runtime/runtime/src/lib.rs:535-541, :1078-1088), so
\*            the earlier commit stays and its completion is lost.
\*            WithOwed(c) marks one child receipt; OwedMethods (overridable,
\*            default {}) marks every postponed self-callback (r in post,
\*            r.fr = r.to) whose method m or key "acct.m" it lists.  The
\*            guard keeps a direct call of the same method (a user calling
\*            a private resolver, which panics) out of the check.
\*  detached  work the contract handed to a call (often one nothing waits
\*            on: a payout Transfer, a job): if that call fails, the work
\*            must not stay executable or credited once its transaction has
\*            settled (DetachedVoided).  WithDetached(c) marks one receipt
\*            of any kind (a Transfer too); DetachedMethods (overridable,
\*            default {}) marks every function call with that method or key.
\* A receipt may carry both marks; its ofail record then lists both (k), and
\* OwedOK and DetachedVoided each check it.
WithOwed(r)     == [owed |-> TRUE] @@ r
WithDetached(r) == [dtch |-> TRUE] @@ r
OwedMethods     == {}
DetachedMethods == {}

\* Joint promise: promise_and(ks).then(c).  ks: the input receipts in
\* promise_and order (built with any cb); c: the callback; d0: the first of
\* Len(ks) fresh ids, used as the data ids.  Returns the inputs wired to the
\* data ids (kids) and the callback waiting on them (cb).  nearcore makes one
\* callback receipt with one fresh data id per input and adds a data receiver
\* to each input (runtime/near-vm-runner/src/logic/host.rs:2486-2535
\* promise_and, :2605-2654 promise_batch_then; runtime/runtime/src/ext.rs:346-355;
\* runtime/runtime/src/receipt_manager.rs:112-140).  The handler puts the
\* kids in ready (or post) and the callback in post, and counts the Len(ks)
\* data ids in O.ids besides the receipt ids.
AndThen(ks, c, d0) ==
    [kids |-> [i \in DOMAIN ks |-> [ks[i] EXCEPT !.cb = d0 + i - 1]],
     cb   |-> [ins |-> [i \in DOMAIN ks |-> d0 + i - 1]] @@ c]

\* SeqSum(F, s): the sum of F(s[i]) over a sequence, halving the index range
\* (recursion depth log2 Len(s); one level per element would overflow a small
\* thread stack on long sequences, as RcptSum explains).
RECURSIVE SeqSumIn(_, _, _, _)
SeqSumIn(F(_), s, lo, hi) ==
    IF lo > hi THEN 0
    ELSE IF lo = hi THEN F(s[lo])
    ELSE LET mid == (lo + hi) \div 2 IN SeqSumIn(F, s, lo, mid) + SeqSumIn(F, s, mid + 1, hi)
SeqSum(F(_), s) == SeqSumIn(F, s, 1, Len(s))
SumSeq(s) == SeqSum(LAMBDA x : x, s)
GasOf(r)   == SumSeq(r.g)                                 \* attached gas, all function calls
LastGas(r) == IF r.g = <<>> THEN 0 ELSE r.g[Len(r.g)]     \* env::prepaid_gas() of the last call

\* Receipt kinds.  Two optional fields, absent on every receipt built by Rcpt
\* alone:
\*   ins  a joint callback, promise_and(..).then(..): the data ids it waits on,
\*        in promise_and order (AndThen).  A postponed receipt without ins
\*        waits on the one data id equal to its own id.
\*   ydl  a yield callback, promise_yield_create (YieldRcpt): the height from
\*        which it may time out.
IsJoint(p) == "ins" \in DOMAIN p
IsYield(p) == "ydl" \in DOMAIN p
\* The data ids a postponed receipt waits on.
InIds(p)   == IF IsJoint(p) THEN {p.ins[i] : i \in DOMAIN p.ins} ELSE {p.id}
\* A data receipt as the promise result it becomes.
DRes(d)    == [ok |-> d.ok, v |-> d.v, sz |-> d.sz, len |-> d.len]

\* A joint callback runs once, when the last of its inputs has arrived, in
\* whatever order they arrive (runtime/runtime/src/lib.rs:1646-1712 counts the
\* missing inputs; :1440-1530 runs the receipt when the count reaches 0).  Its
\* results are in input_data_ids order, which is promise_and order, and each
\* is Successful or Failed on its own (lib.rs:861-899).
Arrived(p)  == \A x \in InIds(p) : \E d \in data : d.to = x
JointRes(p) == [i \in DOMAIN p.ins |-> DRes(CHOOSE d \in data : d.to = p.ins[i])]
\* r.res of a joint callback: not a result.  Its ok = FALSE and v = JOINTRES
\* (not a number), so a handler written for one input that reads r.res takes
\* its Failed branch whatever the inputs were.  Read NRes / ResAt instead.
JOINTRES  == -5
JointMark == [ok |-> FALSE, v |-> JOINTRES, sz |-> 0, len |-> 0]

\* A yield callback runs with the first resume to arrive (one Runnable
\* variant per resume in flight; later ones are dropped,
\* runtime/runtime/src/lib.rs:1616-1622), or times out with Failed
\* (lib.rs:861-899).  The timeout fires in the first chunk whose height
\* reaches the deadline, or later (lib.rs:3113-3221, the test at :3146), and
\* its PromiseResume(None) is dropped if a resume was sent first
\* (lib.rs:1555-1563).  The model merges the timeout and its arrival into
\* one step, allowed while no resume is in flight: exact, since a resume sent
\* before the timeout's PromiseResume arrives wins in both.  At blk = MaxBlk
\* every pending yield may time out (so a deadline past the bound stays
\* reachable; YieldDeadlinesInBound reports it).
FailedRes   == [ok |-> FALSE, v |-> 0, sz |-> 0, len |-> 0]
TimedOut(p) == /\ IsYield(p)
               /\ ~\E d \in data : d.to = p.id
               /\ (blk >= p.ydl \/ blk >= MaxBlk)

\* Instant receipts (docs/SEMANTICS.md S5).  A receipt holding a single
\* DeleteAccount and no inputs, created by a receipt, runs right after its
\* creator in the same chunk, whatever the chunk's load, before any other
\* receipt, local ones included (core/primitives/src/receipt.rs:468-491;
\* runtime/runtime/src/lib.rs:1222-1224, :2747-2775, called for local,
\* delayed and incoming receipts alike at :2538, :2642, :2727).  So does a
\* delegate's inner receipt of that shape (sim: conformance/tests/
\* lifecycle.rs, instant_delete_via_delegate, also with a local creator).
\* A transaction's own first receipt is not instant, nor is the delete's
\* payout (a refund receipt), nor a DeleteAccount waiting on a callback's
\* inputs.  A joint callback with no inputs (AndThen(<<>>, c, d0).cb: an
\* empty promise_and, runtime/near-vm-runner/src/logic/host.rs:2486-2534,
\* then .then, :2631-2643) waits on nothing and is instant if c has the
\* shape: Commit tags it in post (InstantTagP), where it is runnable at
\* once.  (A yield receipt is instant too; the model puts the yield in post
\* at its creator's commit, which is the same.)
\* Commit and NearKeys.ExecDelegate tag such a receipt with the field inst
\* (InstantTag).  While one is pending (InstantPending), only tagged
\* receipts run (Runnable), and SubmitAs, BlockTick and EpochTick are
\* disabled: no transaction, block or epoch can come between a creator and
\* its delete.  A model conjoins ~InstantPending to its own steps that
\* change state outside receipts (a contract-side tick, a scripted step);
\* one that forgets only allows more interleavings.  Tagged receipts run in
\* any order among themselves (nearcore: creation order).
\* InstantFirst <- FALSE: no receipt is instant (the earlier behaviour, an
\* over-approximation: N-instant).
InstantFirst == TRUE
\* No code (CodeOf); the code a receipt with account actions deploys, if any
\* (WithDeploy; the optional field dpl of ac).
NoCode == ""
Dpl(r) == IF "dpl" \in DOMAIN r.ac THEN r.ac.dpl ELSE NoCode
\* Global contracts (A10): the code a receipt's DeployGlobalContract
\* publishes (WithDeployGlobal; ac.dg = [t |-> tag, md |-> "hash" | "acct"])
\* and the identifier its UseGlobalContract switches to (WithUseGlobal;
\* ac.ug), if any.
NoGid == <<>>
DgTag(r) == IF "dg" \in DOMAIN r.ac THEN r.ac.dg.t ELSE NoCode
Ug(r)    == IF "ug" \in DOMAIN r.ac THEN r.ac.ug ELSE NoGid
IsInstantShape(c) ==
    /\ IsAcctRcpt(c)
    /\ ~c.ac.mk /\ c.ac.bnf # "" /\ c.ac.ka = <<>> /\ Dpl(c) = NoCode /\ c.dep = 0
    /\ DgTag(c) = NoCode /\ Ug(c) = NoGid
InstantTag(c) == IF InstantFirst /\ IsInstantShape(c) THEN [inst |-> TRUE] @@ c ELSE c
\* For a postponed child: only a joint callback with no inputs.
InstantTagP(c) == IF IsJoint(c) /\ c.ins = <<>> THEN InstantTag(c) ELSE c
IsInstant(r) == "inst" \in DOMAIN r
InstantPending == InstantFirst /\ (\E y \in rq : IsInstant(y) \/ \E p \in post : IsInstant(p))

\* Receipts that can run now: ready ones; postponed ones whose data arrived
\* (a yield with its resume payload); joint callbacks whose inputs all
\* arrived, with rs = their results in order and res = JointMark; timed-out
\* yields, with Failed.  (No data is ever addressed to a joint callback's own
\* id: its data ids are fresh.)  While an instant receipt is pending, only
\* instant receipts (no timeout either).
RunnableAll ==
    rq \cup { [pd[1] EXCEPT !.res = [ok |-> pd[2].ok, v |-> pd[2].v, sz |-> pd[2].sz, len |-> pd[2].len]] :
                pd \in {xy \in post \X data : xy[2].to = xy[1].id} }
       \cup { [[rs |-> JointRes(p)] @@ p EXCEPT !.res = JointMark] :
                p \in {q \in post : IsJoint(q) /\ Arrived(q)} }
       \cup { [p EXCEPT !.res = FailedRes] : p \in {q \in post : TimedOut(q)} }
Runnable == IF InstantPending
            THEN {y \in rq : IsInstant(y)}
                 \cup {[[rs |-> JointRes(p)] @@ p EXCEPT !.res = JointMark] : p \in {q \in post : IsInstant(q)}}
            ELSE RunnableAll

\* The promise results as the handler sees them: promise_results_count()
\* (runtime/near-vm-runner/src/logic/host.rs:4583-4593) and promise_result(i - 1)
\* (host.rs:4616-4646), 1-based.  An index past the end is an Assert (nearcore:
\* InvalidPromiseResultIndex, a host error that fails the receipt).
NRes(r) == IF IsJoint(r) THEN Len(r.ins) ELSE IF NoResults(r.res) THEN 0 ELSE 1
ResAt(r, i) ==
    IF i \notin 1..NRes(r)
    THEN Assert(FALSE, <<"promise result index out of range", r.m, i, NRes(r)>>)
    ELSE IF IsJoint(r) THEN r.rs[i] ELSE r.res

RemR(r) == {x \in rq   : x.id # r.id}
RemP(r) == {x \in post : x.id # r.id}
\* A receipt consumes every data receipt addressed to it: all inputs of a
\* joint callback; every resume of a yield (the ones after the first are
\* dropped by nearcore, runtime/runtime/src/lib.rs:1616-1622).
RemD(r) == {d \in data : d.to \notin InIds(r)}

DataOfLen(r, ok, v, sz, len) ==
    IF r.cb = 0 THEN {} ELSE {[to |-> r.cb, ok |-> ok, v |-> v, sz |-> sz, len |-> len, tx |-> r.tx]}
DataOfSz(r, ok, v, sz) == DataOfLen(r, ok, v, sz, 0)
DataOf(r, ok, v) == DataOfSz(r, ok, v, 0)

\* The NEAR a receipt carries: its deposit r.dep plus, for a call receipt
\* with a CreateAccount (WithCreate), the Transfer before its call (ac.xfer),
\* which is not the call's attached deposit (function_call.rs:273).
XferOf(r)   == IF "ac" \in DOMAIN r /\ "xfer" \in DOMAIN r.ac THEN r.ac.xfer ELSE 0
DepTotal(r) == r.dep + XferOf(r)
\* The balance a handler sees at the start of r's call (env::account_balance):
\* the receiver's balance after the receipt's earlier actions (a new
\* account starts at 0; the batch's Transfer is credited by then,
\* actions.rs:159-160, function_call.rs:269) plus the call's attached deposit
\* (near-vm-runner logic.rs:45-49).  near[r.to] is the balance before the
\* receipt; a handler that reads its own balance reads BalSeen(r).
BalSeen(r) == (IF "ac" \in DOMAIN r /\ r.ac.mk THEN 0 ELSE near[r.to]) + DepTotal(r)
\* KeySum(F, K, S): the sum of F(x) over a set S, where K(x) is an integer
\* key (an id, or the value itself).  A sum that takes one element per
\* level recurses |S| deep, and with a few hundred elements that is past a
\* 512 KB thread stack (TLC's StackOverflowError; the default stack is
\* 1 MB on 64-bit Linux and macOS).  So a set of more than 16 is split in
\* two by one bit of the key, the lowest first: keys that are consecutive
\* ids split evenly at each level, and the depth stays below 16 + 30 x 2
\* whatever the keys are.  Elements that agree in key bits 0-29 (the same
\* key, in practice) are summed linearly.
RECURSIVE KeySumIn(_, _, _, _)
KeySumIn(F(_), K(_), S, p) ==
    IF Cardinality(S) <= 16 \/ p >= 1073741824
    THEN LET G[T \in SUBSET S] == IF T = {} THEN 0
                                  ELSE LET x == CHOOSE y \in T : TRUE IN F(x) + G[T \ {x}]
         IN G[S]
    ELSE KeySumIn(F, K, {x \in S : (K(x) \div p) % 2 = 0}, 2 * p)
         + KeySumIn(F, K, {x \in S : (K(x) \div p) % 2 = 1}, 2 * p)
KeySum(F(_), K(_), S) == KeySumIn(F, K, S, 1)
\* RcptSum(F, S): the sum of F(x) over a set of receipts S, split by id
\* (ids are unique integers).
RcptSum(F(_), S) == KeySum(F, LAMBDA x : x.id, S)
\* FunSum(f, S): the sum of f[x] over S (f integer-valued, S any set, e.g. of
\* account names), as the sum over f's distinct values v of v times the
\* number of x with f[x] = v: the values are integers, so KeySum splits them.
FunSum(f, S) ==
    KeySum(LAMBDA v : v * Cardinality({x \in S : f[x] = v}), LAMBDA v : v, {f[x] : x \in S})
Sum(S) == RcptSum(LAMBDA x : DepTotal(x), S)

\* Ids are unique, so Sum over a set of receipts is well defined.
InflightDeposits == Sum(rq) + Sum(post)

\* Account existence: initial accounts and accounts created at run time,
\* unless deleted since (DeleteAccount; a later creation removes the id
\* from deleted again).
AcctExists(a) == (a \in Exists \/ a \in created) /\ a \notin deleted
\* An account's code, as a tag ("code" names no particular contract; a model
\* that deploys picks its own tags): the code deployed at run time (the
\* platform variable code, DeployContract, A9), else InitCode[a] for an
\* account in Contracts.  An account created at run time has no code unless
\* it is eth-implicit: a Transfer gives that one the protocol's wallet
\* global contract (EthWalletCode), whether or not it is in Contracts
\* (actions.rs:255-268).  A universal account created by a
\* Transfer is also uninitialised (UninitUniversal; actions.rs:880-887,
\* AccountNotInitialized).  DeleteAccount drops the account's entry in code,
\* so an account created again starts with none.
\* InitCode (overridable): the initial accounts' code tags, default "code".
\* CodeLen (overridable): a code tag's length in bytes, default 0 (the bytes
\* a DeployContract adds and pays the per-byte fee for).
\* EthWalletCode (overridable): the tag of the protocol's eth wallet global
\* contract, which an eth-implicit account created at run time gets, also
\* when it is created again after a deletion, whatever its initial code
\* (actions.rs:255-268).
InitCode == [a \in Accounts |-> "code"]
CodeLen  == [t \in {} |-> 0]
EthWalletCode == "eth_wallet"
CodeLenOf(t) == IF t \in DOMAIN CodeLen THEN CodeLen[t] ELSE 0
\* Global contracts (NEP-591, A10).  An identifier is GHash(t), code t
\* published by its hash (a function of the tag), or GAcct(a), the code
\* account a last published under its own id.  gcode maps the published
\* identifiers to their code; guse[a] is the identifier account a runs.  A
\* by-account identifier is resolved when each receipt runs (lib.rs
\* :684-700), so a redeploy reaches every user, a callback in flight
\* included (sim: conformance/tests/global.rs, redeploy_updates_users,
\* update_while_callback_in_flight).  An identifier's storage bytes
\* (IdLen): 32 by hash, the owner id's length by account
\* (core/primitives-core/src/account.rs:182-188; toy ids give toy lengths).
\* InitGCode, InitUses (overridable): what is published, and which initial
\* accounts use it, at the start (default: nothing).  CodeOf reads code (run
\* time deploys), then guse, then InitCode: an account in InitUses runs its
\* global contract whatever its InitCode.
GHash(t) == <<"hash", t>>
GAcct(a) == <<"acct", a>>
IdLen(g) == IF g[1] = "hash" THEN 32 ELSE Len(g[2])
GCodeOf(g) == IF g \in DOMAIN gcode THEN gcode[g] ELSE NoCode
InitGCode == [g \in {} |-> NoCode]
InitUses  == [a \in {} |-> NoGid]
CodeOf(a) ==
    IF a \in DOMAIN code THEN code[a]
    ELSE IF a \in DOMAIN guse THEN GCodeOf(guse[a])
    ELSE IF a \in created THEN (IF KindOf(a) = "eth_implicit" THEN EthWalletCode ELSE NoCode)
    ELSE IF a \notin Contracts THEN NoCode
    ELSE IF a \in DOMAIN InitCode THEN InitCode[a] ELSE "code"
\* Can a function call on a run?  (The same as before DeployContract while
\* code is empty.)
HasCode(a) == AcctExists(a) /\ CodeOf(a) # NoCode
\* The code a receipt's call sees: what its earlier actions leave (a
\* DeployContract's code, a UseGlobalContract's global code as published
\* now, a CreateAccount's new account with none), else the receiver's.
\* SetsCode(r): r has such an action.  CodeSeen(r): the call finds code.
SetsCode(r) == "ac" \in DOMAIN r /\ (r.ac.mk \/ Dpl(r) # NoCode \/ Ug(r) # NoGid)
CodeAfter(r) ==
    IF "ac" \in DOMAIN r /\ Dpl(r) # NoCode THEN Dpl(r)
    ELSE IF "ac" \in DOMAIN r /\ Ug(r) # NoGid THEN GCodeOf(Ug(r))
    ELSE IF "ac" \in DOMAIN r /\ r.ac.mk THEN NoCode
    ELSE CodeOf(r.to)
CodeSeen(r) ==
    IF SetsCode(r) THEN CodeAfter(r) # NoCode
    ELSE HasCode(r.to)
\* A missing or deleted receiver fails the call even with CallsNeedCode =
\* FALSE (AccountDoesNotExist, actions.rs:874-879), as does an uninitialised
\* universal one (AccountNotInitialized, :883-887).  A call in the same receipt
\* as a CreateAccount, DeployContract or UseGlobalContract (HasAc, the
\* factory batch) sees the account they leave (CodeAfter): a new account
\* has no code (actions.rs:202-208) unless the batch deploys or uses some
\* first; this holds also when the id was deleted before (the existence
\* checks are AcctErr's).
CallTargetOK(r) ==
    \/ ~IsCall(r)
    \/ IF SetsCode(r) THEN ~CallsNeedCode \/ CodeSeen(r)
       ELSE AcctExists(r.to) /\ ~UninitUniversal(r.to) /\ (~CallsNeedCode \/ CodeSeen(r))

\* The transaction signer, inherited by every receipt of the transaction.
SignerOf(t)  == txsig[t]               \* [a |-> account, k |-> key id]
Signer(r)    == txsig[r.tx].a          \* env::signer_account_id()
SignerKey(r) == txsig[r.tx].k          \* env::signer_account_pk()

\* Yield: promise_yield_create on r's account
\* (runtime/near-vm-runner/src/logic/host.rs:4245-4327).  The callback's
\* receiver and predecessor are r.to, its signer r's (function_call.rs:171-189);
\* its gas is a child's (static and weight from GasCall or WithCall, a share
\* of the leftover, 0 gas fails the creator).  It goes in the outcome's post
\* (never ready); its id is the resume token.  dep: 0, or the deposit of
\* promise_yield_create_with_id (host.rs:4330-4440); cb: 0, or r.cb when the
\* handler returns the yield (the caller's result is then the callback's,
\* lib.rs:1152-1166).  A yield created by a failing receipt does not exist
\* (function_call.rs:151-170 enqueues the timeout only on success).
YieldRcpt(id, r, m, a, dep, cb) ==
    [ydl |-> blk + YieldTicks] @@ Rcpt(id, r.tx, r.to, r.to, m, a, dep, r.to, cb)
\* promise_yield_resume's return value for yield y, called by receipt r: TRUE
\* iff y is a yield of r's account whose callback has not run, resumed or not
\* (runtime/runtime/src/ext.rs:406-430; the status is removed when the
\* callback runs, lib.rs:1572-1575, so a callback cannot resume itself).  A
\* yield created in the same call is not in post yet: the handler knows it
\* is pending (the resume succeeds, ext.rs:365-370).
CanResume(r, y) == \E p \in post : p.id = y /\ p.id # r.id /\ IsYield(p) /\ p.to = r.to
\* The yields of r's account still waiting, as r's handler sees them; ps:
\* the yields this handler has created so far (a subset of its outcome's
\* post).  For the duplicate check of promise_yield_create_with_id
\* (ext.rs:375-385: a pending custom id fails, u64::MAX at host.rs:4391-4399),
\* which the handler models by matching the custom id it keeps in each
\* yield's args.  r itself is excluded: when a yield callback runs, its
\* receipt, status and custom-id mapping are already removed
\* (lib.rs:1572-1575, :1576-1591, committed at :903 before the code runs
\* at :1602-1604), so it may re-create its own custom id.  ps is included:
\* the trie update already holds the mappings this call wrote
\* (ext.rs:380-385).
\* A plain promise_yield_create has no custom id: keep the two kinds apart
\* in the args.
PendingYieldRcpts(r, ps) == {q \in RemP(r) \cup ps : IsYield(q) /\ q.to = r.to}
PendingYieldsAt(r, ps)   == {p.id : p \in PendingYieldRcpts(r, ps)}
\* Ids of account a's yields still waiting, as a state view (invariants,
\* send steps).  Not for a handler: it still lists the running yield
\* callback, and not the yields created in the same call; use PendingYieldsAt.
PendingYields(a) == {p.id : p \in {q \in post : IsYield(q) /\ q.to = a}}

----------------------------------------------------------------------------
(* Outcome record a contract handler returns:                              *)
(*   ready : set of new ready receipts                                     *)
(*   post  : set of new postponed callbacks                                *)
(*   ret   : [k |-> "val"|"prom", v |-> value, sz |-> size in KB,          *)
(*            len |-> size in bytes, 0 = not stated]                       *)
(*   out   : sum of deposits attached to new receipts (debited from r.to)  *)
(*   ids   : number of fresh ids consumed                                  *)
(*   err   : "" or the panic message                                       *)
(*   gk    : burn key ("" = r.m); sz : size for the burn (KB)              *)
(* Optional fields:                                                        *)
(*   pa    : for a receipt with several function-call actions, one record  *)
(*           per action, in order (as many as r.g has entries):            *)
(*           [gk |-> burn key, sz |-> size, kids |-> ids of the children   *)
(*            that action created]  (kid sets disjoint)                    *)
(*           With pa, gas is checked and split per action (see GasOK).     *)
(*   pk    : panic-path burn key of a failing outcome (OPanicKey): the     *)
(*           burn up to the panic, without the fees of the children made   *)
(*           before it (KidsCost adds those, as for gk); without pk a      *)
(*           panic is always "fail".                                       *)
(*   pi    : with pa, the index of the action that panics (default the     *)
(*           last one; OPanicAt).                                          *)
(*   sb    : storage bytes the receipt adds to r.to (negative: frees);     *)
(*           OStor.  Used only with StoragePerByte.                        *)
RVal(v)       == [k |-> "val", v |-> v, sz |-> 0, len |-> 0]
RValSz(v, n)  == [k |-> "val", v |-> v, sz |-> n, len |-> 0]
\* A value of b bytes (b >= 1): also sets sz, rounded up (1 KB = 1000 bytes).
\* E.g. the JSON string "0" padded with 40 spaces is RValLen(0, 43).
RValLen(v, b) == [k |-> "val", v |-> v, sz |-> (b + 999) \div 1000, len |-> b]
RProm         == [k |-> "prom", v |-> 0, sz |-> 0, len |-> 0]
\* Size of a returned value; hand-built ret records without sz / len count as 0.
RetSz(O)  == IF "sz" \in DOMAIN O.ret THEN O.ret.sz ELSE 0
RetLen(O) == IF "len" \in DOMAIN O.ret THEN O.ret.len ELSE 0

\* A complete outcome record (contracts may add their own fields).
Outcome(rd, ps, ret, out, ids) ==
    [ready |-> rd, post |-> ps, ret |-> ret, out |-> out, ids |-> ids,
     err |-> "", gk |-> "", sz |-> 0]
OErr(O, e) == IF O.err = "" THEN [O EXCEPT !.err = e] ELSE O
OKey(O, k) == [O EXCEPT !.gk = k]
OSz(O, n)  == [O EXCEPT !.sz = n]
\* A failing outcome's burn up to its panic (burn key k in GasBurn, with size
\* O.sz).  List in O only the children created before the panic.
OPanicKey(O, k)   == [pk |-> k] @@ O
OPanicAt(O, i, k) == [pk |-> k, pi |-> i] @@ O
\* Resumes (optional outcome field rsm): promise_yield_resume(y, payload)
\* with payload value v of n KB.  Several are allowed, also of one yield.
OResume(O, y, v, n) ==
    IF "rsm" \in DOMAIN O THEN [O EXCEPT !.rsm = @ \cup {[y |-> y, v |-> v, sz |-> n]}]
    ELSE [rsm |-> {[y |-> y, v |-> v, sz |-> n]}] @@ O
Rsm(O) == IF "rsm" \in DOMAIN O THEN O.rsm ELSE {}
\* The PromiseResume data a committed outcome sends: one per resume of a
\* yield of r's account that is pending, in post or created by this same
\* outcome; a resume of anything else sends nothing (ext.rs:406-430).  A
\* failing resumer sends nothing.
ResumeData(r, O) ==
    { [to |-> e.y, ok |-> TRUE, v |-> e.v, sz |-> e.sz, len |-> 0, tx |-> r.tx] :
        e \in {x \in Rsm(O) : \E p \in RemP(r) \cup O.post : p.id = x.y /\ IsYield(p) /\ p.to = r.to} }

\* Balances after the receipt.  The receiver cannot spend more than it has
\* (BalanceExceeded inside the call), and liquid + locked must cover its
\* storage (lib.rs:1008-1031, check_storage_stake at verifier.rs:48-84;
\* LackBalanceForState).  Without StoragePerByte, StorageFloor[a] is the
\* required amount (give 0 for an account under the zero-balance threshold,
\* which is exempt, verifier.rs:77-79).  With it, the receiver's bytes after
\* the receipt, stor[r.to] + the outcome's sb, priced at StorageByteCost.
LockedOf(a) == IF a = StakingAcct THEN locked ELSE 0
\* Storage outcome field: the receipt adds d bytes to its receiver (d < 0
\* frees bytes).  Without StoragePerByte it is ignored.
OStor(O, d)  == [sb |-> d] @@ O
StorDelta(O) == IF "sb" \in DOMAIN O THEN O.sb ELSE 0
\* Log outcome field (docs/SEMANTICS.md, R6): OLog(O, b) adds one log of b
\* bytes (the message's UTF-8 length) to what the call writes; logs are
\* checked against the protocol limits (HostLimitErr) and not kept.
LogCount(O) == IF "lgn" \in DOMAIN O THEN O.lgn ELSE 0
LogBytes(O) == IF "lgb" \in DOMAIN O THEN O.lgb ELSE 0
OLog(O, b) == [lgn |-> LogCount(O) + 1, lgb |-> LogBytes(O) + b] @@ O
\* OLogs(O, b, n): n logs of b bytes each, without recursing once per log.
OLogs(O, b, n) == [lgn |-> LogCount(O) + n, lgb |-> LogBytes(O) + n * b] @@ O
\* Join outcome field (R6): OJoins(O, n) states that the call made n
\* promise_and calls, nested ones included (PromisesOver).
OJoins(O, n) == [nj |-> n] @@ O
\* Worst-case trie gas (docs/SEMANTICS.md, G6), opt-in: TrieGasWorst <-
\* TRUE.  At 88 storage_write and storage_remove charge touching_trie_node
\* (2.28 Ggas) per trie node on the key's path, plus one for the old value,
\* and nodes depend on the trie's shape at the start of the chunk, which
\* other writers can deepen; storage_read and storage_has_key charge none
\* (flat storage).  OWriteKey(O, n) declares one storage_write or
\* storage_remove of an n-byte key.  The trie key is 9 ++ account id ++
\* ',' ++ key, L = 2 + TrieAcctLen + n bytes, at most 2L + 1 nodes on its
\* path (one per nibble and the leaf), so a write costs at most 2L + 2
\* nodes more than none.  With the switch on, in gas mode, Exec runs a
\* receipt with declared writes at its calibrated burn plus the gas of n
\* extra nodes, for every n from 0 to the declared writes' bound
\* (TrieNodes; TrieGasAt(n), rounded up to whole Ggas).  Every n, not
\* only the two ends: less gas spent here leaves more for the children,
\* and what a child does with it need not be monotone (a child that runs
\* out at the bound and has room at 0 may, in between, commit and give
\* its owed callback too little).  TrieGasEnds <- TRUE takes only n = 0
\* and the bound: smaller, and UNSOUND for that reason (SEMANTICS G6).
\* Off (the default), OWriteKey changes nothing.
\* TrieAcctLen: the receiver's account id length in bytes; the default is
\* the longest id (64).  Nothing is added on a panic path (OPanicKey) and
\* a receipt with per-action accounting (pa) and declared writes is an
\* Assert.
TrieGasWorst == FALSE
TrieGasEnds  == FALSE
TrieAcctLen  == 64
TrieNodeMgas == 2280            \* wasm_touching_trie_node, Mgas (88)
TrieNodes(O) == IF "trn" \in DOMAIN O THEN O.trn ELSE 0
OWriteKey(O, n) == [trn |-> TrieNodes(O) + 2 * (2 + TrieAcctLen + n) + 2] @@ O
TrieGasAt(n) == (n * TrieNodeMgas + 999) \div 1000
TrieExtra(O) == TrieGasAt(TrieNodes(O))
\* The node counts Exec explores under TrieSplit.
TrieNodeRange(O) == IF TrieGasEnds THEN {0, TrieNodes(O)} ELSE 0..TrieNodes(O)
\* The extra gas Exec chose for this outcome (0 unless TrieSplit).
TrieGas(O)   == IF "trg" \in DOMAIN O THEN O.trg ELSE 0
TrieSplit(O) == GasMode = "gas" /\ TrieGasWorst /\ TrieNodes(O) > 0
\* Measured bytes (docs/SEMANTICS.md, B2): StorBytes is a table the
\* calibrator writes (conformance/, `calibrate --stor`), keyed like GasBurn
\* ("acct.method/path"): [key -> [base |-> Int, per |-> Int]], the receiver's
\* storage_usage after a successful receipt less before it, base + per *
\* size bytes (size: what the table's header says the bytes grow with, e.g.
\* the key + value length of a write).  Overridable, like GasBurn: give your
\* contract's measured table (StorStd has the standard tokens').  Default:
\* empty.  OStorKey(O, k, n) adds key k's bytes at size n to O's (OStor
\* replaces them), so several writes compose; a missing key stops TLC with
\* an Assert.  Without StoragePerByte it leaves O as it is and reads no
\* table.
StorBytes == [k \in {} |-> [base |-> 0, per |-> 0]]
StorOf(k, n) ==
    IF k \in DOMAIN StorBytes THEN StorBytes[k].base + StorBytes[k].per * n
    ELSE Assert(FALSE, <<"no StorBytes entry for", k>>)
OStorKey(O, k, n) == IF StoragePerByte THEN OStor(O, StorDelta(O) + StorOf(k, n)) ELSE O
\* Does bal (liquid + locked) cover bytes?  check_storage_stake: amount +
\* locked >= bytes x storage_amount_per_byte, or at most 770 bytes
\* (verifier.rs:54-79, :88-90).  Exact integer arithmetic.  (IF, not \/:
\* TLC would branch on each true disjunct inside an action.)
StorageCovers(bal, bytes) ==
    IF bytes <= ZeroBalanceBytes THEN TRUE
    ELSE bal * StorageByteCost[2] >= bytes * StorageByteCost[1]
\* r.to's bytes once r commits with outcome O.
StorAfter(r, O) ==
    LET b == stor[r.to] + StorDelta(O) IN
    IF b < 0 THEN Assert(FALSE, <<"storage usage below 0 bytes", r.to, r.m, b>>) ELSE b
----------------------------------------------------------------------------
(* Account lifecycle: CreateAccount, DeleteAccount, DeployContract, and    *)
(* the global-contract actions (docs/SEMANTICS.md A6-A10).  An ACCOUNT     *)
(* receipt (m = ACCT) holds only account actions, in this order:           *)
(* [CreateAccount]? [Transfer(dep)]? [key actions]* [DeployContract]?      *)
(* [DeployGlobalContract]? [UseGlobalContract]? [DeleteAccount(bnf)]?,     *)
(* recorded in the optional field ac = [mk |-> BOOLEAN (CreateAccount),    *)
(* bnf |-> beneficiary or "" (DeleteAccount), ka |-> key actions           *)
(* (NearKeys.WithAcctKeys)], with the optional dpl |-> code tag            *)
(* (WithDeploy), dg |-> [t, md] (WithDeployGlobal) and ug |-> identifier   *)
(* (WithUseGlobal).  The Transfer is present iff dep > 0.  It runs no      *)
(* code, never runs out of gas, and is run by ExecAcct (NearKeys.ExecAcctK *)
(* with key actions); Exec asserts on it.  A dispatcher routes             *)
(* IsAcctRcpt(r) there before any contract handler.  A call receipt may    *)
(* carry the same field (HasAc, A8, below; not dg): Exec runs it.  Sim:    *)
(* conformance/tests/lifecycle.rs, global.rs.                              *)

\* Account-id structure.  Toy ids carry none, so the model states it.
\* AcctParent[a]: a's direct parent ("near" for "alice.near"), or NoParent
\* for a top-level id.  A sub-account can be created only by its direct
\* parent (actions.rs:190-197; near-account-id 3.0.0 src/account_id_ref.rs
\* :216-221).  A top-level id shorter than min_allowed_top_level_account_length
\* can be created only by the registrar_account_id; that length is 65 from
\* protocol 64 on and ids have at most 64 characters, so at 88 only that
\* account (TopCreator) creates top-level ids (actions.rs:175-186;
\* core/parameters/res/runtime_configs/64.yaml:2; near-account-id
\* src/validation.rs:6-8).  Overridable: AcctParent <- MyParents,
\* MyParents == Parents({<<"sub", "c">>}); TopCreator <- "x".
NoParent == ""
AcctParent == [a \in Accounts |-> NoParent]
Parents(pairs) == [a \in Accounts |-> IF \E p \in pairs : p[1] = a
                                      THEN (CHOOSE p \in pairs : p[1] = a)[2] ELSE NoParent]
ParentOf(a) == IF a \in DOMAIN AcctParent THEN AcctParent[a] ELSE NoParent
TopCreator == "top-creator"

\* DeleteAccountWithLargeState: an account whose storage minus its contract
\* code exceeds 10,000 bytes cannot be deleted (actions.rs:342-369;
\* core/primitives-core/src/account.rs:248; from protocol 85 the global
\* contract identifier is subtracted too, version.rs:612-628).  The check
\* reads stor, so it applies only with StoragePerByte (N-delete-large).
\* CodeSize[a]: the code bytes counted in a's StorageInit (overridable,
\* default 0); an account on a global contract counts its identifier
\* (IdLen, A10; include it in StorageInit for an account in InitUses); an
\* eth-implicit account created by a Transfer holds the 32-byte global
\* contract hash; other created accounts have no code.
MaxDeleteBytes == 10000
CodeSize == [a \in Accounts |-> 0]
CodeBytes(a) == IF a \in DOMAIN code THEN CodeLenOf(code[a])
                ELSE IF a \in DOMAIN guse THEN IdLen(guse[a])
                ELSE IF a \in created /\ KindOf(a) = "eth_implicit" THEN 32
                ELSE IF ~HasCode(a) THEN 0
                ELSE IF a \in DOMAIN CodeSize THEN CodeSize[a] ELSE 0

\* Fees (gas mode).  gf convention: an ACCOUNT receipt's gf is the whole
\* receipt's send + exec fees, ReceiptFee plus each action's ActionFee
\* (NearFees), charged to its creator at creation whatever the outcome.
\* That is the prepaid reservation, not the burn: nearcore stops a failed
\* receipt at its failing action (lib.rs:1001-1003) and burns the receipt's
\* exec fee plus the exec fees of the actions it attempted (each burns its
\* own as it starts, :588-592); the exec fees of the actions after it come
\* back with the gas refund (:1299-1309).  Gas refunds, like the creation
\* charge withheld on failure, are gas money, which is not modelled
\* (N-gas-money; sim lifecycle.rs account_action_fees, create_batch_atomic).
\* NearKeys.WithAcctKeys adds the key actions' fees.
\* sir: the receipt is on its predecessor's own account.  AcctActsFee: the
\* account actions alone (a call receipt's base is in its call's fee, A8).
AcctActsFee(fr, to, mk, dep, bnf) ==
    IF GasMode # "gas" THEN 0
    ELSE LET sir == (fr = to) IN
         (IF mk THEN NearFeeTable!ActionFee("create_account", sir, KindOf(to)) ELSE 0)
         + (IF dep > 0 THEN NearFeeTable!ActionFee("transfer", sir, KindOf(to)) ELSE 0)
         + (IF bnf # "" THEN NearFeeTable!ActionFee("delete_account", sir, KindOf(to)) ELSE 0)
AcctFee(fr, to, mk, dep, bnf) ==
    IF GasMode # "gas" THEN 0
    ELSE NearFeeTable!ReceiptFee(fr = to) + AcctActsFee(fr, to, mk, dep, bnf)

\* Constructors.  CreateAcctRcpt: [CreateAccount, Transfer(dep)?] for the
\* new account, from its creator fr (refunds go to fr).  DeleteAcctRcpt:
\* [DeleteAccount(b)] on acct, sent by acct itself (its own transaction or a
\* receipt it creates).  WithDeleteTo(r, b) appends DeleteAccount(b) to an
\* ACCOUNT receipt or a call receipt (it must be last, action_validation.rs
\* :139-142), e.g. WithDeleteTo(CreateAcctRcpt(..), b).
AcctRcpt(id, tx, to, fr, a, dep, cb, mk, bnf) ==
    WithFee([ac |-> [mk |-> mk, bnf |-> bnf, ka |-> <<>>]] @@ Rcpt(id, tx, to, fr, ACCT, a, dep, fr, cb),
            AcctFee(fr, to, mk, dep, bnf))
CreateAcctRcpt(id, tx, new, fr, a, dep, cb) == AcctRcpt(id, tx, new, fr, a, dep, cb, TRUE, "")
DeleteAcctRcpt(id, tx, acct, a, b, cb)      == AcctRcpt(id, tx, acct, acct, a, 0, cb, FALSE, b)
WithDeleteTo(r, b) ==
    IF ~(IsAcctRcpt(r) \/ IsCall(r)) \/ b = "" \/ ("ac" \in DOMAIN r /\ r.ac.bnf # "")
    THEN Assert(FALSE, <<"WithDeleteTo needs an ACCOUNT or call receipt without a DeleteAccount, and a beneficiary", r.id>>)
    ELSE LET r1 == IF "ac" \in DOMAIN r THEN r ELSE [ac |-> [mk |-> FALSE, bnf |-> "", ka |-> <<>>]] @@ r IN
         [r1 EXCEPT !.ac.bnf = b, !.gf = @ + AcctActsFee(r.fr, r.to, FALSE, 0, b)]
\* WithDeploy(r, t) adds DeployContract(t) to an ACCOUNT or call receipt,
\* after its CreateAccount and Transfer and before its call and
\* DeleteAccount (A9).  t is a code tag; CodeLen[t] its bytes (overridable,
\* default 0), at most max_contract_size (4 MiB, action_validation.rs
\* :305-318; a larger one is rejected, which the model does not represent).
\* Its fee is deploy_base plus deploy_byte per byte (config.rs:99-108).
\* DeployRcpt: [DeployContract(t)] on acct from acct itself.  Not with a
\* UseGlobalContract in the same receipt (the model fixes the action order;
\* nearcore keeps the last one).
MaxContractSize == 4194304
WithDeploy(r, t) ==
    IF ~(IsAcctRcpt(r) \/ IsCall(r)) \/ t = NoCode \/ ("ac" \in DOMAIN r /\ Dpl(r) # NoCode)
       \/ ("ac" \in DOMAIN r /\ Ug(r) # NoGid)
    THEN Assert(FALSE, <<"WithDeploy needs an ACCOUNT or call receipt without a DeployContract"
                         \o " or UseGlobalContract, and a code tag", r.id>>)
    ELSE IF CodeLenOf(t) > MaxContractSize
    THEN Assert(FALSE, <<"WithDeploy: code above max_contract_size", t>>)
    ELSE LET r1 == IF "ac" \in DOMAIN r THEN r ELSE [ac |-> [mk |-> FALSE, bnf |-> "", ka |-> <<>>]] @@ r
             fee == IF GasMode # "gas" THEN 0
                    ELSE NearFeeTable!ActionFee("deploy_base", r.fr = r.to, KindOf(r.to))
                         + NearFeeTable!DeployBytesFee(r.fr = r.to, CodeLenOf(t)) IN
         [r1 EXCEPT !.ac = [dpl |-> t] @@ @, !.gf = @ + fee]
DeployRcpt(id, tx, acct, a, t, cb) == WithDeploy(AcctRcpt(id, tx, acct, acct, a, 0, cb, FALSE, ""), t)

\* Global contracts (NEP-591, A10; sim: conformance/tests/global.rs).
\* WithDeployGlobal(r, t, md) adds DeployGlobalContract(t) to an ACCOUNT
\* receipt, after its DeployContract position and before its DeleteAccount;
\* md is "hash" (identifier GHash(t)) or "acct" (GAcct(r.to)).  The account
\* itself must send it (ActorNoPermission, actions.rs:755-812).  It burns
\* GlobalBurn(CodeLen[t]) of the account's balance (global_contracts.rs
\* :35-51; LackBalanceForState when short) and adds nothing to its storage
\* or code.  The code is published later, when the distribution receipt it
\* emits runs (DistRcpt, ExecGDist; :143-171): a UseGlobalContract in the
\* same batch, or in a receipt that runs before the distribution, fails
\* (sim: deploy_global).  Fee: deploy_global base plus per byte
\* (config.rs:171-180, :380-387).  Only in ACCOUNT receipts here.
\* WithUseGlobal(r, g) adds UseGlobalContract(g) to an ACCOUNT or call
\* receipt, after its CreateAccount, Transfer and key actions and before its
\* call and DeleteAccount (the factory batch [CreateAccount, Transfer,
\* UseGlobalContract, FunctionCall(init)]).  g must be published when the
\* receipt runs (GlobalContractDoesNotExist, :76-90); the account's bytes
\* lose its old code's (local length or identifier) and gain IdLen(g)
\* (:91-106; sim: use_global_storage).  Fee: use_global base plus per
\* identifier byte (config.rs:182-190, :389-395).
\* GlobalByteCost = <<num, den>>: one published byte burns num/den model
\* NEAR units; 0.0001 N per byte (77.yaml:2), ten times the storage rate,
\* so <<1, 10000>> when 1 unit = 1 NEAR.  The burn is exact: choose units
\* and CodeLen so that bytes x num is a multiple of den (an Assert).
\* GlobalInstant <- TRUE: the code is published when the deploy commits, no
\* distribution receipt.  An under-approximation (unsound, N-global-instant):
\* it drops the window in which a Use fails and users still run the old code.
GlobalByteCost == <<1, 10000>>
GlobalInstant  == FALSE
GlobalBurn(n) ==
    IF (n * GlobalByteCost[1]) % GlobalByteCost[2] # 0
    THEN Assert(FALSE, <<"GlobalBurn: code bytes x num is not a multiple of den"
                         \o " (GlobalByteCost)", n>>)
    ELSE (n * GlobalByteCost[1]) \div GlobalByteCost[2]
DgId(r)  == IF r.ac.dg.md = "hash" THEN GHash(r.ac.dg.t) ELSE GAcct(r.to)
GBurn(r) == IF IsAcctRcpt(r) /\ DgTag(r) # NoCode THEN GlobalBurn(CodeLenOf(DgTag(r))) ELSE 0
\* An ACCOUNT receipt's liquid after its actions: the Transfer in, the
\* global deploy's burn out (negative: the burn is not covered).
AcctBal(r) == (IF r.ac.mk THEN 0 ELSE near[r.to]) + r.dep - GBurn(r)
WithDeployGlobal(r, t, md) ==
    IF ~IsAcctRcpt(r) \/ t = NoCode \/ md \notin {"hash", "acct"} \/ DgTag(r) # NoCode
    THEN Assert(FALSE, <<"WithDeployGlobal needs an ACCOUNT receipt without a DeployGlobalContract,"
                         \o " a code tag, and md \"hash\" or \"acct\"", r.id>>)
    ELSE IF CodeLenOf(t) > MaxContractSize
    THEN Assert(FALSE, <<"WithDeployGlobal: code above max_contract_size", t>>)
    ELSE LET fee == IF GasMode # "gas" THEN 0
                    ELSE NearFeeTable!ActionFee("deploy_global_base", r.fr = r.to, KindOf(r.to))
                         + NearFeeTable!GlobalDeployBytesFee(r.fr = r.to, CodeLenOf(t)) IN
         [r EXCEPT !.ac = [dg |-> [t |-> t, md |-> md]] @@ @, !.gf = @ + fee]
WithUseGlobal(r, g) ==
    IF ~(IsAcctRcpt(r) \/ IsCall(r)) \/ g = NoGid \/ g[1] \notin {"hash", "acct"}
       \/ ("ac" \in DOMAIN r /\ (Ug(r) # NoGid \/ Dpl(r) # NoCode))
    THEN Assert(FALSE, <<"WithUseGlobal needs an ACCOUNT or call receipt without a UseGlobalContract"
                         \o " or DeployContract, and an identifier (GHash, GAcct)", r.id>>)
    ELSE LET r1 == IF "ac" \in DOMAIN r THEN r ELSE [ac |-> [mk |-> FALSE, bnf |-> "", ka |-> <<>>]] @@ r
             fee == IF GasMode # "gas" THEN 0
                    ELSE NearFeeTable!ActionFee("use_global_base", r.fr = r.to, KindOf(r.to))
                         + NearFeeTable!UseGlobalBytesFee(r.fr = r.to, IdLen(g)) IN
         [r1 EXCEPT !.ac = [ug |-> g] @@ @, !.gf = @ + fee]
\* [DeployGlobalContract(t)] and [UseGlobalContract(g)] on acct from acct.
DeployGlobalRcpt(id, tx, acct, a, t, md, cb) ==
    WithDeployGlobal(AcctRcpt(id, tx, acct, acct, a, 0, cb, FALSE, ""), t, md)
UseGlobalRcpt(id, tx, acct, a, g, cb) == WithUseGlobal(AcctRcpt(id, tx, acct, acct, a, 0, cb, FALSE, ""), g)
\* The distribution receipt of r's DeployGlobalContract, with id (and
\* nonce) id: a system receipt (receipt.rs:538-548), here addressed to the
\* owner; it carries no NEAR and no gas.
DistRcpt(id, r) == Rcpt(id, r.tx, r.to, r.to, GDIST, [g |-> DgId(r), t |-> DgTag(r)], 0, r.to, 0)

\* The actor after the CreateAccount (the new account) or without one (the
\* predecessor) (actions.rs:202; lib.rs:599-610).
AcctActor(r) == IF r.ac.mk THEN r.to ELSE r.fr
\* Does the receiver exist for the actions after CreateAccount?  A universal
\* account created by a Transfer is uninitialised: only a Transfer accepts it
\* (actions.rs:880-887).
AcctThere(r) == r.ac.mk \/ AcctExists(r.to)
AcctInit(r)  == r.ac.mk \/ ~UninitUniversal(r.to)

\* DeployContract (A9): the code bytes before and after a receipt's account
\* actions, and the receiver's bytes after them.  A deploy replaces the
\* code: usage less the old code's size plus the new one's (actions.rs
\* :300-311, the old size :426-440); data stays.
CodeBytesBefore(r) == IF r.ac.mk THEN 0 ELSE CodeBytes(r.to)
CodeBytesAfter(r)  == IF Dpl(r) # NoCode THEN CodeLenOf(Dpl(r))
                      ELSE IF Ug(r) # NoGid THEN IdLen(Ug(r)) ELSE CodeBytesBefore(r)
DplDelta(r)        == CodeBytesAfter(r) - CodeBytesBefore(r)
AcctBytes(r, kb)   == (IF r.ac.mk THEN AccountBytes ELSE stor[r.to]) + kb + DplDelta(r)
\* code after a committed receipt with account actions: a DeleteAccount
\* drops the account's entry (remove_account, core/store/src/utils/mod.rs
\* :504-575), as does a CreateAccount (a new account has none), unless a
\* DeployContract sets it; a UseGlobalContract drops it too
\* (global_contracts.rs:92-94).  guse likewise: a DeleteAccount, a
\* DeployContract or a CreateAccount without a UseGlobalContract drops the
\* account's entry, a UseGlobalContract sets it.  An account is in at most
\* one of DOMAIN code and DOMAIN guse.
CodeNext(r) ==
    IF r.ac.bnf # "" \/ (r.ac.mk /\ Dpl(r) = NoCode) THEN [x \in DOMAIN code \ {r.to} |-> code[x]]
    ELSE IF Dpl(r) # NoCode THEN (r.to :> Dpl(r)) @@ code
    ELSE IF Ug(r) # NoGid THEN [x \in DOMAIN code \ {r.to} |-> code[x]]
    ELSE code
UsesNext(r) ==
    IF r.ac.bnf # "" \/ Dpl(r) # NoCode \/ (r.ac.mk /\ Ug(r) = NoGid)
    THEN [x \in DOMAIN guse \ {r.to} |-> guse[x]]
    ELSE IF Ug(r) # NoGid THEN (r.to :> Ug(r)) @@ guse
    ELSE guse

\* The first failing action check, as nearcore's error name, or "".  Per
\* action: existence, then the actor, then the action (lib.rs:599-610).
\* kb: the bytes the key actions add; kok: they all apply (NearKeys).
\*  CreateAccount: AccountAlreadyExists (actions.rs:822-828); an implicit id
\*    (IsImplicit, which follows get_account_type at 88, universal included)
\*    only by a Transfer (:829-840); a top-level id only by TopCreator
\*    (:175-186); a sub-account only by its direct parent (:190-197).
\*  Transfer: the receiver must exist (:842-849; an ACCOUNT receipt never
\*    creates an implicit account, see ExecTransfer).
\*  Key actions: exist, initialised, actor = the account (:862-886,
\*    :755-801), each one applies (access_keys.rs:84, :158).
\*  DeployContract: exists, initialised, actor = the account (:755-776).
\*  DeployGlobalContract, UseGlobalContract: the same (:755-776); then the
\*    balance must cover the deploy's burn (LackBalanceForState,
\*    global_contracts.rs:41-48) and the used identifier must be published
\*    now (GlobalContractDoesNotExist, :83-90).
\*  DeleteAccount: exists; actor = the account (:776-783, ActorNoPermission);
\*    nothing locked (:784-790, DeleteAccountStaking); not large state, the
\*    code it then has subtracted (a DeployContract before it: the new code).
\* t: NoCode unless the receipt has a code action (DeployContract,
\* DeployGlobalContract, UseGlobalContract).
AcctErr(r, kb, kok) ==
    LET a == r.to  ka == r.ac.ka  b == r.ac.bnf
        t == IF Dpl(r) # NoCode THEN Dpl(r) ELSE IF DgTag(r) # NoCode THEN DgTag(r)
             ELSE IF Ug(r) # NoGid THEN "global" ELSE NoCode
        bytes == AcctBytes(r, kb) IN
    \* (IF, not CASE: the first failing check wins.)
    IF r.ac.mk /\ AcctExists(a) THEN "AccountAlreadyExists"
    ELSE IF r.ac.mk /\ IsImplicit(a) THEN "OnlyImplicitAccountCreationAllowed"
    ELSE IF r.ac.mk /\ ParentOf(a) = NoParent /\ r.fr # TopCreator THEN "CreateAccountOnlyByRegistrar"
    ELSE IF r.ac.mk /\ ParentOf(a) # NoParent /\ ParentOf(a) # r.fr THEN "CreateAccountNotAllowed"
    ELSE IF (DepTotal(r) > 0 \/ ka # <<>> \/ t # NoCode \/ b # "") /\ ~AcctThere(r) THEN "AccountDoesNotExist"
    ELSE IF (ka # <<>> \/ t # NoCode \/ b # "") /\ ~AcctInit(r) THEN "AccountNotInitialized"
    ELSE IF (ka # <<>> \/ t # NoCode \/ b # "") /\ AcctActor(r) # a THEN "ActorNoPermission"
    ELSE IF ka # <<>> /\ ~kok THEN "AddKeyAlreadyExists or DeleteKeyDoesNotExist"
    ELSE IF DgTag(r) # NoCode /\ AcctBal(r) < 0 THEN "LackBalanceForState"
    ELSE IF Ug(r) # NoGid /\ Ug(r) \notin DOMAIN gcode THEN "GlobalContractDoesNotExist"
    ELSE IF b # "" /\ LockedOf(a) > 0 THEN "DeleteAccountStaking"
    ELSE IF b # "" /\ StoragePerByte /\ bytes - CodeBytesAfter(r) > MaxDeleteBytes
         THEN "DeleteAccountWithLargeState"
    ELSE ""

\* Call receipts that carry account actions (HasAc on a call: the factory
\* batch [CreateAccount, Transfer, key actions?, FunctionCall(init)] on the
\* new account, or [FunctionCall, DeleteAccount(b)] on the account itself).
\* WithCreate(r) puts a CreateAccount (and, if r.dep > 0, a Transfer of
\* r.dep, moved to ac.xfer: the call's own deposit becomes 0, and a handler
\* reading r.dep sees that, function_call.rs:273; sim lifecycle.rs
\* batch_call_sees_own_deposit) before r's call; set r.dep after WithCreate
\* for a call deposit too.  WithDeleteTo(r, b) puts a DeleteAccount after it;
\* NearKeys.WithAcctKeys adds key actions before it.  Exec runs such a
\* receipt: its account actions as in an ACCOUNT receipt (AcCallErr, the
\* first Verdict branch), the call on the account they leave (CallTargetOK:
\* a new account has no code), the storage check after all of them, skipped
\* when the account is deleted (AcAffordable), and on commit their effects
\* with the call's (CommitAc).  The Transfer and the call's deposit are
\* credited at once (DepTotal; in nearcore the Transfer runs before the
\* call; the end state is the same) and refunded together on failure.  gf: the call's fee (GasCall) plus the account actions' send
\* and exec fees (AcctActsFee), the receipt base being in the call's fee.
HasAc(r)  == "ac" \in DOMAIN r
AcCall(r) == HasAc(r) /\ IsCall(r)
\* The account actions' first failing check (AcctErr; kb: the bytes the
\* call and the key actions add, which the DeleteAccount's 10,000-byte check
\* reads after the call; key failures come in O.err, NearKeys.WithKeyActs).
AcCallErr(r, O) == AcctErr(r, StorDelta(O), TRUE)
\* The receiver's balance and bytes after the receipt (a new account starts
\* at 0 and 100 bytes).
AcBal(r, O)   == (IF r.ac.mk THEN 0 ELSE near[r.to]) + DepTotal(r) - O.out
AcBytes(r, O) ==
    LET b == AcctBytes(r, StorDelta(O)) IN
    IF b < 0 THEN Assert(FALSE, <<"storage usage below 0 bytes", r.to, r.m, b>>) ELSE b
\* The storage check runs once, after all actions, and not on an account
\* the receipt deleted (lib.rs:1008-1031, the skip at :1010).
AcAffordable(r, O) ==
    /\ AcBal(r, O) >= 0
    /\ IF r.ac.bnf # "" THEN TRUE
       ELSE IF StoragePerByte THEN StorageCovers(AcBal(r, O) + LockedOf(r.to), AcBytes(r, O))
       ELSE AcBal(r, O) + LockedOf(r.to) >= StorageFloor[r.to]
WithCreate(r) ==
    IF ~IsCall(r) \/ HasAc(r) THEN Assert(FALSE, <<"WithCreate needs a call receipt without account actions", r.id>>)
    ELSE [ac |-> [mk |-> TRUE, bnf |-> "", ka |-> <<>>, xfer |-> r.dep]]
         @@ [r EXCEPT !.dep = 0, !.gf = @ + AcctActsFee(r.fr, r.to, TRUE, r.dep, "")]
----------------------------------------------------------------------------
(* Affordability                                                          *)
Affordable(r, O) ==
    IF AcCall(r) THEN AcAffordable(r, O) ELSE
    /\ near[r.to] + r.dep - O.out >= 0
    /\ IF StoragePerByte
       THEN StorageCovers(near[r.to] + r.dep - O.out + LockedOf(r.to), StorAfter(r, O))
       ELSE near[r.to] + r.dep - O.out + LockedOf(r.to) >= StorageFloor[r.to]

----------------------------------------------------------------------------
(* Protocol limits (docs/SEMANTICS.md, R6), protocol 88's values           *)
(* (core/parameters/src/snapshots/near_parameters__config_store__tests__88 *)
(* .json.snap:244-256).  The ones the model can count fail the receipt as  *)
(* nearcore does (Verdict, CanSubmit); the deploy limits are Asserts       *)
(* (WithDeploy, WithDeployGlobal).                                         *)
MaxActionsPerReceipt == 100      \* max_actions_per_receipt
MaxPromisesPerCall   == 1024     \* max_promises_per_function_call_action
MaxJointInputs       == 128      \* max_number_input_data_dependencies
MaxReturnedData      == 4194304  \* max_length_returned_data, bytes
MaxLogs              == 100      \* max_number_logs
MaxLogBytes          == 16384    \* max_total_log_length, bytes

\* The actions of a receipt record: its function calls (one per static or
\* gas entry, at least one), and the account actions it carries (A8):
\* CreateAccount, Transfer, key actions, DeployContract,
\* DeployGlobalContract, UseGlobalContract, DeleteAccount.  An ACCOUNT
\* receipt's deposit is its Transfer.  Any other receipt is one action.
AcActCount(r) ==
    (IF r.ac.mk THEN 1 ELSE 0) + (IF (IsAcctRcpt(r) /\ r.dep > 0) \/ XferOf(r) > 0 THEN 1 ELSE 0)
    + Len(r.ac.ka) + (IF Dpl(r) # NoCode THEN 1 ELSE 0) + (IF DgTag(r) # NoCode THEN 1 ELSE 0)
    + (IF Ug(r) # NoGid THEN 1 ELSE 0) + (IF r.ac.bnf # "" THEN 1 ELSE 0)
NCalls(r) == LET n == IF Len(r.gs) > Len(r.g) THEN Len(r.gs) ELSE Len(r.g) IN IF n > 1 THEN n ELSE 1
NActs(r) ==
    IF IsAcctRcpt(r) THEN AcActCount(r)
    ELSE IF IsCall(r) THEN NCalls(r) + (IF HasAc(r) THEN AcActCount(r) ELSE 0)
    ELSE 1

\* Host-function limits, hit while the call runs (HostLimitErr): the call
\* fails there, as a panic would, and creates nothing.
\*  - a joint callback waiting on more than 128 inputs (promise_and,
\*    runtime/near-vm-runner/src/logic/host.rs:2523-2532);
\*  - more than 1024 promises in one function-call action (host.rs:610-622,
\*    checked by every host function that makes a promise: each receipt,
\*    each promise_and, each yield), PromisesOver below;
\*  - a returned value over 4 MiB (value_return, host.rs:4711-4717), in
\*    bytes when the outcome states them (RValLen), else from the KB size:
\*    4196 KB is surely over and 4195 KB may be either (an Assert);
\*  - more than 100 logs, or more than 16384 bytes of them, in one
\*    function-call action (runtime/near-vm-runner/src/logic/logic.rs:81-101,
\*    host.rs:486-512, :4792-4800), as the outcome declares them (OLog).  The
\*    limits are per action: over them in a receipt of several function
\*    calls is an Assert, since the model cannot tell which call logs what.
LogsOver(r, O) ==
    IF LogCount(O) <= MaxLogs /\ LogBytes(O) <= MaxLogBytes THEN FALSE
    ELSE IF NCalls(r) > 1
    THEN Assert(FALSE, <<"logs over max_number_logs or max_total_log_length in a receipt of several function calls;"
                         \o " the limits are per call", r.m, LogCount(O), LogBytes(O)>>)
    ELSE TRUE
RetTooLong(O) ==
    /\ O.ret.k = "val"
    /\ IF RetLen(O) > 0 THEN RetLen(O) > MaxReturnedData
       ELSE IF RetSz(O) = (MaxReturnedData + 999) \div 1000
       THEN Assert(FALSE, <<"a returned value of", RetSz(O), "KB may or may not exceed max_length_returned_data;"
                            \o " state its bytes with RValLen">>)
       ELSE RetSz(O) > (MaxReturnedData + 999) \div 1000

----------------------------------------------------------------------------
(* Need, verdict and the unused-gas split                                  *)
Kids(O) == O.ready \cup O.post

BurnKey(r, O) == IF O.gk = "" THEN r.m ELSE O.gk
Burn(r, O) ==
    LET k == BurnKey(r, O) IN
    IF k \in DOMAIN GasBurn THEN GasBurn[k].base + GasBurn[k].per * O.sz
    ELSE Assert(FALSE, <<"no GasBurn entry for", k>>)

KidsCost(S) == RcptSum(LAMBDA c : c.gf + SumSeq(c.gs), S)

Need(r, O) == Burn(r, O) + KidsCost(Kids(O)) + TrieGas(O) + ReadGas(O)

\* Per-action accounting.  Each function-call action runs with its own gas and
\* its own promise manager (function_call.rs:61); its children share only
\* that action's leftover (function_call.rs:343-345); the leftover of other
\* actions is refunded (lib.rs:1311-1315).  Used when the outcome has pa
\* with more than one action; otherwise the receipt is one action.
PAOK(r, O) ==
    IF Len(O.pa) # Len(r.g)
    THEN Assert(FALSE, <<"pa has", Len(O.pa), "actions but the receipt has", Len(r.g), "gas entries", r.m>>)
    ELSE IF \E i, j \in DOMAIN O.pa : i < j /\ O.pa[i].kids \cap O.pa[j].kids # {}
    THEN Assert(FALSE, <<"pa kid sets overlap", r.m>>)
    ELSE TRUE
PerAction(r, O) ==
    /\ GasMode = "gas" /\ "pa" \in DOMAIN O /\ O.pa # <<>>
    /\ PAOK(r, O)
    /\ Len(O.pa) > 1
ActGas(r, k) == IF k \in DOMAIN r.g THEN r.g[k] ELSE 0
ActBurn(O, k) ==
    LET key == O.pa[k].gk IN
    IF key \in DOMAIN GasBurn THEN GasBurn[key].base + GasBurn[key].per * O.pa[k].sz
    ELSE Assert(FALSE, <<"no GasBurn entry for", key>>)
ActKids(O, k) == {c \in Kids(O) : c.id \in O.pa[k].kids}
ActNeed(O, k) == ActBurn(O, k) + KidsCost(ActKids(O, k))
ActOf(O, c) ==
    IF \E k \in DOMAIN O.pa : c.id \in O.pa[k].kids
    THEN CHOOSE k \in DOMAIN O.pa : c.id \in O.pa[k].kids
    ELSE Assert(FALSE, <<"child not attributed to an action in pa", c.id>>)

GasOK(r, O) ==
    \/ GasMode # "gas"
    \/ IF PerAction(r, O) THEN \A k \in DOMAIN O.pa : ActGas(r, k) >= ActNeed(O, k)
       ELSE GasOf(r) >= Need(r, O)

\* A panicking receipt that could not reach its panic ran out of gas first:
\* the burn up to the panic plus the gas reserved by the promises created
\* before it exceeds the attached gas (gas_counter.rs:126-150, :136-141 limit
\* prepaid - promises_gas, :155-174, :205-213 GasExceeded).  Only for an
\* outcome with an explicit panic-path key (OPanicKey / OPanicAt); the
\* success-path key says nothing about where the panic happens.  Per action:
\* the actions before the panicking one, and that one up to its panic.
HasPanicKey(O) == "pk" \in DOMAIN O /\ O.pk # ""
PanicBurn(O) ==
    IF O.pk \in DOMAIN GasBurn THEN GasBurn[O.pk].base + GasBurn[O.pk].per * O.sz
    ELSE Assert(FALSE, <<"no GasBurn entry for panic key", O.pk>>)
PanicAct(O) == IF "pi" \in DOMAIN O THEN O.pi ELSE Len(O.pa)
PanicOOG(r, O) ==
    /\ GasMode = "gas"
    /\ HasPanicKey(O)
    /\ IF PerAction(r, O)
       THEN LET f == PanicAct(O) IN
            \/ \E k \in 1..(f - 1) : ActGas(r, k) < ActNeed(O, k)
            \/ ActGas(r, f) < PanicBurn(O) + KidsCost(ActKids(O, f))
       ELSE GasOf(r) < PanicBurn(O) + KidsCost(Kids(O))

\* Weighted function-call actions of a set of children: <<id, action index, weight>>.
\* In gas mode a function-call child needs one static (and one weight) per
\* call: a GasCall entry for it, or WithCall / WithStatic.  An empty list
\* would give it no gas and skip the zero-gas check, so it is an error.
GasListsOK(c) ==
    IF Len(c.gs) # Len(c.gw)
    THEN Assert(FALSE, <<"static and weight lists differ in length", c.m, c.id>>)
    ELSE IF GasMode = "gas" /\ IsCall(c) /\ c.gs = <<>>
    THEN Assert(FALSE, <<"function-call child without static gas (add a GasCall entry or WithCall)", c.to, c.m>>)
    ELSE TRUE
EntriesOf(S) ==
    UNION { IF GasListsOK(c) THEN { <<c.id, k, c.gw[k]>> : k \in {j \in DOMAIN c.gw : c.gw[j] > 0} } ELSE {}
            : c \in S }
Entries(O) == EntriesOf(Kids(O))
\* Sums over entries, split by receipt id (KeySum).
WSum(E) == KeySum(LAMBDA e : e[3], LAMBDA e : e[1], E)
FloorSum(E, U, W) == KeySum(LAMBDA e : (U * e[3]) \div W, LAMBDA e : e[1], E)
\* The last weighted action.  The model orders by (receipt id, action index);
\* nearcore by the order of the host calls that set the weights
\* (receipt_manager.rs:414).  They agree when receipts are created in id
\* order and their actions appended in order, as near-sdk promise chains do.
LastE(E) == CHOOSE e \in E : \A f \in E : f[1] < e[1] \/ (f[1] = e[1] /\ f[2] <= e[2])
\* nearcore gives each weighted action floor(U*w/W) in gas units and the last
\* one also the remainder, fewer than n gas units for n weighted actions
\* (receipt_manager.rs:679-719).  The model's U is in whole Ggas.
\*  "up" (the default): floor(U*w/W) Ggas for every action, the last one
\*    included; the model's remainder (up to n - 1 Ggas) is not handed out.
\*    Where the model's U is at most nearcore's, a whole-Ggas floor of a
\*    smaller value never exceeds the gas-unit floor of a larger one, so every
\*    share is at most nearcore's: gas the model finds enough for a child is
\*    enough there.  U is at most nearcore's when the attached gas is (a stated
\*    prepaid amount or an "up" share; not a pooled leftover, PooledGasOK) and
\*    Need is an upper bound (fees "up"; burns from a calibrated table within
\*    its measured sizes).  docs/SEMANTICS.md, N-precision, lists the
\*    exceptions.
\*  "nearest": the last action in (id, index) order gets the remainder in
\*    Ggas, as before; it can then exceed nearcore's share by up to n - 1
\*    Ggas (docs/SEMANTICS.md, G3).
\* W = WSum(E) and L = LastE(E), passed in so that a split over n children
\* computes them once (Give), not once per child.
ShareWL(e, U, E, W, L) ==
    IF NearFeeTable!FeeRounding = "up" THEN (U * e[3]) \div W
    ELSE IF e = L THEN U - FloorSum(E \ {e}, U, W) ELSE (U * e[3]) \div W
Share(e, U, E) == ShareWL(e, U, E, WSum(E), LastE(E))

AssignWL(c, U, E, W, L) ==
    IF ~GasListsOK(c) THEN c
    ELSE [c EXCEPT !.g = [k \in DOMAIN c.gs |->
                        c.gs[k] + (IF c.gw[k] > 0 /\ U > 0 THEN ShareWL(<<c.id, k, c.gw[k]>>, U, E, W, L) ELSE 0)]]
Assign(c, U, E) == AssignWL(c, U, E, WSum(E), LastE(E))

\* The leftover U split over c's siblings: its action's under pa, else the receipt's.
LeftFor(r, O, c) ==
    IF PerAction(r, O) THEN LET k == ActOf(O, c) IN ActGas(r, k) - ActNeed(O, k)
    ELSE GasOf(r) - Need(r, O)
\* The weighted actions U is split over: those of c's action's children under pa.
EntriesFor(r, O, c) ==
    IF PerAction(r, O) THEN EntriesOf(ActKids(O, ActOf(O, c))) ELSE Entries(O)

\* A child with its attached gas, after the split.
Alloc(r, O, c) == Assign(c, LeftFor(r, O, c), EntriesFor(r, O, c))

\* Without pa every child shares the receipt's leftover and entries, so they
\* are computed once (the same values as Alloc's).
Give(r, O, S) ==
    IF GasMode # "gas" THEN S
    ELSE IF PerAction(r, O) THEN {Alloc(r, O, c) : c \in S}
    ELSE LET U == GasOf(r) - Need(r, O)
             E == Entries(O)
             W == WSum(E)
             L == LastE(E)
         IN {AssignWL(c, U, E, W, L) : c \in S}

\* A function-call child left with 0 gas fails the creating receipt: new
\* receipts are validated after the action (lib.rs:968-978;
\* action_validation.rs:350-351, FunctionCallZeroAttachedGas).  nearcore
\* splits the leftover in gas units (receipt_manager.rs:686-716): a weighted
\* action gets floor(U*w/W) gas units, the last one also the remainder; an
\* action with weight 0 is not in gas_weights (:414-419) and gets nothing.
\*  "nearest": the child's allocated gas decides (ZeroGasKid), as before.
\*  "up": the model's U (whole Ggas) is a lower bound of nearcore's, so
\*    whether a static-0 action ends up with 0 gas is not always known:
\*    - weight 0: certainly 0 gas: the creator fails (ZeroGasKid);
\*    - weight w > 0 and U*10^9*w >= W: nearcore's share is at least
\*      floor(U*10^9*w/W) >= 1 gas unit, certainly nonzero (SureShare);
\*    - weight w > 0 otherwise (U = 0 included, and a small w against a large
\*      W, which floors to 0 gas units even with U >= 1 Ggas, host.rs:
\*      3501-3503): nearcore's share may be 0 or not (ZeroGasMaybe).  Both
\*      outcomes are kept: Verdict is "either", and Exec fails the creator or
\*      commits it; the child then runs with its floor of 0 Ggas and runs out
\*      of gas, as it does in nearcore with less gas than its burn.
\* The premise is the one of Share's "up" lower bound (N-precision).
ZeroGasKid(r, O) ==
    /\ GasMode = "gas"
    /\ \E c \in Kids(O) : \E k \in DOMAIN c.gs :
         IF NearFeeTable!FeeRounding = "up"
         THEN GasListsOK(c) /\ c.gs[k] = 0 /\ c.gw[k] = 0
         ELSE Alloc(r, O, c).g[k] = 0
\* U*10^9*w >= W without overflow (TLC integers are 32-bit): with
\* q = ceil(W / 10^9), at most 3, it is U*w >= q.  W is WSum over the
\* entries, so Share's U*w and W themselves must fit (weights up to about
\* 10^9 work only with small U).
SureShareUW(U, w, W) ==
    LET q == W \div 1000000000 + (IF W % 1000000000 = 0 THEN 0 ELSE 1)
    IN  U >= 1 /\ w >= 1 /\ (U >= q \/ w >= q \/ U * w >= q)
SureShare(r, O, c, k) == SureShareUW(LeftFor(r, O, c), c.gw[k], WSum(EntriesFor(r, O, c)))
ZeroGasMaybe(r, O) ==
    /\ GasMode = "gas"
    /\ NearFeeTable!FeeRounding = "up"
    /\ LET pa == PerAction(r, O)
           U0 == GasOf(r) - Need(r, O)
           W0 == WSum(Entries(O))
       IN \E c \in Kids(O) : \E k \in DOMAIN c.gs :
            /\ GasListsOK(c) /\ c.gs[k] = 0 /\ c.gw[k] > 0
            /\ ~IF pa THEN SureShare(r, O, c, k) ELSE SureShareUW(U0, c.gw[k], W0)

\* A receipt with several function-call actions and no pa would pool their
\* gas; that is only allowed with PooledGasOK.  A failing outcome without a
\* panic key does not use the gas, so it is exempt.
PoolCheck(r, O) ==
    IF GasMode # "gas" \/ Len(r.g) <= 1 \/ ("pa" \in DOMAIN O /\ O.pa # <<>>) \/ PooledGasOK
       \/ (O.err # "" /\ ~HasPanicKey(O)) THEN TRUE
    ELSE Assert(FALSE, <<"receipt with several function calls but no pa (per-action gas); PooledGasOK <- TRUE to pool", r.to, r.m>>)

\* Promises per function-call action (R6).  A call's promises are the
\* receipts it creates (Kids) and its promise_and calls: each pushes one
\* promise (host.rs:2486-2535), a nested one too.  The model does not see
\* promise_and calls.  OJoins(O, n) states them for the call, or a field nj
\* in each pa record for a receipt of several calls; without them the
\* model counts one per joint callback (NJoins), which is exact when each
\* promise_and feeds one callback directly.  Nested over n inputs they can
\* be up to n - 1 (MaxJoins, assuming each joins two promises or more), so
\* where that could cross the limit and the count is not stated, the model
\* asserts.  A promise_and that no callback uses, or that joins a single
\* promise, is past that bound: state the count.  The limit is per call:
\* in a receipt of several function calls the model counts each call's
\* children as pa partitions them (Partitioned, in either mode), and
\* asserts without pa when the receipt's total could cross it.
NJoins(S) == Cardinality({c \in S : IsJoint(c)})
JoinsUpTo(J) == RcptSum(LAMBDA c : IF Len(c.ins) > 2 THEN Len(c.ins) - 1 ELSE 1, J)
MaxJoins(S) == JoinsUpTo({c \in S : IsJoint(c)})
PromiseCount(S) == Cardinality(S) + NJoins(S)
\* The joins a record states (OJoins, or nj in a pa record), or -1.
StatedJoins(R) == IF "nj" \in DOMAIN R THEN R.nj ELSE -1
\* A stated count is at least the joint callbacks of the call's children S:
\* each is the .then of at least one promise_and.  Below that (or negative)
\* is a modelling error, so the model asserts before using it.
JoinsFieldOK(S, R) ==
    IF "nj" \notin DOMAIN R \/ R.nj >= NJoins(S) THEN TRUE
    ELSE Assert(FALSE, <<"a stated promise_and count (OJoins, or nj in a pa record) below the joint callbacks"
                         \o " the call creates, each of which needs one", R.nj, NJoins(S)>>)
\* Does the call that creates S, with nj joins stated (-1: none), go over?
CallPromisesOver(S, nj) ==
    IF Cardinality(S) + (IF nj >= 0 THEN nj ELSE NJoins(S)) > MaxPromisesPerCall THEN TRUE
    ELSE IF nj < 0 /\ Cardinality(S) + MaxJoins(S) > MaxPromisesPerCall
    THEN Assert(FALSE, <<"receipts and joint callbacks within reach of max_promises_per_function_call_action (1024)"
                         \o " if promise_and is nested (each promise_and is a promise); state the call's"
                         \o " promise_and count with OJoins(O, n), or nj in its pa record", PromiseCount(S), MaxJoins(S)>>)
    ELSE FALSE
\* pa as the children of each call, in fault mode as in gas mode (where it
\* is also PerAction's): one record per call, disjoint, every child in one.
PAPartOK(r, O) ==
    IF Len(O.pa) # NCalls(r)
    THEN Assert(FALSE, <<"pa has", Len(O.pa), "records but the receipt has", NCalls(r), "function calls", r.m>>)
    ELSE IF \E i, j \in DOMAIN O.pa : i < j /\ O.pa[i].kids \cap O.pa[j].kids # {}
    THEN Assert(FALSE, <<"pa kid sets overlap", r.m>>)
    ELSE IF \E c \in Kids(O) : ~\E k \in DOMAIN O.pa : c.id \in O.pa[k].kids
    THEN Assert(FALSE, <<"a child is in no pa record", r.m>>)
    ELSE TRUE
Partitioned(r, O) ==
    IF GasMode = "gas" THEN PerAction(r, O) /\ PAPartOK(r, O)
    ELSE "pa" \in DOMAIN O /\ Len(O.pa) > 1 /\ PAPartOK(r, O)
\* Every join the outcome states, for the bound checked first.
PAJoins(O) == IF "pa" \in DOMAIN O
              THEN SumSeq([k \in DOMAIN O.pa |-> IF "nj" \in DOMAIN O.pa[k] THEN O.pa[k].nj ELSE 0])
              ELSE 0
\* The stated counts are checked first: an outcome-level one against all
\* of the children (and only for a receipt of one call: several calls state
\* theirs in pa), each pa one for being >= 0 here and against its call's
\* children once pa is read.
JoinsStatedOK(r, O) ==
    /\ IF "nj" \in DOMAIN O /\ NCalls(r) > 1
       THEN Assert(FALSE, <<"OJoins on a receipt of several function calls: state each call's count as nj in its pa record", r.m>>)
       ELSE JoinsFieldOK(Kids(O), O)
    /\ "pa" \in DOMAIN O => \A k \in DOMAIN O.pa : JoinsFieldOK({}, O.pa[k])
PromisesOver(r, O) ==
    LET S == Kids(O) IN
    IF ~JoinsStatedOK(r, O) THEN FALSE
    ELSE IF Cardinality(S) + MaxJoins(S) + (IF "nj" \in DOMAIN O THEN O.nj ELSE 0) + PAJoins(O) <= MaxPromisesPerCall
    THEN FALSE        \* no call can go over: most outcomes stop here
    ELSE IF NCalls(r) <= 1 THEN CallPromisesOver(S, StatedJoins(O))
    ELSE IF Partitioned(r, O)
    THEN /\ \A k \in DOMAIN O.pa : JoinsFieldOK(ActKids(O, k), O.pa[k])
         /\ \E k \in DOMAIN O.pa : CallPromisesOver(ActKids(O, k), StatedJoins(O.pa[k]))
    ELSE Assert(FALSE, <<"a receipt of several function calls whose receipts and joins could exceed"
                         \o " max_promises_per_function_call_action (1024) in all; the limit is per call:"
                         \o " give the outcome pa (one record per call, its children in kids)", r.m, Cardinality(S)>>)

\* The first host-function limit the outcome O of r exceeds, or "" (see
\* "Protocol limits": joint inputs, promises per action, returned bytes,
\* logs).
HostLimitErr(r, O) ==
    CASE \E c \in Kids(O) : IsJoint(c) /\ Len(c.ins) > MaxJointInputs -> "NumberInputDataDependenciesExceeded"
      [] PromisesOver(r, O)                                   -> "NumberPromisesExceeded"
      [] RetTooLong(O)                                        -> "ReturnedValueLengthExceeded"
      [] LogsOver(r, O) /\ LogCount(O) > MaxLogs              -> "NumberOfLogsExceeded"
      [] LogsOver(r, O)                                       -> "TotalLogLengthExceeded"
      [] OTHER                                                -> ""
\* New-receipt validation, after the call succeeded: a receipt it creates
\* with more than 100 actions fails it (runtime/runtime/src/lib.rs:968-979,
\* NewReceiptValidationError; runtime/runtime/src/action_validation.rs
\* :104-109), and the call's receipts are dropped.
NewRcptLimitErr(O) == \E c \in Kids(O) : NActs(c) > MaxActionsPerReceipt

\* "ok" | "fail" (panic, action error, balance) | "oog" (ran out of its real gas)
\* | "either" (gas mode, "up": a child's gas may be 0 in nearcore or not,
\* ZeroGasMaybe; the receipt commits or fails, and Exec takes both).
\* Order: a call receipt's account actions come first (AcCallErr: the
\* CreateAccount, Transfer and key actions before the call fail it before
\* it starts; the DeleteAccount after it is checked on the state after the
\* call); then the receiver check (the call never starts); a panic
\* the gas could not reach is "oog"; a host-function limit (HostLimitErr)
\* fails the call as a panic does; new-receipt validation (a zero-gas
\* child, more than 100 actions) and the storage check run after the call
\* (an unaffordable receipt fails either way).  A
\* Delegate receipt runs no code: a dispatcher that hands one to a contract
\* handler is a modelling error (an Assert).
Verdict(r, O) ==
    IF IsDeleg(r) THEN Assert(FALSE, <<"DELEGATE receipt passed to Exec; run it with NearKeys' ExecDelegate", r.id>>)
    ELSE IF IsAcctRcpt(r) THEN Assert(FALSE, <<"ACCOUNT receipt passed to Exec; run it with ExecAcct (NearKeys: ExecAcctK)", r.id>>)
    ELSE IF AcCall(r) /\ AcCallErr(r, O) # "" THEN "fail"
    ELSE IF ~PoolCheck(r, O) THEN "fail"
    ELSE IF ~CallTargetOK(r) THEN "fail"
    ELSE IF O.err # "" THEN (IF PanicOOG(r, O) THEN "oog" ELSE "fail")
    ELSE IF HostLimitErr(r, O) # "" THEN "fail"
    ELSE IF ~GasOK(r, O) THEN "oog"
    ELSE IF ZeroGasKid(r, O) THEN "fail"
    ELSE IF NewRcptLimitErr(O) THEN "fail"
    ELSE IF ~Affordable(r, O) THEN "fail"
    ELSE IF ZeroGasMaybe(r, O) THEN "either"
    ELSE "ok"

\* Why a receipt fails: Verdict's branches in Verdict's order, as nearcore's
\* error name where there is one (F2).  "" when the verdict is "ok".
FailWhy(r, O) ==
    IF AcCall(r) /\ AcCallErr(r, O) # "" THEN AcCallErr(r, O)
    ELSE IF ~CallTargetOK(r) THEN "AccountDoesNotExist, AccountNotInitialized or CodeDoesNotExist"
    ELSE IF O.err # "" THEN (IF PanicOOG(r, O) THEN "out of gas before its panic" ELSE "panic: " \o O.err)
    ELSE IF HostLimitErr(r, O) # "" THEN HostLimitErr(r, O)
    ELSE IF ~GasOK(r, O) THEN
        (IF TrieGas(O) > 0 /\ GasOK(r, [O EXCEPT !.trg = 0]) THEN "out of gas (worst-case trie depth)"
         ELSE "out of gas")
    ELSE IF ZeroGasKid(r, O) THEN "FunctionCallZeroAttachedGas"
    ELSE IF NewRcptLimitErr(O) THEN "NewReceiptValidationError: TotalNumberOfActionsExceeded"
    ELSE IF ~Affordable(r, O) THEN "LackBalanceForState or BalanceExceeded"
    ELSE IF ZeroGasMaybe(r, O) THEN "FunctionCallZeroAttachedGas (a share that may be 0 gas)"
    ELSE ""
\* The gas a receipt that ran out needed, for the report: Need, or the
\* largest action's need under pa; 0 when it did not run out for gas.
OogNeed(r, O) ==
    IF GasMode # "gas" \/ O.err # "" \/ GasOK(r, O) THEN 0
    ELSE IF PerAction(r, O)
    THEN LET short == {k \in DOMAIN O.pa : ActGas(r, k) < ActNeed(O, k)}
             k0 == CHOOSE k \in short : \A j \in short : k <= j IN ActNeed(O, k0)
    ELSE Need(r, O)

\* Outcome log (conformance).  st: "ok" | "fail" | "oog" | "forced"
LogR(r, st) ==
    IF LogOn THEN rlog \cup {[tx |-> r.tx, id |-> r.id, m |-> r.m, to |-> r.to, st |-> st, g |-> GasOf(r)]}
    ELSE rlog

\* Which kind of failure a behaviour contains: "forced" (the switch fired),
\* "caller-gas" (a real out-of-gas), else "no-fault".
Label == IF fails > 0 THEN "forced" ELSE IF oog # {} THEN "caller-gas" ELSE "no-fault"

----------------------------------------------------------------------------
\* Commit of a call receipt with account actions (AcCall): the call's
\* commit, plus the account actions' effects as in ExecAcctWith.  The
\* payout of a DeleteAccount gets the id after the call's children.  With a
\* DeleteAccount last, the receipt's result is that action's, empty bytes,
\* whatever the call returned (ActionResult::merge keeps the last action's
\* result, lib.rs:507-513; ReturnData::None gives the callback empty bytes,
\* :1172-1175, and the status SuccessValue([]), :1245).  A call that
\* returns a promise there keeps its children, but the promise is not the
\* result: the receipt's output receivers are not forwarded to it
\* (lib.rs:1146-1189), so a child the handler wired to r.cb (tail.cb :=
\* r.cb) gets cb 0 (Unfwd).  Sim: lifecycle.rs promise_call_then_delete.
CommitAc(r, O) ==
    LET a == r.to  mk == r.ac.mk  b == r.ac.bnf  bal == AcBal(r, O)
        pay == b # "" /\ bal > 0
        Unfwd(c) == IF b # "" /\ r.cb # 0 /\ c.cb = r.cb THEN [c EXCEPT !.cb = 0] ELSE c IN
    /\ Assert(~mk \/ near[a] = 0, <<"CreateAccount of an account whose near is not 0", a, near[a]>>)
    /\ Assert(r.ac.ka = <<>> \/ "kf" \in DOMAIN O,
              <<"call receipt with key actions run with Exec; run it with NearKeys' ExecK", r.id>>)
    /\ rq'   = RemR(r) \cup {InstantTag(Unfwd(c)) : c \in Give(r, O, O.ready)}
                     \cup (IF pay THEN {Rcpt(nid + O.ids, r.tx, b, "system", REFND, r.a, bal, b, 0)} ELSE {})
    /\ post' = RemP(r) \cup {InstantTagP(Unfwd(c)) : c \in Give(r, O, O.post)}
    /\ data' = RemD(r) \cup (IF b # "" THEN DataOf(r, TRUE, EMPTY)
                            ELSE IF O.ret.k = "val" THEN DataOfLen(r, TRUE, O.ret.v, RetSz(O), RetLen(O)) ELSE {})
                     \cup ResumeData(r, O)
    /\ near' = [near EXCEPT ![a] = IF b # "" THEN 0 ELSE bal]
    /\ nid'  = nid + O.ids + (IF pay THEN 1 ELSE 0)
    /\ rlog' = LogR(r, "ok")
    /\ stor' = IF ~StoragePerByte THEN stor ELSE [stor EXCEPT ![a] = IF b # "" THEN 0 ELSE AcBytes(r, O)]
    /\ created' = IF mk THEN created \cup {a} ELSE created
    /\ deleted' = IF b # "" THEN deleted \cup {a} ELSE IF mk THEN deleted \ {a} ELSE deleted
    /\ code' = CodeNext(r)
    /\ guse' = UsesNext(r)
    /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, burnt, blk, gcode, gnonce, ofail>>

\* Commit: platform part.  The contract conjoins its own state update.
Commit(r, O) ==
    IF AcCall(r) THEN CommitAc(r, O) ELSE
    /\ rq'   = RemR(r) \cup {InstantTag(c) : c \in Give(r, O, O.ready)}
    /\ post' = RemP(r) \cup {InstantTagP(c) : c \in Give(r, O, O.post)}
    /\ data' = RemD(r) \cup (IF O.ret.k = "val" THEN DataOfLen(r, TRUE, O.ret.v, RetSz(O), RetLen(O)) ELSE {})
                     \cup ResumeData(r, O)
    /\ near' = [near EXCEPT ![r.to] = @ + r.dep - O.out]
    /\ nid'  = nid + O.ids
    /\ rlog' = LogR(r, "ok")
    /\ stor' = IF StoragePerByte /\ StorDelta(O) # 0 THEN [stor EXCEPT ![r.to] = StorAfter(r, O)] ELSE stor
    /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, created, burnt, blk, deleted, code, gcode, guse, gnonce, ofail>>

\* r's marks when it runs (F2): a subset of {"owed", "detached"}; a receipt
\* can carry both, and each check reads its own.
MarkedIn(S, r) == r.m \in S \/ CallKey(r.to, r.m) \in S
MarksOf(r) ==
    (IF \/ "owed" \in DOMAIN r /\ r.owed
        \/ IsCall(r) /\ r.fr = r.to /\ MarkedIn(OwedMethods, r) /\ \E p \in post : p.id = r.id
     THEN {"owed"} ELSE {})
    \cup
    (IF \/ "dtch" \in DOMAIN r /\ r.dtch
        \/ IsCall(r) /\ MarkedIn(DetachedMethods, r)
     THEN {"detached"} ELSE {})

\* Fail: receipt state reverted; deposit refunded; callback gets Failed.
\* lbl: "fail" (panic, action error), "forced" (MayFail switch), "oog" (real gas).
\* why: the cause, for ofail (FailWhy); need: the gas it needed when it ran
\* out (OogNeed), else 0.  A marked receipt (MarksOf) is recorded in ofail
\* as [tx, id, to, m, k (its marks, a set), why, g (its attached gas), need, a].
\* FailWhyLK with keep: record r in ofail even when unmarked (k = {}), so
\* that Ok can tell a failure from a commit by r's id (TrieSplit).
FailWhyLK(r, lbl, why, need, keep) ==
    /\ rq'   = RemR(r) \cup (IF DepTotal(r) > 0
                             THEN {Rcpt(nid, r.tx, r.rto, "system", REFND, r.a, DepTotal(r), r.rto, 0)}
                             ELSE {})
    /\ post' = RemP(r)
    /\ data' = RemD(r) \cup DataOf(r, FALSE, 0)
    /\ nid'  = nid + 1
    /\ fails' = IF lbl = "forced" THEN fails + 1 ELSE fails
    /\ oog'   = IF lbl = "oog" THEN oog \cup {<<r.tx, r.m>>} ELSE oog
    /\ rlog'  = LogR(r, lbl)
    /\ ofail' = LET k == MarksOf(r) IN
                IF k = {} /\ ~keep THEN ofail
                ELSE ofail \cup {[tx |-> r.tx, id |-> r.id, to |-> r.to, m |-> r.m, k |-> k, why |-> why,
                                  g |-> GasOf(r), need |-> need, a |-> r.a]}
    /\ UNCHANGED <<near, locked, proposal, epoch, paid, minted, txsig, created, burnt, blk, stor, deleted, code, gcode, guse, gnonce>>
FailWhyL(r, lbl, why, need) == FailWhyLK(r, lbl, why, need, FALSE)
FailL(r, lbl) == FailWhyL(r, lbl, lbl, 0)

FailP(r, gas) == FailL(r, IF gas THEN "forced" ELSE "fail")
FailOOG(r)    == FailL(r, "oog")

\* The generic runner.  Platform part only; the caller conjoins, after Exec,
\*   IF Ok(r, O) THEN <its own state := O's> ELSE UNCHANGED <its state>.
\* For "either" Exec has two successors, and Ok tells which one this step
\* took by reading the primed platform state: the commit created r's
\* children (fresh ids, so no other receipt equals one), the failure none.
\* So Ok must come after Exec in the same action; written as membership in
\* rq' / post', it is an error (not an assignment) if it comes first.
Committed(r, O) == \/ \E c \in O.ready : InstantTag(Alloc(r, O, c)) \in rq'
                   \/ \E c \in O.post : InstantTagP(Alloc(r, O, c)) \in post'
\* Under TrieSplit, Exec takes the outcome at every trie gas (G6), so the
\* verdict alone does not say which successor this step is, and a receipt
\* with no children leaves no trace in rq' / post': every failure branch
\* then records r in ofail (keep), and Ok reads that.
Ok(r, O) ==
    IF TrieSplit(O) THEN ~\E x \in ofail' : x.id = r.id
    ELSE LET v == Verdict(r, O) IN
         IF v = "either" THEN Committed(r, O) ELSE v = "ok"
ExecKeep(r, O, keep) ==
    LET v == Verdict(r, O) IN
    IF v = "ok" THEN Commit(r, O)
    ELSE IF v = "oog" THEN FailWhyLK(r, "oog", FailWhy(r, O), OogNeed(r, O), keep)
    ELSE IF v = "either" THEN Commit(r, O) \/ FailWhyLK(r, "fail", FailWhy(r, O), 0, keep)
    ELSE FailWhyLK(r, "fail", FailWhy(r, O), 0, keep)
\* The runner's audit (tools/run.py, docs/USAGE.md "Auditing what the runs
\* reach"): with AuditOn, Exec prints one AUDIT tuple per distinct fact about
\* a receipt it runs: its account and method, whether it is owed, detached or
\* a callback, the gas mode, TrieGasWorst, whether its static gas is known and
\* its weight 0 (a fixed budget), its outcome's declared logs (count, bytes)
\* and trie nodes, and whether the library's own token implementation ran it
\* (ExecLib, from TokStep and MtStep).  The runner sets AuditOn and
\* initialises register AuditReg, which keeps the facts already printed; off
\* (the default), Exec is as before.
AuditOn  == FALSE
AuditReg == 41
AuditFact(r, O, lib) ==
    LET gs == IF "gs" \in DOMAIN r THEN r.gs ELSE <<>>
        gw == IF "gw" \in DOMAIN r THEN r.gw ELSE <<>>
        k  == MarksOf(r)
    IN <<"AUDIT", r.to, r.m, "owed" \in k, "detached" \in k, \E p \in post : p.id = r.id,
         GasMode, TrieGasWorst, Len(gs) > 0, Len(gs) > 0 /\ SumSeq(gw) = 0,
         LogCount(O), LogBytes(O), TrieNodes(O), lib>>
AuditNote(r, O, lib) ==
    IF ~AuditOn THEN TRUE
    ELSE LET f == AuditFact(r, O, lib) IN
         IF f \in TLCGet(AuditReg) THEN TRUE
         ELSE PrintT(f) /\ TLCSet(AuditReg, TLCGet(AuditReg) \cup {f})
ExecAs(r, O, lib) ==
    /\ AuditNote(r, O, lib)
    /\ IF TrieSplit(O)
       THEN IF "pa" \in DOMAIN O /\ Len(O.pa) > 1
            THEN Assert(FALSE, <<"OWriteKey with per-action accounting (pa) is not supported", r.m>>)
            ELSE \E n \in TrieNodeRange(O) : ExecKeep(r, [trg |-> TrieGasAt(n)] @@ O, TRUE)
       ELSE ExecKeep(r, O, FALSE)
Exec(r, O)    == ExecAs(r, O, FALSE)
ExecLib(r, O) == ExecAs(r, O, TRUE)

\* The forced-fault switch as one step (the contract conjoins UNCHANGED of its vars).
ForcedFail(r) == /\ fails < MaxFails /\ r.m \in MayFail /\ FailWhyL(r, "forced", "forced fault (MayFail)", 0)

----------------------------------------------------------------------------
(* Built-in receipt execution (no contract code; no gas of their own).     *)

\* Transfer / refund: credit the receiver; result data (empty bytes) to the
\* callback if any.  A Transfer to a missing implicit account creates it
\* (actions.rs:221-290).  Eth-implicit creation attaches a protocol-defined
\* global contract (HasCode stays TRUE); the other created kinds have no code,
\* so calls to them fail.  NEAR-implicit creation adds a full-access key:
\* NearKeys.ExecTransferK adds it to keys (ImplicitKeyId); ExecTransfer
\* alone leaves keys to the model.  With StoragePerByte its bytes are counted
\* (CreatedBytes).  A credit never needs a storage check: it keeps a covered
\* account covered (StorageCovered).  A deleted implicit account is created
\* again the same way (actions.rs:842-849, :929-946; sim: conformance/
\* tests/lifecycle.rs, receipts_to_deleted), so it leaves deleted.
ExecTransfer(r) ==
    /\ r.m \in {XFER, REFND}
    /\ \/ AcctExists(r.to)
       \/ r.m = XFER /\ IsImplicit(r.to)
    /\ rq'   = RemR(r)
    /\ post' = RemP(r)
    /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)
    /\ near' = [near EXCEPT ![r.to] = @ + r.dep]
    /\ paid' = [paid EXCEPT ![r.tx][r.to] = @ + r.dep]
    /\ rlog' = LogR(r, "ok")
    /\ created' = IF AcctExists(r.to) THEN created ELSE created \cup {r.to}
    /\ deleted' = IF AcctExists(r.to) THEN deleted ELSE deleted \ {r.to}
    /\ stor' = IF StoragePerByte /\ ~AcctExists(r.to) THEN [stor EXCEPT ![r.to] = CreatedBytes(r.to)] ELSE stor
    /\ UNCHANGED <<locked, proposal, epoch, nid, fails, minted, oog, txsig, burnt, blk, code, gcode, guse, gnonce, ofail>>

\* A refund to a missing account fails and its amount is burnt
\* (lib.rs:1046-1054); refunds never create accounts (actions.rs:930-933).
RefundBurn(r) ==
    /\ rq'    = RemR(r)
    /\ post'  = RemP(r)
    /\ data'  = RemD(r) \cup DataOf(r, FALSE, 0)
    /\ burnt' = burnt + r.dep
    /\ rlog'  = LogR(r, "fail")
    /\ UNCHANGED <<near, locked, proposal, epoch, nid, fails, paid, minted, oog, txsig, created, blk, stor, deleted, code, gcode, guse, gnonce, ofail>>

\* A Transfer to a missing named account fails (AccountDoesNotExist,
\* actions.rs:842-850); the deposit is refunded to r.rto and the callback
\* sees Failed.  A refund to a missing account is burnt.
ExecTransferFail(r) ==
    /\ ~AcctExists(r.to)
    /\ \/ r.m = XFER /\ ~IsImplicit(r.to) /\ FailWhyL(r, "fail", "AccountDoesNotExist", 0)
       \/ r.m = REFND /\ BurnLostRefunds /\ RefundBurn(r)

\* Stake action (actions.rs:58-109): the account must exist
\* (AccountDoesNotExist, actions.rs:874-879; a deleted StakingAcct), the
\* actor must be the account itself (actions.rs:755-801, ActorNoPermission);
\* then TriesToStake (liquid below
\* the increment), TriesToUnstake, InsufficientStake.  Storage is checked
\* after the receipt with liquid + locked, which staking does not change.
StakeFails(amt) ==
    LET inc == IF amt > locked THEN amt - locked ELSE 0 IN
    \/ near[StakingAcct] < inc                                \* TriesToStake
    \/ (locked = 0 /\ amt = 0)                               \* TriesToUnstake
    \/ (amt > 0 /\ amt < MinStake)                           \* InsufficientStake

ExecStake(r) ==
    /\ r.m = STAKE
    /\ Assert(r.to = StakingAcct, <<"Stake receipt for an account other than StakingAcct", r.to>>)
    /\ LET amt == r.a.x1
           inc == IF amt > locked THEN amt - locked ELSE 0 IN
       IF ~AcctExists(r.to) \/ r.fr # r.to \/ StakeFails(amt)
       THEN FailP(r, FALSE)
       ELSE /\ rq'   = RemR(r)
            /\ post' = RemP(r)
            /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)      \* no return value: empty bytes (lib.rs:1172-1176)
            /\ near' = [near EXCEPT ![StakingAcct] = @ - inc]
            /\ locked' = IF amt > locked THEN amt ELSE locked
            /\ proposal' = amt
            /\ rlog' = LogR(r, "ok")
            /\ UNCHANGED <<epoch, nid, fails, paid, minted, oog, txsig, created, burnt, blk, stor, deleted, code, gcode, guse, gnonce, ofail>>

\* A global contract's distribution receipt (A10): it publishes its code
\* under its identifier unless a later deploy's distribution got there
\* first.  Its nonce is its id, so a later deploy's is larger; the code is
\* set iff the nonce is above the last one applied for the identifier
\* (global_contracts.rs:191-246, the check at :251-269).  The model's
\* network keeps no order, so two distributions of one identifier can
\* arrive either way: the later deploy wins, and the earlier code may be
\* published briefly first (nearcore: on a shard other than the deployer's;
\* on the deployer's own, the nonce is bumped at deploy time, :175-189, and
\* the earlier one is dropped).  It runs whether or not the owner still
\* exists (sim: redeploy_updates_users), has no result and no outcome entry
\* (rlog), and costs no gas (its compute, 84.yaml:39-40, is chunk-level).
GNonceOf(g) == IF g \in DOMAIN gnonce THEN gnonce[g] ELSE 0
ExecGDist(r) ==
    /\ r.m = GDIST
    /\ LET g == r.a.g  fresh == r.id > GNonceOf(g) IN
       /\ rq'     = RemR(r)
       /\ gcode'  = IF fresh THEN (g :> r.a.t) @@ gcode ELSE gcode
       /\ gnonce' = IF fresh THEN (g :> r.id) @@ gnonce ELSE gnonce
    /\ UNCHANGED <<post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog, rlog,
                   txsig, created, burnt, blk, stor, deleted, code, guse, ofail>>

\* All built-in receipts as one step (the contract conjoins UNCHANGED of its vars).
ExecBuiltin(r) == ExecTransfer(r) \/ ExecTransferFail(r) \/ ExecStake(r) \/ ExecGDist(r)

\* A function call whose receiver is missing or has no code fails before
\* any contract code runs.  Exec does this already (Verdict); this step lets
\* a dispatcher handle such receipts without calling a handler.
ExecNoCode(r) == IsCall(r) /\ ~CallTargetOK(r)
                 /\ FailWhyL(r, "fail", "AccountDoesNotExist, AccountNotInitialized or CodeDoesNotExist", 0)

----------------------------------------------------------------------------
(* Account lifecycle, continued: ACCOUNT receipts (ExecAcct).            *)
\* The storage check after the actions (lib.rs:1008-1031), skipped when the
\* receipt deleted the account (:1010).  AcctBal: the liquid after the
\* actions.
AcctStorOK(r, kb) ==
    IF r.ac.bnf # "" THEN TRUE
    ELSE IF StoragePerByte
    THEN StorageCovers(AcctBal(r) + LockedOf(r.to), AcctBytes(r, kb))
    ELSE AcctBal(r) + LockedOf(r.to) >= StorageFloor[r.to]
AcctOK(r, kb, kok) == AcctErr(r, kb, kok) = "" /\ AcctStorOK(r, kb)

\* Run an ACCOUNT receipt; kb, kok as for AcctErr.  On success:
\*  create: the account starts with 0 balance, no code and 100 bytes
\*    (actions.rs:202-208), then gets the deposit; it joins created and
\*    leaves deleted;
\*  delete: its liquid goes out as a refund receipt from "system" to the
\*    beneficiary, a separate receipt that runs later (actions.rs:380-386),
\*    if it is > 0: ExecTransfer credits a beneficiary that exists, and
\*    RefundBurn burns it otherwise (a refund never creates an account,
\*    lib.rs:1046-1054; the beneficiary may be the account itself).  The
\*    account's balance, bytes and keys go (core/store/src/utils/mod.rs
\*    :504-575); it joins deleted.  Its postponed receipts, data and
\*    yields stay (D4): they fail while it is deleted and run on the new
\*    account if it is created again.  The model wipes its own state
\*    (DeletesAcct);
\*  the callback gets empty bytes (lib.rs:1172-1176).
\* On failure the receipt fails as a whole (lib.rs:946-1005): FailP refunds
\* the deposit to r.rto (the creator) and the callback gets Failed.
ExecAcctWith(r, kb, kok) ==
    /\ IsAcctRcpt(r)
    /\ LET a == r.to  mk == r.ac.mk  b == r.ac.bnf  bal == AcctBal(r)
           pay == b # "" /\ bal > 0
           dg == DgTag(r) # NoCode
           dist == dg /\ ~GlobalInstant
           did == IF pay THEN nid + 1 ELSE nid IN
       IF AcctOK(r, kb, kok)
       THEN /\ Assert(~mk \/ near[a] = 0, <<"CreateAccount of an account whose near is not 0", a, near[a]>>)
            /\ rq'   = RemR(r) \cup (IF pay THEN {Rcpt(nid, r.tx, b, "system", REFND, r.a, bal, b, 0)} ELSE {})
                             \cup (IF dist THEN {DistRcpt(did, r)} ELSE {})
            /\ post' = RemP(r)
            /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)
            /\ near' = [near EXCEPT ![a] = IF b # "" THEN 0 ELSE bal]
            /\ nid'  = did + (IF dist THEN 1 ELSE 0)
            /\ burnt' = burnt + GBurn(r)
            /\ guse' = UsesNext(r)
            /\ gcode' = IF dg /\ GlobalInstant THEN (DgId(r) :> DgTag(r)) @@ gcode ELSE gcode
            /\ rlog' = LogR(r, "ok")
            /\ created' = IF mk THEN created \cup {a} ELSE created
            /\ deleted' = IF b # "" THEN deleted \cup {a} ELSE IF mk THEN deleted \ {a} ELSE deleted
            /\ stor' = IF ~StoragePerByte THEN stor
                       ELSE [stor EXCEPT ![a] = IF b # "" THEN 0 ELSE AcctBytes(r, kb)]
            /\ code' = CodeNext(r)
            /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, blk, gnonce, ofail>>
       ELSE FailP(r, FALSE)
\* Without key actions (NearKeys.ExecAcctK runs them).
ExecAcct(r) ==
    /\ IsAcctRcpt(r)
    /\ Assert(r.ac.ka = <<>>, <<"ACCOUNT receipt with key actions: run it with NearKeys' ExecAcctK", r.id>>)
    /\ ExecAcctWith(r, 0, TRUE)

\* Did this step delete r.to?  A primed read, like Ok: conjoin it after
\* ExecAcct / ExecAcctK, to reset the model's own state for the account
\* (N-wipe), e.g. bal' = IF DeletesAcct(r) THEN 0 ELSE ...
DeletesAcct(r) == r.to \in deleted' \ deleted

----------------------------------------------------------------------------
(* Epochs and blocks                                                       *)

\* Epoch transition: rewards go to locked; a decreased proposal releases the
\* difference to liquid.  Scaled: the release happens on the next tick
\* (nearcore returns unstaked funds once the stake leaves the validator set,
\* a few epochs later).
EpochTick ==
    /\ ~InstantPending
    /\ epoch < MaxEpoch
    /\ \E rw \in 0..(IF locked > 0 THEN MaxReward ELSE 0) :
         LET newLocked == IF proposal < locked THEN proposal ELSE locked
             release   == locked - newLocked IN
         /\ epoch'  = epoch + 1
         /\ locked' = newLocked + rw
         /\ near'   = [near EXCEPT ![StakingAcct] = @ + release]
         /\ minted' = minted + rw
    /\ UNCHANGED <<rq, post, data, proposal, nid, fails, paid, oog, rlog, txsig, created, burnt, blk, stor, deleted, code, gcode, guse, gnonce, ofail>>

\* Block clock: one block passes (the model adds BlockTick /\ UNCHANGED of its
\* own variables to Next).  Every receipt that runs at one value of blk sees
\* that height (env::block_height(), runtime/near-vm-runner/src/logic/host.rs:827;
\* env::block_timestamp() is BlockTs, :837).  Heights only grow.  With
\* TickAnytime = FALSE a block passes only while some yield's deadline is
\* ahead.  Independent of EpochTick (env::epoch_height(), :847).
BlockTick ==
    /\ ~InstantPending
    /\ blk < MaxBlk
    /\ TickAnytime \/ \E p \in post : IsYield(p) /\ p.ydl > blk
    /\ blk' = blk + 1
    /\ UNCHANGED <<rq, post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog,
                   rlog, txsig, created, burnt, stor, deleted, code, gcode, guse, gnonce, ofail>>
BlockTs == TsOf(blk)

----------------------------------------------------------------------------
(* Transactions                                                            *)

\* Can account a sign the transaction whose first receipt is r?  It must pay
\* the deposit (NotEnoughBalance), and with StoragePerByte what is left must
\* still cover its storage (InvalidTxError::LackBalanceForState,
\* runtime/runtime/src/verifier.rs:375-386 in verify_and_charge_tx_ephemeral).
\* Gas money is not modelled (docs/SEMANTICS.md, N-gas-money).  A deleted
\* signer cannot sign (InvalidTxError::SignerDoesNotExist, verifier.rs
\* :170-175).  A scripted model branches on this rather than letting Submit
\* disable its step.  A transaction of more than 100 actions (a delegate's
\* inner actions too) is invalid (verifier.rs:92-104;
\* action_validation.rs:104-109, :266-272).
CanSubmit(r, a) ==
    /\ NActs(r) <= MaxActionsPerReceipt
    /\ IF IsDeleg(r) THEN NActs(r.a.inner) <= MaxActionsPerReceipt ELSE TRUE
    /\ a \notin deleted
    /\ near[a] >= DepTotal(r)
    /\ IF StoragePerByte THEN StorageCovers(near[a] - DepTotal(r) + LockedOf(a), stor[a]) ELSE TRUE

\* Submit a transaction signed by account a with key id k: its first receipt
\* (prepaid gas in r.g, see WithGas).  The signer pays the deposit now.  The
\* receipt is local iff signer = receiver (lib.rs:2316-2324).
SubmitAs(r, a, k) ==
    /\ ~InstantPending
    /\ CanSubmit(r, a)
    /\ rq'    = rq \cup {[r EXCEPT !.loc = (a = r.to)]}
    /\ near'  = [near EXCEPT ![a] = @ - DepTotal(r)]
    /\ nid'   = nid + 1
    /\ txsig' = IF TrackSigner THEN (r.tx :> [a |-> a, k |-> k]) @@ txsig ELSE txsig
    /\ UNCHANGED <<post, data, locked, proposal, epoch, fails, paid, minted, oog, rlog, created, burnt, blk, stor, deleted, code, gcode, guse, gnonce, ofail>>

\* A transaction signed by its predecessor r.fr with the default key.
Submit(r) == SubmitAs(r, r.fr, DefaultKey)

\* Local-receipt priority (lib.rs:2799-2821): a pending local receipt on an
\* account runs before any other receipt on that account.  Only a
\* transaction's first receipt is local; later self-calls are not
\* (lib.rs:1222-1234).
\* ON assumes no congestion: a local receipt that does not fit the chunk's
\* compute limit is delayed behind already-delayed receipts
\* (lib.rs:2513-2520), and then other receipts on the account can run
\* first.  OFF (not conjoining it) is the conservative setting: every
\* causally enabled order, including those reachable under congestion.
\* nearcore's order is chunk-wide (all local receipts first, for every
\* account); this rule only orders receipts of the same account, which
\* allows more orders than nearcore does.
\* An instant receipt (S5) precedes local ones: it runs right after its
\* creator, before the chunk's other receipts whatever their kind, so
\* LocalPriorityOK never holds it back.
\* Opt-in: conjoin LocalPriorityOK(r) to the receipt step, or draw r from Schedulable.
LocalPriorityOK(r) == IsInstant(r) \/ (~r.loc => ~\E y \in rq : y.loc /\ y.to = r.to)
Schedulable == {r \in Runnable : LocalPriorityOK(r)}

TxBusy(t) == \E x \in rq \cup post : x.tx = t
TxSettled(t) == ~TxBusy(t) /\ ~\E d \in data : d.tx = t
Idle == rq = {} /\ post = {} /\ data = {}

----------------------------------------------------------------------------
(* Init helpers                                                            *)

\* With StoragePerByte, every account's initial liquid + locked must cover
\* its StorageInit bytes: nearcore never leaves an account uncovered, and the
\* library checks storage only where it can be lost (a model error otherwise).
StorageInitOK(near0, locked0) ==
    IF ~StoragePerByte THEN TRUE
    ELSE \A a \in Accounts :
           IF StorageCovers(near0[a] + (IF a = StakingAcct THEN locked0 ELSE 0), StorageInit[a]) THEN TRUE
           ELSE Assert(FALSE, <<"StorageInit[a] exceeds what a's initial balance covers", a, StorageInit[a]>>)

\* Every platform variable.  near0: [Accounts -> Nat]; txIds: the domain of paid.
PlatformInitStaked(near0, locked0, txIds) ==
    /\ rq = {} /\ post = {} /\ data = {}
    /\ near = near0
    /\ locked = locked0 /\ proposal = locked0 /\ epoch = 0
    /\ nid = 1 /\ fails = 0 /\ minted = 0
    /\ paid = [t \in txIds |-> [a \in Accounts |-> 0]]
    /\ oog = {} /\ rlog = {}
    /\ txsig = <<>> /\ created = {} /\ burnt = 0 /\ deleted = {} /\ code = [x \in {} |-> NoCode] /\ blk = 0
    /\ gcode = InitGCode /\ guse = InitUses /\ gnonce = [g \in {} |-> 0]
    /\ stor = StorageInit /\ StorageInitOK(near0, locked0)
    /\ ofail = {}
PlatformInit(near0, txIds) == PlatformInitStaked(near0, 0, txIds)

\* Only the variables added in 0.1.0 and 0.2, for models that initialise the
\* others themselves.  The parts compose: a model with its own txsig
\* initialiser (e.g. a pre-sized function) conjoins PlatformInitAccounts,
\* PlatformInitClock, PlatformInitStorage and PlatformInitOwed alone.
\* PlatformInitAccounts also initialises ofail, so a model written before
\* ofail existed needs no change; PlatformInitOwed repeats it harmlessly.
\* PlatformInitStorage does not check the initial cover: list
\* StorageCovered as an invariant.
PlatformInitSigner   == txsig = <<>>
PlatformInitAccounts == created = {} /\ burnt = 0 /\ deleted = {} /\ code = [x \in {} |-> NoCode]
                        /\ gcode = InitGCode /\ guse = InitUses /\ gnonce = [g \in {} |-> 0]
                        /\ ofail = {}
PlatformInitClock    == blk = 0
PlatformInitStorage  == stor = StorageInit
PlatformInitOwed     == ofail = {}
PlatformInitExtra    == PlatformInitSigner /\ PlatformInitAccounts /\ PlatformInitClock
                        /\ PlatformInitStorage /\ PlatformInitOwed

----------------------------------------------------------------------------
(* Platform sanity                                                         *)

\* NEAR is conserved modulo rewards and burnt refunds.
NearConserved(total0) ==
    FunSum(near, Accounts) + locked + InflightDeposits = total0 + minted - burnt

\* No orphans: every postponed callback still has its data in flight or a
\* pending receipt that will deliver it (for each input of a joint
\* callback; a pending yield waits on a resume or its timeout), and every
\* data receipt has a waiting callback.  Receipts nobody can run show up as
\* a deadlock when a run sets deadlock = true (with a terminal stutter step
\* once idle).
NoOrphans ==
    /\ \A p \in post : \/ IsYield(p)
                      \/ \A i \in InIds(p) : (\E d \in data : d.to = i) \/ (\E x \in rq \cup post : x.cb = i)
    /\ \A d \in data : \E p \in post : d.to \in InIds(p)

\* With StoragePerByte, every account's liquid + locked covers its bytes.
\* The library keeps this from the initial state on (it checks storage after
\* every receipt that can lose it, and at submission); list it to check a
\* hand-written Init, or steps of the model's own that move NEAR.
StorageCovered ==
    IF StoragePerByte THEN \A a \in Accounts : StorageCovers(near[a] + LockedOf(a), stor[a]) ELSE TRUE

\* Owed and detached receipts (F2; WithOwed, OwedMethods, WithDetached,
\* DetachedMethods).  OwedOK: no owed callback has failed.  A violation's
\* last state shows the failure in ofail: which receipt (tx, id, to, m),
\* why (FailWhy: a panic and its message, "out of gas" with the gas it had
\* (g) and needed (need), a host limit such as NumberOfLogsExceeded or
\* ReturnedValueLengthExceeded, a forced fault, ...).  OwedFailed lists
\* them, e.g. for a print-only window.
OwedFailed == {x \in ofail : "owed" \in x.k}
OwedOK     == OwedFailed = {}
\* DetachedVoided(Voided(_)): once the transaction of a failed detached
\* receipt x has settled, Voided(x) holds: the model's own predicate that
\* the work x carried (read it from x.a, x.to, x.m) is neither executable
\* again nor counted as done or credited.  Before the transaction settles
\* a callback may still void it (the escrow that restores its claim).
DetachedFailed == {x \in ofail : "detached" \in x.k}
DetachedVoided(Voided(_)) == \A x \in DetachedFailed : TxSettled(x.tx) => Voided(x)

\* No pending yield's deadline lies past the clock bound.  When this fails,
\* some yield could time out before its deadline (at blk = MaxBlk, see
\* TimedOut), so a violation found in that run may be an artefact: raise
\* MaxBlk.  When it holds, no timeout in the run is premature.  It says
\* nothing about what the bound leaves out (ClockHorizonOK).  Trivially
\* TRUE without a clock.
YieldDeadlinesInBound == MaxBlk = 0 \/ \A p \in post : IsYield(p) => p.ydl <= MaxBlk

\* Clock horizon: does MaxBlk cover every behaviour of the model?  blk stops
\* at MaxBlk, so a guard of the model that only becomes TRUE past the bound
\* (a cancel window, a late timeout) never fires there, and a run that
\* passes says nothing about it: an under-approximation.  A check on the
\* constants (list it as an invariant; it fails in the initial state).
\* Assumption: every comparison with the clock (in handlers, guards and
\* invariants) is x - h >= c or its negation, with 0 <= c <= T and h <= x
\* each 0, blk, or a height recorded earlier in the behaviour (blk at some
\* step, a yield's creation).  Count blk > h + c and blk = h + c as c + 1, a
\* comparison with a yield's deadline (creation + YieldTicks) as
\* YieldTicks + c, and one of BlockTs as the height it needs.  n: the most
\* clock-relevant steps in one behaviour (steps that read or record blk or
\* BlockTs, yield creations, yield callbacks).
\* Argument.  An invariant fails in the last state of some behaviour on an
\* unbounded clock.  Let its clock-relevant steps run at heights
\* b1 <= .. <= bn and its last state be at bf >= bn; with b0 = 0 that is
\* n + 1 gaps.  Cut each gap to K = max(T, YieldTicks) blocks, dropping the
\* ticks at its end.  x - h is a sum of whole gaps: if none was cut it is
\* unchanged, otherwise it is >= K >= c before and after.  So every
\* handler, guard, timeout and invariant sees the same values; with
\* TickAnytime = FALSE a kept tick keeps its offset in its gap, so the
\* deadline it waits for is still ahead.  The cut behaviour ends at
\* bf <= (n + 1) * K: the + 1 is the final observation, the gap after the
\* last step.  Sufficient, not necessary.  Without a clock (MaxBlk = 0)
\* every gap is 0, which changes no comparison if T = 0; every yield may
\* then time out at any moment (more behaviours, not fewer).
\* (blk <= MaxBlk always holds; it makes this a state predicate, which TLC
\* reports as a violation rather than as an error at startup.)
ClockHorizonOK(n, T) ==
    /\ blk <= MaxBlk
    /\ IF MaxBlk = 0 THEN T = 0
       ELSE MaxBlk >= (n + 1) * (IF T > YieldTicks THEN T ELSE YieldTicks)

\* No receipt in flight holds more gas than its transaction's prepaid gas
\* (the split never creates gas).
GasBounded(prepaidOf(_)) ==
    GasMode = "gas" => \A x \in rq \cup post : GasOf(x) <= prepaidOf(x.tx)
=============================================================================
