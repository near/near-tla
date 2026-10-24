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
(*  The forced switch is kept in both modes: a receipt whose method is in  *)
(*  MayFail may fail, at most MaxFails times; counted in `fails`.  A real  *)
(*  out-of-gas is recorded in `oog`.                                       *)
(*                                                                         *)
(* Accounts are created and deleted by ACCOUNT receipts (CreateAccount,    *)
(* DeleteAccount; ExecAcct): see "Account lifecycle" below.  A lone       *)
(* DeleteAccount created by a receipt is instant (InstantFirst, S5).       *)
(*                                                                         *)
(* Not modelled: congestion (a local receipt that does not fit the chunk's *)
(* compute limit is delayed, lib.rs:2513-2521), gas price and gas refunds  *)
(* in NEAR, DeployContract (code is static, see Contracts), one receipt    *)
(* feeding several callbacks (cb is one id).                               *)
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
    deleted    \* accounts deleted by DeleteAccount and not created again since
\* Every platform variable must be initialised: use PlatformInit /
\* PlatformInitStaked, or conjoin PlatformInitExtra to an older Init.  TLC's
\* "current state is not a legal state" on the initial state, with a
\* platform variable such as txsig, blk, stor or deleted shown as null,
\* means PlatformInitExtra (or its parts PlatformInitSigner /
\* PlatformInitAccounts / PlatformInitClock / PlatformInitStorage) is missing.

platformVars == <<rq, post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog, rlog,
                  txsig, created, burnt, blk, stor, deleted>>

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

\* Built-in (non function-call) receipt kinds.
XFER  == "XFER"     \* Transfer action (may carry a callback)
REFND == "REFUND"   \* system refund receipt
STAKE == "STAKE"    \* Stake action on StakingAcct; a.x1 = amount
ADDK  == "ADDKEY"   \* AddKey action (executed by NearKeys)
DELK  == "DELKEY"   \* DeleteKey action (executed by NearKeys)
DELEG == "DELEGATE" \* Delegate action, NEP-366 (executed by NearKeys.ExecDelegate)
ACCT  == "ACCOUNT"  \* CreateAccount / DeleteAccount, with Transfer and AddKey (ExecAcct, NearKeys.ExecAcctK)
IsBuiltin(r) == r.m \in {XFER, REFND, STAKE}
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

RECURSIVE SumSeq(_)
SumSeq(s) == IF s = <<>> THEN 0 ELSE Head(s) + SumSeq(Tail(s))
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
\* inputs.  (A yield receipt is instant too; the model puts the yield in
\* post at its creator's commit, which is the same.)
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
IsInstantShape(c) ==
    /\ IsAcctRcpt(c)
    /\ ~c.ac.mk /\ c.ac.bnf # "" /\ c.ac.ka = <<>> /\ c.dep = 0
InstantTag(c) == IF InstantFirst /\ IsInstantShape(c) THEN [inst |-> TRUE] @@ c ELSE c
IsInstant(r) == "inst" \in DOMAIN r
InstantPending == InstantFirst /\ \E y \in rq : IsInstant(y)

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
Runnable == IF InstantPending THEN {y \in rq : IsInstant(y)} ELSE RunnableAll

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

Sum(S) == LET F[T \in SUBSET S] == IF T = {} THEN 0
                                   ELSE LET x == CHOOSE y \in T : TRUE IN x.dep + F[T \ {x}]
          IN F[S]

\* Ids are unique, so Sum over a set of receipts is well defined.
InflightDeposits == Sum(rq) + Sum(post)

\* Account existence: initial accounts and accounts created at run time,
\* unless deleted since (DeleteAccount; a later creation removes the id
\* from deleted again).
AcctExists(a) == (a \in Exists \/ a \in created) /\ a \notin deleted
\* Can a function call on a run?  An account created by a Transfer has no
\* code, except an eth-implicit one, which gets a protocol-defined global
\* contract (actions.rs:221-290); a universal one is also uninitialised
\* (UninitUniversal; actions.rs:880-887, AccountNotInitialized).
HasCode(a) == /\ AcctExists(a)
              /\ a \in Contracts
              /\ ~(a \in created /\ KindOf(a) # "eth_implicit")
\* A deleted receiver fails the call even with CallsNeedCode = FALSE
\* (AccountDoesNotExist, actions.rs:874-879).
CallTargetOK(r) == ~IsCall(r) \/ (r.to \notin deleted /\ (~CallsNeedCode \/ HasCode(r.to)))

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
Affordable(r, O) ==
    /\ near[r.to] + r.dep - O.out >= 0
    /\ IF StoragePerByte
       THEN StorageCovers(near[r.to] + r.dep - O.out + LockedOf(r.to), StorAfter(r, O))
       ELSE near[r.to] + r.dep - O.out + LockedOf(r.to) >= StorageFloor[r.to]

----------------------------------------------------------------------------
(* Need, verdict and the unused-gas split                                  *)
Kids(O) == O.ready \cup O.post

BurnKey(r, O) == IF O.gk = "" THEN r.m ELSE O.gk
Burn(r, O) ==
    LET k == BurnKey(r, O) IN
    IF k \in DOMAIN GasBurn THEN GasBurn[k].base + GasBurn[k].per * O.sz
    ELSE Assert(FALSE, <<"no GasBurn entry for", k>>)

RECURSIVE KidsCost(_)
KidsCost(S) == IF S = {} THEN 0
               ELSE LET c == CHOOSE y \in S : TRUE IN c.gf + SumSeq(c.gs) + KidsCost(S \ {c})

Need(r, O) == Burn(r, O) + KidsCost(Kids(O))

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
RECURSIVE WSum(_), FloorSum(_, _, _)
WSum(E) == IF E = {} THEN 0 ELSE LET e == CHOOSE y \in E : TRUE IN e[3] + WSum(E \ {e})
FloorSum(E, U, W) == IF E = {} THEN 0
                     ELSE LET e == CHOOSE y \in E : TRUE IN (U * e[3]) \div W + FloorSum(E \ {e}, U, W)
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
Share(e, U, E) ==
    LET W == WSum(E) IN
    IF NearFeeTable!FeeRounding = "up" THEN (U * e[3]) \div W
    ELSE IF e = LastE(E) THEN U - FloorSum(E \ {e}, U, W) ELSE (U * e[3]) \div W

Assign(c, U, E) ==
    IF ~GasListsOK(c) THEN c
    ELSE [c EXCEPT !.g = [k \in DOMAIN c.gs |->
                        c.gs[k] + (IF c.gw[k] > 0 /\ U > 0 THEN Share(<<c.id, k, c.gw[k]>>, U, E) ELSE 0)]]

\* The leftover U split over c's siblings: its action's under pa, else the receipt's.
LeftFor(r, O, c) ==
    IF PerAction(r, O) THEN LET k == ActOf(O, c) IN ActGas(r, k) - ActNeed(O, k)
    ELSE GasOf(r) - Need(r, O)
\* The weighted actions U is split over: those of c's action's children under pa.
EntriesFor(r, O, c) ==
    IF PerAction(r, O) THEN EntriesOf(ActKids(O, ActOf(O, c))) ELSE Entries(O)

\* A child with its attached gas, after the split.
Alloc(r, O, c) == Assign(c, LeftFor(r, O, c), EntriesFor(r, O, c))

Give(r, O, S) ==
    IF GasMode # "gas" THEN S ELSE {Alloc(r, O, c) : c \in S}

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
SureShare(r, O, c, k) ==
    LET U == LeftFor(r, O, c)
        w == c.gw[k]
        W == WSum(EntriesFor(r, O, c))
        q == W \div 1000000000 + (IF W % 1000000000 = 0 THEN 0 ELSE 1)
    IN  U >= 1 /\ w >= 1 /\ (U >= q \/ w >= q \/ U * w >= q)
ZeroGasMaybe(r, O) ==
    /\ GasMode = "gas"
    /\ NearFeeTable!FeeRounding = "up"
    /\ \E c \in Kids(O) : \E k \in DOMAIN c.gs :
         GasListsOK(c) /\ c.gs[k] = 0 /\ c.gw[k] > 0 /\ ~SureShare(r, O, c, k)

\* A receipt with several function-call actions and no pa would pool their
\* gas; that is only allowed with PooledGasOK.  A failing outcome without a
\* panic key does not use the gas, so it is exempt.
PoolCheck(r, O) ==
    IF GasMode # "gas" \/ Len(r.g) <= 1 \/ ("pa" \in DOMAIN O /\ O.pa # <<>>) \/ PooledGasOK
       \/ (O.err # "" /\ ~HasPanicKey(O)) THEN TRUE
    ELSE Assert(FALSE, <<"receipt with several function calls but no pa (per-action gas); PooledGasOK <- TRUE to pool", r.to, r.m>>)

\* "ok" | "fail" (panic, action error, balance) | "oog" (ran out of its real gas)
\* | "either" (gas mode, "up": a child's gas may be 0 in nearcore or not,
\* ZeroGasMaybe; the receipt commits or fails, and Exec takes both).
\* Order: the receiver check comes first (the call never starts); a panic
\* the gas could not reach is "oog"; new-receipt validation and the storage
\* check run after the call (an unaffordable receipt fails either way).  A
\* Delegate receipt runs no code: a dispatcher that hands one to a contract
\* handler is a modelling error (an Assert).
Verdict(r, O) ==
    IF IsDeleg(r) THEN Assert(FALSE, <<"DELEGATE receipt passed to Exec; run it with NearKeys' ExecDelegate", r.id>>)
    ELSE IF IsAcctRcpt(r) THEN Assert(FALSE, <<"ACCOUNT receipt passed to Exec; run it with ExecAcct (NearKeys: ExecAcctK)", r.id>>)
    ELSE IF ~PoolCheck(r, O) THEN "fail"
    ELSE IF ~CallTargetOK(r) THEN "fail"
    ELSE IF O.err # "" THEN (IF PanicOOG(r, O) THEN "oog" ELSE "fail")
    ELSE IF ~GasOK(r, O) THEN "oog"
    ELSE IF ZeroGasKid(r, O) THEN "fail"
    ELSE IF ~Affordable(r, O) THEN "fail"
    ELSE IF ZeroGasMaybe(r, O) THEN "either"
    ELSE "ok"

\* Outcome log (conformance).  st: "ok" | "fail" | "oog" | "forced"
LogR(r, st) ==
    IF LogOn THEN rlog \cup {[tx |-> r.tx, id |-> r.id, m |-> r.m, to |-> r.to, st |-> st, g |-> GasOf(r)]}
    ELSE rlog

\* Which kind of failure a behaviour contains: "forced" (the switch fired),
\* "caller-gas" (a real out-of-gas), else "no-fault".
Label == IF fails > 0 THEN "forced" ELSE IF oog # {} THEN "caller-gas" ELSE "no-fault"

----------------------------------------------------------------------------
\* Commit: platform part.  The contract conjoins its own state update.
Commit(r, O) ==
    /\ rq'   = RemR(r) \cup {InstantTag(c) : c \in Give(r, O, O.ready)}
    /\ post' = RemP(r) \cup Give(r, O, O.post)
    /\ data' = RemD(r) \cup (IF O.ret.k = "val" THEN DataOfLen(r, TRUE, O.ret.v, RetSz(O), RetLen(O)) ELSE {})
                     \cup ResumeData(r, O)
    /\ near' = [near EXCEPT ![r.to] = @ + r.dep - O.out]
    /\ nid'  = nid + O.ids
    /\ rlog' = LogR(r, "ok")
    /\ stor' = IF StoragePerByte /\ StorDelta(O) # 0 THEN [stor EXCEPT ![r.to] = StorAfter(r, O)] ELSE stor
    /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, created, burnt, blk, deleted>>

\* Fail: receipt state reverted; deposit refunded; callback gets Failed.
\* lbl: "fail" (panic, action error), "forced" (MayFail switch), "oog" (real gas).
FailL(r, lbl) ==
    /\ rq'   = RemR(r) \cup (IF r.dep > 0
                             THEN {Rcpt(nid, r.tx, r.rto, "system", REFND, r.a, r.dep, r.rto, 0)}
                             ELSE {})
    /\ post' = RemP(r)
    /\ data' = RemD(r) \cup DataOf(r, FALSE, 0)
    /\ nid'  = nid + 1
    /\ fails' = IF lbl = "forced" THEN fails + 1 ELSE fails
    /\ oog'   = IF lbl = "oog" THEN oog \cup {<<r.tx, r.m>>} ELSE oog
    /\ rlog'  = LogR(r, lbl)
    /\ UNCHANGED <<near, locked, proposal, epoch, paid, minted, txsig, created, burnt, blk, stor, deleted>>

FailP(r, gas) == FailL(r, IF gas THEN "forced" ELSE "fail")
FailOOG(r)    == FailL(r, "oog")

\* The generic runner.  Platform part only; the caller conjoins, after Exec,
\*   IF Ok(r, O) THEN <its own state := O's> ELSE UNCHANGED <its state>.
\* For "either" Exec has two successors, and Ok tells which one this step
\* took by reading the primed platform state: the commit created r's
\* children (fresh ids, so no other receipt equals one), the failure none.
\* So Ok must come after Exec in the same action; written as membership in
\* rq' / post', it is an error (not an assignment) if it comes first.
Committed(r, O) == \E c \in Kids(O) : InstantTag(Alloc(r, O, c)) \in rq' \cup post'
Ok(r, O) ==
    LET v == Verdict(r, O) IN
    IF v = "either" THEN Committed(r, O) ELSE v = "ok"
Exec(r, O) ==
    LET v == Verdict(r, O) IN
    IF v = "ok" THEN Commit(r, O) ELSE IF v = "oog" THEN FailOOG(r)
    ELSE IF v = "either" THEN Commit(r, O) \/ FailP(r, FALSE)
    ELSE FailP(r, FALSE)

\* The forced-fault switch as one step (the contract conjoins UNCHANGED of its vars).
ForcedFail(r) == /\ fails < MaxFails /\ r.m \in MayFail /\ FailP(r, TRUE)

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
    /\ UNCHANGED <<locked, proposal, epoch, nid, fails, minted, oog, txsig, burnt, blk>>

\* A refund to a missing account fails and its amount is burnt
\* (lib.rs:1046-1054); refunds never create accounts (actions.rs:930-933).
RefundBurn(r) ==
    /\ rq'    = RemR(r)
    /\ post'  = RemP(r)
    /\ data'  = RemD(r) \cup DataOf(r, FALSE, 0)
    /\ burnt' = burnt + r.dep
    /\ rlog'  = LogR(r, "fail")
    /\ UNCHANGED <<near, locked, proposal, epoch, nid, fails, paid, minted, oog, txsig, created, blk, stor, deleted>>

\* A Transfer to a missing named account fails (AccountDoesNotExist,
\* actions.rs:842-850); the deposit is refunded to r.rto and the callback
\* sees Failed.  A refund to a missing account is burnt.
ExecTransferFail(r) ==
    /\ ~AcctExists(r.to)
    /\ \/ r.m = XFER /\ ~IsImplicit(r.to) /\ FailP(r, FALSE)
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
            /\ UNCHANGED <<epoch, nid, fails, paid, minted, oog, txsig, created, burnt, blk, stor, deleted>>

\* All built-in receipts as one step (the contract conjoins UNCHANGED of its vars).
ExecBuiltin(r) == ExecTransfer(r) \/ ExecTransferFail(r) \/ ExecStake(r)

\* A function call whose receiver is missing or has no code fails before
\* any contract code runs.  Exec does this already (Verdict); this step lets
\* a dispatcher handle such receipts without calling a handler.
ExecNoCode(r) == IsCall(r) /\ ~CallTargetOK(r) /\ FailP(r, FALSE)

----------------------------------------------------------------------------
(* Account lifecycle: CreateAccount and DeleteAccount (docs/SEMANTICS.md,  *)
(* A6, A7).  An ACCOUNT receipt (m = ACCT) holds only account actions, in  *)
(* this order: [CreateAccount]? [Transfer(dep)]? [key actions]*            *)
(* [DeleteAccount(bnf)]?, recorded in the optional field ac = [mk |->      *)
(* BOOLEAN (CreateAccount), bnf |-> beneficiary or "" (DeleteAccount),     *)
(* ka |-> key actions (NearKeys.WithAcctKeys)].  The Transfer is present   *)
(* iff dep > 0.  It runs no code, never runs out of gas, and is run by     *)
(* ExecAcct (NearKeys.ExecAcctK with key actions); Exec asserts on it.  A  *)
(* dispatcher routes IsAcctRcpt(r) there before any contract handler.      *)
(* Sim: conformance/tests/lifecycle.rs.                                    *)

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
\* default 0); an eth-implicit account created by a Transfer holds the
\* 32-byte global contract hash; other created accounts have no code.
MaxDeleteBytes == 10000
CodeSize == [a \in Accounts |-> 0]
CodeBytes(a) == IF a \in created /\ KindOf(a) = "eth_implicit" THEN 32
                ELSE IF ~HasCode(a) THEN 0
                ELSE IF a \in DOMAIN CodeSize THEN CodeSize[a] ELSE 0
LargeState(a, bytes) == StoragePerByte /\ bytes - CodeBytes(a) > MaxDeleteBytes

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
\* sir: the receipt is on its predecessor's own account.
AcctFee(fr, to, mk, dep, bnf) ==
    IF GasMode # "gas" THEN 0
    ELSE LET sir == (fr = to) IN
         NearFeeTable!ReceiptFee(sir)
         + (IF mk THEN NearFeeTable!ActionFee("create_account", sir, KindOf(to)) ELSE 0)
         + (IF dep > 0 THEN NearFeeTable!ActionFee("transfer", sir, KindOf(to)) ELSE 0)
         + (IF bnf # "" THEN NearFeeTable!ActionFee("delete_account", sir, KindOf(to)) ELSE 0)

\* Constructors.  CreateAcctRcpt: [CreateAccount, Transfer(dep)?] for the
\* new account, from its creator fr (refunds go to fr).  DeleteAcctRcpt:
\* [DeleteAccount(b)] on acct, sent by acct itself (its own transaction or a
\* receipt it creates).  WithDeleteTo(r, b) appends DeleteAccount(b) to an
\* ACCOUNT receipt (it must be last, action_validation.rs:139-142), e.g.
\* WithDeleteTo(CreateAcctRcpt(..), b).
AcctRcpt(id, tx, to, fr, a, dep, cb, mk, bnf) ==
    WithFee([ac |-> [mk |-> mk, bnf |-> bnf, ka |-> <<>>]] @@ Rcpt(id, tx, to, fr, ACCT, a, dep, fr, cb),
            AcctFee(fr, to, mk, dep, bnf))
CreateAcctRcpt(id, tx, new, fr, a, dep, cb) == AcctRcpt(id, tx, new, fr, a, dep, cb, TRUE, "")
DeleteAcctRcpt(id, tx, acct, a, b, cb)      == AcctRcpt(id, tx, acct, acct, a, 0, cb, FALSE, b)
WithDeleteTo(r, b) ==
    IF ~IsAcctRcpt(r) \/ b = "" THEN Assert(FALSE, <<"WithDeleteTo needs an ACCOUNT receipt and a beneficiary", r.id>>)
    ELSE [r EXCEPT !.ac.bnf = b,
                   !.gf = @ + (IF GasMode = "gas"
                               THEN NearFeeTable!ActionFee("delete_account", r.fr = r.to, KindOf(r.to)) ELSE 0)]

\* The actor after the CreateAccount (the new account) or without one (the
\* predecessor) (actions.rs:202; lib.rs:599-610).
AcctActor(r) == IF r.ac.mk THEN r.to ELSE r.fr
\* Does the receiver exist for the actions after CreateAccount?  A universal
\* account created by a Transfer is uninitialised: only a Transfer accepts it
\* (actions.rs:880-887).
AcctThere(r) == r.ac.mk \/ AcctExists(r.to)
AcctInit(r)  == r.ac.mk \/ ~UninitUniversal(r.to)

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
\*  DeleteAccount: exists; actor = the account (:776-783, ActorNoPermission);
\*    nothing locked (:784-790, DeleteAccountStaking); not large state.
AcctErr(r, kb, kok) ==
    LET a == r.to  ka == r.ac.ka  b == r.ac.bnf
        bytes == (IF r.ac.mk THEN AccountBytes ELSE stor[a]) + kb IN
    \* (IF, not CASE: the first failing check wins.)
    IF r.ac.mk /\ AcctExists(a) THEN "AccountAlreadyExists"
    ELSE IF r.ac.mk /\ IsImplicit(a) THEN "OnlyImplicitAccountCreationAllowed"
    ELSE IF r.ac.mk /\ ParentOf(a) = NoParent /\ r.fr # TopCreator THEN "CreateAccountOnlyByRegistrar"
    ELSE IF r.ac.mk /\ ParentOf(a) # NoParent /\ ParentOf(a) # r.fr THEN "CreateAccountNotAllowed"
    ELSE IF (r.dep > 0 \/ ka # <<>> \/ b # "") /\ ~AcctThere(r) THEN "AccountDoesNotExist"
    ELSE IF (ka # <<>> \/ b # "") /\ ~AcctInit(r) THEN "AccountNotInitialized"
    ELSE IF (ka # <<>> \/ b # "") /\ AcctActor(r) # a THEN "ActorNoPermission"
    ELSE IF ka # <<>> /\ ~kok THEN "AddKeyAlreadyExists or DeleteKeyDoesNotExist"
    ELSE IF b # "" /\ LockedOf(a) > 0 THEN "DeleteAccountStaking"
    ELSE IF b # "" /\ LargeState(a, bytes) THEN "DeleteAccountWithLargeState"
    ELSE ""

\* The storage check after the actions (lib.rs:1008-1031), skipped when the
\* receipt deleted the account (:1010).  bal: the liquid after the actions.
AcctBal(r) == (IF r.ac.mk THEN 0 ELSE near[r.to]) + r.dep
AcctStorOK(r, kb) ==
    IF r.ac.bnf # "" THEN TRUE
    ELSE IF StoragePerByte
    THEN StorageCovers(AcctBal(r) + LockedOf(r.to), (IF r.ac.mk THEN AccountBytes ELSE stor[r.to]) + kb)
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
           pay == b # "" /\ bal > 0 IN
       IF AcctOK(r, kb, kok)
       THEN /\ Assert(~mk \/ near[a] = 0, <<"CreateAccount of an account whose near is not 0", a, near[a]>>)
            /\ rq'   = RemR(r) \cup (IF pay THEN {Rcpt(nid, r.tx, b, "system", REFND, r.a, bal, b, 0)} ELSE {})
            /\ post' = RemP(r)
            /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)
            /\ near' = [near EXCEPT ![a] = IF b # "" THEN 0 ELSE bal]
            /\ nid'  = IF pay THEN nid + 1 ELSE nid
            /\ rlog' = LogR(r, "ok")
            /\ created' = IF mk THEN created \cup {a} ELSE created
            /\ deleted' = IF b # "" THEN deleted \cup {a} ELSE IF mk THEN deleted \ {a} ELSE deleted
            /\ stor' = IF ~StoragePerByte THEN stor
                       ELSE [stor EXCEPT ![a] = IF b # "" THEN 0
                                                ELSE (IF mk THEN AccountBytes ELSE @) + kb]
            /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, burnt, blk>>
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
    /\ UNCHANGED <<rq, post, data, proposal, nid, fails, paid, oog, rlog, txsig, created, burnt, blk, stor, deleted>>

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
                   rlog, txsig, created, burnt, stor, deleted>>
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
\* disable its step.
CanSubmit(r, a) ==
    /\ a \notin deleted
    /\ near[a] >= r.dep
    /\ IF StoragePerByte THEN StorageCovers(near[a] - r.dep + LockedOf(a), stor[a]) ELSE TRUE

\* Submit a transaction signed by account a with key id k: its first receipt
\* (prepaid gas in r.g, see WithGas).  The signer pays the deposit now.  The
\* receipt is local iff signer = receiver (lib.rs:2316-2324).
SubmitAs(r, a, k) ==
    /\ ~InstantPending
    /\ CanSubmit(r, a)
    /\ rq'    = rq \cup {[r EXCEPT !.loc = (a = r.to)]}
    /\ near'  = [near EXCEPT ![a] = @ - r.dep]
    /\ nid'   = nid + 1
    /\ txsig' = IF TrackSigner THEN (r.tx :> [a |-> a, k |-> k]) @@ txsig ELSE txsig
    /\ UNCHANGED <<post, data, locked, proposal, epoch, fails, paid, minted, oog, rlog, created, burnt, blk, stor, deleted>>

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
    /\ txsig = <<>> /\ created = {} /\ burnt = 0 /\ deleted = {} /\ blk = 0
    /\ stor = StorageInit /\ StorageInitOK(near0, locked0)
PlatformInit(near0, txIds) == PlatformInitStaked(near0, 0, txIds)

\* Only the variables added in 0.1.0 and 0.2, for models that initialise the
\* others themselves.  The parts compose: a model with its own txsig
\* initialiser (e.g. a pre-sized function) conjoins PlatformInitAccounts,
\* PlatformInitClock and PlatformInitStorage alone.  PlatformInitStorage
\* does not check the initial cover: list StorageCovered as an invariant.
PlatformInitSigner   == txsig = <<>>
PlatformInitAccounts == created = {} /\ burnt = 0 /\ deleted = {}
PlatformInitClock    == blk = 0
PlatformInitStorage  == stor = StorageInit
PlatformInitExtra    == PlatformInitSigner /\ PlatformInitAccounts /\ PlatformInitClock
                        /\ PlatformInitStorage

----------------------------------------------------------------------------
(* Platform sanity                                                         *)

\* NEAR is conserved modulo rewards and burnt refunds.
NearConserved(total0) ==
    LET F[S \in SUBSET Accounts] == IF S = {} THEN 0
                                    ELSE LET a == CHOOSE y \in S : TRUE IN near[a] + F[S \ {a}]
    IN F[Accounts] + locked + InflightDeposits = total0 + minted - burnt

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
