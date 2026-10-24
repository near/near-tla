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
(*    after a receipt uses liquid + locked (verifier.rs:48-79).            *)
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
(*      function-call actions with weight > 0, in creation order: each     *)
(*      gets floor(U*w/W), the last one also gets the remainder; W = 0     *)
(*      distributes nothing (runtime/runtime/src/receipt_manager.rs:414,   *)
(*      :679-721).                                                         *)
(*    * a receipt with several function-call actions may give per-action   *)
(*      accounting in the outcome (`pa`): each action's leftover is split  *)
(*      over the children it created (function_call.rs:61, :343-345);      *)
(*      without `pa` the whole receipt is one action.                      *)
(*    * a created function call left with 0 gas fails the creating receipt *)
(*      (action_validation.rs:350-351, applied at lib.rs:968-978).         *)
(*    * a panic is labelled out-of-gas when its explicit panic-path burn   *)
(*      (OPanicKey) plus the children created before it exceeds the        *)
(*      attached gas (gas_counter.rs:136-141, :155-174, :205-213).         *)
(*    * action-only receipts never run out of gas.                         *)
(*  The forced switch is kept in both modes: a receipt whose method is in  *)
(*  MayFail may fail, at most MaxFails times; counted in `fails`.  A real  *)
(*  out-of-gas is recorded in `oog`.                                       *)
(*                                                                         *)
(* Not modelled: congestion (a local receipt that does not fit the chunk's *)
(* compute limit is delayed, lib.rs:2513-2521), instant receipts           *)
(* (core/primitives/src/receipt.rs:468-485), DeleteAccount, gas price and  *)
(* gas refunds in NEAR, DeployContract (code is static, see Contracts),    *)
(* one receipt feeding several callbacks (cb is one id).                   *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences, TLC

\* The fee table, as a named instance so its helper names do not enter the
\* models' namespace.  A model that wants the fee operators unqualified can
\* EXTENDS NearFees itself.
NearFeeTable == INSTANCE NearFees

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
    blk        \* block height, env::block_height() (BlockTick); stays 0 unless MaxBlk > 0
\* Every platform variable must be initialised: use PlatformInit /
\* PlatformInitStaked, or conjoin PlatformInitExtra to an older Init.  TLC's
\* "The variable txsig was not initialized" means PlatformInitExtra (or its
\* parts PlatformInitSigner / PlatformInitAccounts / PlatformInitClock) is
\* missing.

platformVars == <<rq, post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog, rlog,
                  txsig, created, burnt, blk>>

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

\* Key id used by Submit(r), which carries no key information.
DefaultKey == "default"

\* Block clock and yield timeouts.  blk is env::block_height(), advanced only
\* by BlockTick, which a model adds to its Next.
\* MaxBlk: bound on blk; 0 = no clock (blk stays 0).
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
IsBuiltin(r) == r.m \in {XFER, REFND, STAKE}
IsKeyRcpt(r) == r.m \in {ADDK, DELK}
\* A function-call receipt (the rest).
IsCall(r)    == ~IsBuiltin(r) /\ ~IsKeyRcpt(r)

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
\* reachable; ClockBoundOK reports it).
FailedRes   == [ok |-> FALSE, v |-> 0, sz |-> 0, len |-> 0]
TimedOut(p) == /\ IsYield(p)
               /\ ~\E d \in data : d.to = p.id
               /\ (blk >= p.ydl \/ blk >= MaxBlk)

\* Receipts that can run now: ready ones; postponed ones whose data arrived
\* (a yield with its resume payload); joint callbacks whose inputs all
\* arrived, with rs = their results in order and res = JointMark; timed-out
\* yields, with Failed.  (No data is ever addressed to a joint callback's own
\* id: its data ids are fresh.)
Runnable ==
    rq \cup { [pd[1] EXCEPT !.res = [ok |-> pd[2].ok, v |-> pd[2].v, sz |-> pd[2].sz, len |-> pd[2].len]] :
                pd \in {xy \in post \X data : xy[2].to = xy[1].id} }
       \cup { [[rs |-> JointRes(p)] @@ p EXCEPT !.res = JointMark] :
                p \in {q \in post : IsJoint(q) /\ Arrived(q)} }
       \cup { [p EXCEPT !.res = FailedRes] : p \in {q \in post : TimedOut(q)} }

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

\* Account existence: initial accounts and accounts created at run time.
AcctExists(a) == a \in Exists \/ a \in created
\* Can a function call on a run?  An account created by a Transfer has no
\* code, except an eth-implicit one, which gets a protocol-defined global
\* contract (actions.rs:221-290); a universal one is also uninitialised
\* (actions.rs:880-887, AccountNotInitialized).
HasCode(a) == /\ AcctExists(a)
              /\ a \in Contracts
              /\ ~(a \in created /\ KindOf(a) # "eth_implicit")
CallTargetOK(r) == ~CallsNeedCode \/ ~IsCall(r) \/ HasCode(r.to)

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
\* Ids of account a's yields still waiting (e.g. for the duplicate check of
\* promise_yield_create_with_id, ext.rs:375-385, which the handler models).
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
\* storage (lib.rs:1008-1023, check_storage_stake at verifier.rs:48-79;
\* LackBalanceForState).  StorageFloor[a] is the required amount; give 0 for
\* an account under the zero-balance storage threshold, which is exempt
\* (verifier.rs:75-77).
LockedOf(a) == IF a = StakingAcct THEN locked ELSE 0
Affordable(r, O) ==
    /\ near[r.to] + r.dep - O.out >= 0
    /\ near[r.to] + r.dep - O.out + LockedOf(r.to) >= StorageFloor[r.to]

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
Share(e, U, E) ==
    LET W == WSum(E) IN
    IF e = LastE(E) THEN U - FloorSum(E \ {e}, U, W) ELSE (U * e[3]) \div W

Assign(c, U, E) ==
    IF ~GasListsOK(c) THEN c
    ELSE [c EXCEPT !.g = [k \in DOMAIN c.gs |->
                        c.gs[k] + (IF c.gw[k] > 0 /\ U > 0 THEN Share(<<c.id, k, c.gw[k]>>, U, E) ELSE 0)]]

\* A child with its attached gas, after the split.
Alloc(r, O, c) ==
    IF PerAction(r, O)
    THEN LET k == ActOf(O, c) IN Assign(c, ActGas(r, k) - ActNeed(O, k), EntriesOf(ActKids(O, k)))
    ELSE Assign(c, GasOf(r) - Need(r, O), Entries(O))

Give(r, O, S) ==
    IF GasMode # "gas" THEN S ELSE {Alloc(r, O, c) : c \in S}

\* A function-call child left with 0 gas (static 0 and no share) fails the
\* creating receipt: new receipts are validated after the action
\* (lib.rs:968-978; action_validation.rs:350-351, FunctionCallZeroAttachedGas).
ZeroGasKid(r, O) ==
    /\ GasMode = "gas"
    /\ \E c \in Kids(O) : \E k \in DOMAIN c.gs : Alloc(r, O, c).g[k] = 0

\* A receipt with several function-call actions and no pa would pool their
\* gas; that is only allowed with PooledGasOK.  A failing outcome without a
\* panic key does not use the gas, so it is exempt.
PoolCheck(r, O) ==
    IF GasMode # "gas" \/ Len(r.g) <= 1 \/ ("pa" \in DOMAIN O /\ O.pa # <<>>) \/ PooledGasOK
       \/ (O.err # "" /\ ~HasPanicKey(O)) THEN TRUE
    ELSE Assert(FALSE, <<"receipt with several function calls but no pa (per-action gas); PooledGasOK <- TRUE to pool", r.to, r.m>>)

\* "ok" | "fail" (panic, action error, balance) | "oog" (ran out of its real gas).
\* Order: the receiver check comes first (the call never starts); a panic
\* the gas could not reach is "oog"; new-receipt validation and the storage
\* check run after the call.
Verdict(r, O) ==
    IF ~PoolCheck(r, O) THEN "fail"
    ELSE IF ~CallTargetOK(r) THEN "fail"
    ELSE IF O.err # "" THEN (IF PanicOOG(r, O) THEN "oog" ELSE "fail")
    ELSE IF ~GasOK(r, O) THEN "oog"
    ELSE IF ZeroGasKid(r, O) THEN "fail"
    ELSE IF ~Affordable(r, O) THEN "fail"
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
    /\ rq'   = RemR(r) \cup Give(r, O, O.ready)
    /\ post' = RemP(r) \cup Give(r, O, O.post)
    /\ data' = RemD(r) \cup (IF O.ret.k = "val" THEN DataOfLen(r, TRUE, O.ret.v, RetSz(O), RetLen(O)) ELSE {})
                     \cup ResumeData(r, O)
    /\ near' = [near EXCEPT ![r.to] = @ + r.dep - O.out]
    /\ nid'  = nid + O.ids
    /\ rlog' = LogR(r, "ok")
    /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, created, burnt, blk>>

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
    /\ UNCHANGED <<near, locked, proposal, epoch, paid, minted, txsig, created, burnt, blk>>

FailP(r, gas) == FailL(r, IF gas THEN "forced" ELSE "fail")
FailOOG(r)    == FailL(r, "oog")

\* The generic runner.  Platform part only; the caller conjoins
\*   IF Ok(r, O) THEN <its own state := O's> ELSE UNCHANGED <its state>.
Ok(r, O) == Verdict(r, O) = "ok"
Exec(r, O) ==
    LET v == Verdict(r, O) IN
    IF v = "ok" THEN Commit(r, O) ELSE IF v = "oog" THEN FailOOG(r) ELSE FailP(r, FALSE)

\* The forced-fault switch as one step (the contract conjoins UNCHANGED of its vars).
ForcedFail(r) == /\ fails < MaxFails /\ r.m \in MayFail /\ FailP(r, TRUE)

----------------------------------------------------------------------------
(* Built-in receipt execution (no contract code; no gas of their own).     *)

\* Transfer / refund: credit the receiver; result data (empty bytes) to the
\* callback if any.  A Transfer to a missing implicit account creates it
\* (actions.rs:221-290).  Eth-implicit creation attaches a protocol-defined
\* global contract (HasCode stays TRUE); the other created kinds have no code,
\* so calls to them fail.  NEAR-implicit creation adds a full-access key, which
\* is not modelled (model the keys of such accounts yourself).
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
    /\ UNCHANGED <<locked, proposal, epoch, nid, fails, minted, oog, txsig, burnt, blk>>

\* A refund to a missing account fails and its amount is burnt
\* (lib.rs:1046-1054); refunds never create accounts (actions.rs:930-933).
RefundBurn(r) ==
    /\ rq'    = RemR(r)
    /\ post'  = RemP(r)
    /\ data'  = RemD(r) \cup DataOf(r, FALSE, 0)
    /\ burnt' = burnt + r.dep
    /\ rlog'  = LogR(r, "fail")
    /\ UNCHANGED <<near, locked, proposal, epoch, nid, fails, paid, minted, oog, txsig, created, blk>>

\* A Transfer to a missing named account fails (AccountDoesNotExist,
\* actions.rs:842-850); the deposit is refunded to r.rto and the callback
\* sees Failed.  A refund to a missing account is burnt.
ExecTransferFail(r) ==
    /\ ~AcctExists(r.to)
    /\ \/ r.m = XFER /\ ~IsImplicit(r.to) /\ FailP(r, FALSE)
       \/ r.m = REFND /\ BurnLostRefunds /\ RefundBurn(r)

\* Stake action (actions.rs:58-109): the actor must be the account itself
\* (actions.rs:755-801, ActorNoPermission); then TriesToStake (liquid below
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
       IF r.fr # r.to \/ StakeFails(amt)
       THEN FailP(r, FALSE)
       ELSE /\ rq'   = RemR(r)
            /\ post' = RemP(r)
            /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)      \* no return value: empty bytes (lib.rs:1172-1176)
            /\ near' = [near EXCEPT ![StakingAcct] = @ - inc]
            /\ locked' = IF amt > locked THEN amt ELSE locked
            /\ proposal' = amt
            /\ rlog' = LogR(r, "ok")
            /\ UNCHANGED <<epoch, nid, fails, paid, minted, oog, txsig, created, burnt, blk>>

\* All built-in receipts as one step (the contract conjoins UNCHANGED of its vars).
ExecBuiltin(r) == ExecTransfer(r) \/ ExecTransferFail(r) \/ ExecStake(r)

\* A function call whose receiver is missing or has no code fails before
\* any contract code runs.  Exec does this already (Verdict); this step lets
\* a dispatcher handle such receipts without calling a handler.
ExecNoCode(r) == IsCall(r) /\ ~CallTargetOK(r) /\ FailP(r, FALSE)

\* Epoch transition: rewards go to locked; a decreased proposal releases the
\* difference to liquid.  Scaled: the release happens on the next tick
\* (nearcore returns unstaked funds once the stake leaves the validator set,
\* a few epochs later).
EpochTick ==
    /\ epoch < MaxEpoch
    /\ \E rw \in 0..(IF locked > 0 THEN MaxReward ELSE 0) :
         LET newLocked == IF proposal < locked THEN proposal ELSE locked
             release   == locked - newLocked IN
         /\ epoch'  = epoch + 1
         /\ locked' = newLocked + rw
         /\ near'   = [near EXCEPT ![StakingAcct] = @ + release]
         /\ minted' = minted + rw
    /\ UNCHANGED <<rq, post, data, proposal, nid, fails, paid, oog, rlog, txsig, created, burnt, blk>>

\* Block clock: one block passes (the model adds BlockTick /\ UNCHANGED of its
\* own variables to Next).  Every receipt that runs at one value of blk sees
\* that height (env::block_height(), runtime/near-vm-runner/src/logic/host.rs:827;
\* env::block_timestamp() is BlockTs, :837).  Heights only grow.  With
\* TickAnytime = FALSE a block passes only while some yield's deadline is
\* ahead.  Independent of EpochTick (env::epoch_height(), :847).
BlockTick ==
    /\ blk < MaxBlk
    /\ TickAnytime \/ \E p \in post : IsYield(p) /\ p.ydl > blk
    /\ blk' = blk + 1
    /\ UNCHANGED <<rq, post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog,
                   rlog, txsig, created, burnt>>
BlockTs == TsOf(blk)

----------------------------------------------------------------------------
(* Transactions                                                            *)

\* Submit a transaction signed by account a with key id k: its first receipt
\* (prepaid gas in r.g, see WithGas).  The signer pays the deposit now.  The
\* receipt is local iff signer = receiver (lib.rs:2316-2324).
SubmitAs(r, a, k) ==
    /\ near[a] >= r.dep
    /\ rq'    = rq \cup {[r EXCEPT !.loc = (a = r.to)]}
    /\ near'  = [near EXCEPT ![a] = @ - r.dep]
    /\ nid'   = nid + 1
    /\ txsig' = IF TrackSigner THEN (r.tx :> [a |-> a, k |-> k]) @@ txsig ELSE txsig
    /\ UNCHANGED <<post, data, locked, proposal, epoch, fails, paid, minted, oog, rlog, created, burnt, blk>>

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
\* Opt-in: conjoin LocalPriorityOK(r) to the receipt step, or draw r from Schedulable.
LocalPriorityOK(r) == ~r.loc => ~\E y \in rq : y.loc /\ y.to = r.to
Schedulable == {r \in Runnable : LocalPriorityOK(r)}

TxBusy(t) == \E x \in rq \cup post : x.tx = t
TxSettled(t) == ~TxBusy(t) /\ ~\E d \in data : d.tx = t
Idle == rq = {} /\ post = {} /\ data = {}

----------------------------------------------------------------------------
(* Init helpers                                                            *)

\* Every platform variable.  near0: [Accounts -> Nat]; txIds: the domain of paid.
PlatformInitStaked(near0, locked0, txIds) ==
    /\ rq = {} /\ post = {} /\ data = {}
    /\ near = near0
    /\ locked = locked0 /\ proposal = locked0 /\ epoch = 0
    /\ nid = 1 /\ fails = 0 /\ minted = 0
    /\ paid = [t \in txIds |-> [a \in Accounts |-> 0]]
    /\ oog = {} /\ rlog = {}
    /\ txsig = <<>> /\ created = {} /\ burnt = 0 /\ blk = 0
PlatformInit(near0, txIds) == PlatformInitStaked(near0, 0, txIds)

\* Only the variables added in 0.1.0 and 0.2, for models that initialise the
\* others themselves.  The parts compose: a model with its own txsig
\* initialiser (e.g. a pre-sized function) conjoins PlatformInitAccounts and
\* PlatformInitClock alone.
PlatformInitSigner   == txsig = <<>>
PlatformInitAccounts == created = {} /\ burnt = 0
PlatformInitClock    == blk = 0
PlatformInitExtra    == PlatformInitSigner /\ PlatformInitAccounts /\ PlatformInitClock

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

\* No pending yield's deadline lies past the clock bound.  When this fails,
\* some yield could time out before its deadline (at blk = MaxBlk, see
\* TimedOut): raise MaxBlk.  Trivially TRUE without a clock.
ClockBoundOK == MaxBlk = 0 \/ \A p \in post : IsYield(p) => p.ydl <= MaxBlk

\* No receipt in flight holds more gas than its transaction's prepaid gas
\* (the split never creates gas).
GasBounded(prepaidOf(_)) ==
    GasMode = "gas" => \A x \in rq \cup post : GasOf(x) <= prepaidOf(x.tx)
=============================================================================
