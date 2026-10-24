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
(*    value is PromiseResult::Failed, lib.rs:895).  This module models one *)
(*    input data dependency per callback.                                  *)
(*  - Data receipts are separate in-flight objects: anything may           *)
(*    interleave between a receipt's commit and its callback.              *)
(*  - Returning a promise forwards the caller's output receivers to the    *)
(*    returned receipt (lib.rs:1152-1168); the contract wires              *)
(*    `tail.cb := r.cb`.                                                   *)
(*  - The transaction signer is inherited by every receipt of the tree     *)
(*    (runtime/runtime/src/function_call.rs:172-173) and exposed to the    *)
(*    contract next to the predecessor (function_call.rs:259-262).         *)
(*  - Local receipts: a transaction whose signer is its receiver produces  *)
(*    a local receipt, executed in the same chunk before delayed and       *)
(*    incoming receipts (lib.rs:2316-2324, :2800-2821).  Receipts created  *)
(*    by a receipt (self-calls included) are outgoing and run in a later  *)
(*    chunk (lib.rs:1222-1234).  See LocalPriorityOK.                      *)
(*  - Account types (named / NEAR-implicit / eth-implicit): a Transfer to  *)
(*    a missing implicit account creates it; to a missing named account it *)
(*    fails and refunds (runtime/runtime/src/actions.rs:842-850,           *)
(*    :929-949, :221-290).  Refunds never create accounts (:931-933).      *)
(*  - Native NEAR: liquid per account, plus locked / proposal for one      *)
(*    staking account.  Stake failures follow actions.rs:58-109.           *)
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
(*    * action-only receipts never run out of gas.                         *)
(*  The forced switch is kept in both modes: a receipt whose method is in  *)
(*  MayFail may fail, at most MaxFails times; counted in `fails`.  A real  *)
(*  out-of-gas is recorded in `oog`.                                       *)
(*                                                                         *)
(* Not modelled: congestion (a local receipt that does not fit the chunk's *)
(* compute limit is delayed, lib.rs:2513-2521), instant receipts           *)
(* (core/primitives/src/receipt.rs:468-485), DeleteAccount, yield/resume,  *)
(* gas price and gas refunds in NEAR, deterministic and universal account  *)
(* types, a refund to a missing account (burnt, lib.rs:1047-1054; here it *)
(* stays pending).                                                         *)
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
    post,      \* set of postponed callback receipts (each waits on exactly one data id)
    data,      \* set of in-flight data receipts [to, ok, v, sz, tx]
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
    created    \* accounts created at run time (implicit-account Transfer)

platformVars == <<rq, post, data, near, locked, proposal, epoch, nid, fails, paid, minted, oog, rlog,
                  txsig, created>>

----------------------------------------------------------------------------
(* Overridable definitions.  Override in the cfg with `Name <- MyDef`      *)
(* (or a [run.constants] entry); the defaults keep the behaviour of models *)
(* that do not mention them.                                               *)

\* Account type by id pattern: "named", "near_implicit" (64 hex chars) or
\* "eth_implicit" ("0x" + 40 hex chars).  Toy ids cannot match the real
\* patterns, so the model states the type.  Default: every account is named.
AcctKind == [a \in Accounts |-> "named"]
\* Helper for overrides: AcctKind <- MyKinds, MyKinds == AcctKinds({"0xe"}, {}).
AcctKinds(eth, nearImp) ==
    [a \in Accounts |-> IF a \in eth THEN "eth_implicit"
                        ELSE IF a \in nearImp THEN "near_implicit" ELSE "named"]
KindOf(a) == IF a \in DOMAIN AcctKind THEN AcctKind[a] ELSE "named"
\* Kinds a Transfer may create (NearFees.RcvKinds also has "deterministic"
\* and "universal"; they are created by a lone Transfer too, actions.rs:929-949).
IsImplicit(a) == KindOf(a) # "named"

\* Key id used by Submit(r), which carries no key information.
DefaultKey == "default"

----------------------------------------------------------------------------
(* Promise results.  A callback sees r.res = [ok, v, sz]:                   *)
(*   ok = FALSE           Failed                                           *)
(*   v >= 0               Successful, a well-formed JSON number            *)
(*   v = EMPTY            Successful, empty bytes (Transfer, `()` return)  *)
(*   v = MAL              Successful, malformed / unparsable bytes         *)
(*   v = NONEMPTY         Successful, other bytes (a JSON object, null...) *)
(*   v = NOPR             the receipt has no promise results at all        *)
(*                        (promise_results_count() = 0,                    *)
(*                        runtime/near-vm-runner/src/logic/host.rs:4583)   *)
(*   sz                   result size in KB (rounded up); 0 when unknown   *)
EMPTY    == -1
MAL      == -2
NONEMPTY == -3
NOPR     == -4

NoRes == [ok |-> TRUE, v |-> NOPR, sz |-> 0]

IsNum(res)    == res.ok /\ res.v >= 0
IsEmpty(res)  == res.ok /\ res.v = EMPTY
IsFailed(res) == ~res.ok
NoResults(res) == res.ok /\ res.v = NOPR
\* The "parse a U128 or fall back" pattern: Failed or not a number => dflt.
NumOr(res, dflt) == IF IsNum(res) THEN res.v ELSE dflt

\* Built-in (non function-call) receipt kinds.
XFER  == "XFER"     \* Transfer action (may carry a callback)
REFND == "REFUND"   \* system refund receipt
STAKE == "STAKE"    \* Stake action on StakingAcct; a.x1 = amount
IsBuiltin(r) == r.m \in {XFER, REFND, STAKE}

----------------------------------------------------------------------------
(* Receipt records.  All receipts have the same fields.                    *)
(*   id tx to fr m a dep rto cb   id, transaction, receiver, predecessor,   *)
(*                                method, args, deposit, refund account,   *)
(*                                callback id waiting on the output (0: none)*)
(*   res                          promise result (callbacks), else NoRes    *)
(*   gs gw g gf                   gas: static / weight / attached per call, *)
(*                                and the creator-side fee                  *)
(*   loc                          a local receipt (set by Submit)           *)
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

RECURSIVE SumSeq(_)
SumSeq(s) == IF s = <<>> THEN 0 ELSE Head(s) + SumSeq(Tail(s))
GasOf(r)   == SumSeq(r.g)                                 \* attached gas, all function calls
LastGas(r) == IF r.g = <<>> THEN 0 ELSE r.g[Len(r.g)]     \* env::prepaid_gas() of the last call

\* Receipts that can run now: ready ones, and postponed ones whose data arrived.
Runnable ==
    rq \cup { [pd[1] EXCEPT !.res = [ok |-> pd[2].ok, v |-> pd[2].v, sz |-> pd[2].sz]] :
                pd \in {xy \in post \X data : xy[2].to = xy[1].id} }

RemR(r) == {x \in rq   : x.id # r.id}
RemP(r) == {x \in post : x.id # r.id}
RemD(r) == {d \in data : d.to # r.id}

DataOfSz(r, ok, v, sz) ==
    IF r.cb = 0 THEN {} ELSE {[to |-> r.cb, ok |-> ok, v |-> v, sz |-> sz, tx |-> r.tx]}
DataOf(r, ok, v) == DataOfSz(r, ok, v, 0)

Sum(S) == LET F[T \in SUBSET S] == IF T = {} THEN 0
                                   ELSE LET x == CHOOSE y \in T : TRUE IN x.dep + F[T \ {x}]
          IN F[S]

\* Ids are unique, so Sum over a set of receipts is well defined.
InflightDeposits == Sum(rq) + Sum(post)

\* Account existence: initial accounts and accounts created at run time.
AcctExists(a) == a \in Exists \/ a \in created

\* The transaction signer, inherited by every receipt of the transaction.
SignerOf(t)  == txsig[t]               \* [a |-> account, k |-> key id]
Signer(r)    == txsig[r.tx].a          \* env::signer_account_id()
SignerKey(r) == txsig[r.tx].k          \* env::signer_account_pk()

----------------------------------------------------------------------------
(* Outcome record a contract handler returns:                             *)
(*   ready : set of new ready receipts                                    *)
(*   post  : set of new postponed callbacks                               *)
(*   ret   : [k |-> "val"|"prom", v |-> value, sz |-> size in KB]          *)
(*   out   : sum of deposits attached to new receipts (debited from r.to) *)
(*   ids   : number of fresh ids consumed                                 *)
(*   err   : "" or the panic message                                      *)
(*   gk    : burn key ("" = r.m); sz : size for the burn (KB)             *)
RVal(v)       == [k |-> "val", v |-> v, sz |-> 0]
RValSz(v, n)  == [k |-> "val", v |-> v, sz |-> n]
RProm         == [k |-> "prom", v |-> 0, sz |-> 0]
\* Size of a returned value; hand-built ret records without sz count as 0.
RetSz(O) == IF "sz" \in DOMAIN O.ret THEN O.ret.sz ELSE 0

\* A complete outcome record (contracts may add their own fields).
Outcome(rd, ps, ret, out, ids) ==
    [ready |-> rd, post |-> ps, ret |-> ret, out |-> out, ids |-> ids,
     err |-> "", gk |-> "", sz |-> 0]
OErr(O, e) == IF O.err = "" THEN [O EXCEPT !.err = e] ELSE O
OKey(O, k) == [O EXCEPT !.gk = k]
OSz(O, n)  == [O EXCEPT !.sz = n]

\* Storage staking: the receiver's liquid balance after the receipt must
\* cover its storage (lib.rs:1008-1023, LackBalanceForState).
Affordable(r, O) == near[r.to] + r.dep - O.out >= StorageFloor[r.to]

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
GasOK(r, O) == GasMode # "gas" \/ GasOf(r) >= Need(r, O)

\* "ok" | "fail" (panic / balance) | "oog" (ran out of its real gas)
Verdict(r, O) ==
    IF O.err # "" \/ ~Affordable(r, O) THEN "fail"
    ELSE IF ~GasOK(r, O) THEN "oog"
    ELSE "ok"

\* Weighted function-call actions of the children: <<id, action index, weight>>.
Entries(O) == UNION { { <<c.id, k, c.gw[k]>> : k \in {j \in DOMAIN c.gw : c.gw[j] > 0} } : c \in Kids(O) }
RECURSIVE WSum(_), FloorSum(_, _, _)
WSum(E) == IF E = {} THEN 0 ELSE LET e == CHOOSE y \in E : TRUE IN e[3] + WSum(E \ {e})
FloorSum(E, U, W) == IF E = {} THEN 0
                     ELSE LET e == CHOOSE y \in E : TRUE IN (U * e[3]) \div W + FloorSum(E \ {e}, U, W)
\* The last weighted action in creation order (ids are allocated in creation order).
LastE(E) == CHOOSE e \in E : \A f \in E : f[1] < e[1] \/ (f[1] = e[1] /\ f[2] <= e[2])
Share(e, U, E) ==
    LET W == WSum(E) IN
    IF e = LastE(E) THEN U - FloorSum(E \ {e}, U, W) ELSE (U * e[3]) \div W

Assign(c, U, E) ==
    [c EXCEPT !.g = [k \in DOMAIN c.gs |->
                        c.gs[k] + (IF c.gw[k] > 0 /\ U > 0 THEN Share(<<c.id, k, c.gw[k]>>, U, E) ELSE 0)]]

Give(r, O, S) ==
    IF GasMode # "gas" THEN S
    ELSE LET U == GasOf(r) - Need(r, O)  E == Entries(O) IN {Assign(c, U, E) : c \in S}

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
    /\ data' = RemD(r) \cup (IF O.ret.k = "val" THEN DataOfSz(r, TRUE, O.ret.v, RetSz(O)) ELSE {})
    /\ near' = [near EXCEPT ![r.to] = @ + r.dep - O.out]
    /\ nid'  = nid + O.ids
    /\ rlog' = LogR(r, "ok")
    /\ UNCHANGED <<locked, proposal, epoch, fails, paid, minted, oog, txsig, created>>

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
    /\ UNCHANGED <<near, locked, proposal, epoch, paid, minted, txsig, created>>

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
\* global contract and NEAR-implicit creation adds a full-access key; neither
\* is modelled beyond existence (model code and keys of such accounts yourself).
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
    /\ UNCHANGED <<locked, proposal, epoch, nid, fails, minted, oog, txsig>>

\* A Transfer to a missing named account fails (AccountDoesNotExist,
\* actions.rs:842-850); the deposit is refunded to r.rto and the callback
\* sees Failed.
ExecTransferFail(r) ==
    /\ r.m = XFER
    /\ ~AcctExists(r.to)
    /\ ~IsImplicit(r.to)
    /\ FailP(r, FALSE)

\* Stake action on StakingAcct (actions.rs:58-109).
StakeFails(amt) ==
    LET inc == IF amt > locked THEN amt - locked ELSE 0 IN
    \/ near[StakingAcct] - inc < StorageFloor[StakingAcct]   \* TriesToStake / LackBalanceForState
    \/ (locked = 0 /\ amt = 0)                               \* TriesToUnstake
    \/ (amt > 0 /\ amt < MinStake)                           \* InsufficientStake

ExecStake(r) ==
    /\ r.m = STAKE
    /\ LET amt == r.a.x1
           inc == IF amt > locked THEN amt - locked ELSE 0 IN
       IF StakeFails(amt)
       THEN FailP(r, FALSE)
       ELSE /\ rq'   = RemR(r)
            /\ post' = RemP(r)
            /\ data' = RemD(r) \cup DataOf(r, TRUE, 0)
            /\ near' = [near EXCEPT ![StakingAcct] = @ - inc]
            /\ locked' = IF amt > locked THEN amt ELSE locked
            /\ proposal' = amt
            /\ rlog' = LogR(r, "ok")
            /\ UNCHANGED <<epoch, nid, fails, paid, minted, oog, txsig, created>>

\* All built-in receipts as one step (the contract conjoins UNCHANGED of its vars).
ExecBuiltin(r) == ExecTransfer(r) \/ ExecTransferFail(r) \/ ExecStake(r)

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
    /\ UNCHANGED <<rq, post, data, proposal, nid, fails, paid, oog, rlog, txsig, created>>

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
    /\ txsig' = (r.tx :> [a |-> a, k |-> k]) @@ txsig
    /\ UNCHANGED <<post, data, locked, proposal, epoch, fails, paid, minted, oog, rlog, created>>

\* A transaction signed by its predecessor r.fr with the default key.
Submit(r) == SubmitAs(r, r.fr, DefaultKey)

\* Local-receipt priority (lib.rs:2800-2821): a pending local receipt on an
\* account runs before any other receipt on that account.  Only a
\* transaction's first receipt is local; later self-calls are not
\* (lib.rs:1222-1234).  Assumes no congestion (lib.rs:2513-2521).
\* nearcore's order is chunk-wide (all local receipts first, for every
\* account); this rule only orders receipts of the same account.  That is
\* exact for per-account state; ghosts that relate several accounts may see
\* orders nearcore does not produce.
\* Opt-in: conjoin LocalPriorityOK(r) to the receipt step, or draw r from Schedulable.
\* A model that does not conjoin it explores every causally enabled order.
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
    /\ txsig = <<>> /\ created = {}
PlatformInit(near0, txIds) == PlatformInitStaked(near0, 0, txIds)

\* Only the variables added in 0.1.0, for models that initialise the others
\* themselves.
PlatformInitExtra == txsig = <<>> /\ created = {}

----------------------------------------------------------------------------
(* Platform sanity                                                         *)

\* NEAR is conserved modulo rewards.
NearConserved(total0) ==
    LET F[S \in SUBSET Accounts] == IF S = {} THEN 0
                                    ELSE LET a == CHOOSE y \in S : TRUE IN near[a] + F[S \ {a}]
    IN F[Accounts] + locked + InflightDeposits = total0 + minted

\* No receipt in flight holds more gas than its transaction's prepaid gas
\* (the split never creates gas).
GasBounded(prepaidOf(_)) ==
    GasMode = "gas" => \A x \in rq \cup post : GasOf(x) <= prepaidOf(x.tx)
=============================================================================
