------------------------------ MODULE NearKeys ------------------------------
(***************************************************************************)
(* Access keys on top of NearAsync (the signer itself is in NearAsync).    *)
(*                                                                         *)
(*  1. Access keys.  keys[a] : key id -> permission                        *)
(*     Perm(rcv, ms, all): a function-call key for receiver rcv, methods   *)
(*     ms (any method if all, or if ms = {}); FullPerm: full access.       *)
(*     A function-call key may only sign a transaction with exactly one    *)
(*     action, a zero-deposit function call to its receiver with a         *)
(*     permitted method; an empty method list allows every method          *)
(*     (runtime/runtime/src/verifier.rs:209-250, :213, :223, :238).        *)
(*  2. SubmitSigned(r, a, k): a transaction signed by a with key k.        *)
(*  3. AddKey / DeleteKey receipts (ADDK / DELK, ExecKeyAct).  Key actions *)
(*     are only allowed on the predecessor's own account                   *)
(*     (runtime/runtime/src/actions.rs:755-801, ActorNoPermission);        *)
(*     deleting an absent key (access_keys.rs:84) or adding a present key  *)
(*     (access_keys.rs:158) fails the receipt.                             *)
(*  4. Multi-action receipts such as [DeleteKey(k), FunctionCall]: the     *)
(*     actions of one receipt run in order and are atomic                  *)
(*     (runtime/runtime/src/lib.rs:946-1005: the first failing action      *)
(*     stops the receipt, and the whole receipt rolls back,                *)
(*     lib.rs:1078-1088).  WithKeyActs / ExecWithKeys.                     *)
(*  5. A function call to an account without code, or to a missing         *)
(*     account, fails.  NearAsync does this itself (Contracts, HasCode);   *)
(*     FailNoCode is kept as an explicit step.                             *)
(*  6. Ghost sigpaid[a]: transactions signed by a's keys (a pays the gas). *)
(*  7. Delegate actions (NEP-366, meta transactions): a user signs a       *)
(*     delegate (SignedDelegate), a relayer submits it (SubmitDelegate),   *)
(*     ExecDelegate checks it on the user's account and emits the inner    *)
(*     receipt (runtime/runtime/src/actions.rs:453-535).  Delegate nonces  *)
(*     live in the key record (KeyNonce).                                  *)
(*                                                                         *)
(* A model that uses keys conjoins UNCHANGED keyVars to every step that    *)
(* does not touch keys, like any contract variable.                        *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS KeyAccts     \* accounts whose access keys are modelled
\* Contracts (accounts with code) is a NearAsync definition; a cfg
\* `Contracts = {...}` or `Contracts <- Def` sets it as before.

VARIABLES keys, sigpaid
keyVars == <<keys, sigpaid>>

Perm(rcv, ms, all) == [rcv |-> rcv, ms |-> ms, all |-> all]
FullPerm == [rcv |-> "", ms |-> {}, all |-> TRUE, full |-> TRUE]
IsFull(p) == "full" \in DOMAIN p /\ p.full

KeyPresent(a, k) == k \in DOMAIN keys[a]
\* The cases are written with IF so that they are mutually exclusive: an
\* overlapping disjunction in an action makes TLC generate the same
\* successor once per true disjunct.
KeyAllows(a, k, to, m) ==
    /\ KeyPresent(a, k)
    /\ IF IsFull(keys[a][k]) THEN TRUE
       ELSE /\ keys[a][k].rcv = to
            /\ IF keys[a][k].all \/ keys[a][k].ms = {} THEN TRUE ELSE m \in keys[a][k].ms
KeysWithout(a, k) == [keys EXCEPT ![a] = [x \in DOMAIN keys[a] \ {k} |-> keys[a][x]]]
KeysWith(a, k, p)  == [keys EXCEPT ![a] = (k :> p) @@ keys[a]]

\* Init helper: keys0 : [KeyAccts -> (key id -> permission)].
KeysInit(keys0) == keys = keys0 /\ sigpaid = [a \in Accounts |-> 0]

\* A receipt with more than one function-call action (a batch).  Receipt
\* records carry no action list, so this reads the per-call gas lists: in
\* fault mode give a multi-call transaction one static per call
\* (WithStatic(r, <<0, 0>>)), or a function-call key will be allowed to
\* sign it.
IsMultiCall(r) == Len(r.gs) > 1 \/ Len(r.g) > 1

\* Can key k of a sign the transaction whose first receipt is r?  A
\* function-call key: one action only, a function call (not Transfer, Stake
\* or a key action), no deposit (verifier.rs:209-250).  A model that bundles
\* key actions into a call receipt (WithKeyActs) must also require IsFull.
KeyCanSign(a, k, r) ==
    /\ KeyAllows(a, k, r.to, r.m)
    /\ IF IsFull(keys[a][k]) THEN TRUE
       ELSE /\ IsCall(r)
            /\ ~IsMultiCall(r)
            /\ r.dep = 0

\* Submit a signed transaction.  A key of a \in KeyAccts must be able to sign it.
SubmitSigned(r, a, k) ==
    /\ (a \in KeyAccts) => KeyCanSign(a, k, r)
    /\ SubmitAs(r, a, k)
    /\ sigpaid' = [sigpaid EXCEPT ![a] = @ + 1]
    /\ UNCHANGED keys

----------------------------------------------------------------------------
(* AddKey / DeleteKey receipts                                             *)

\* The bytes a function-call AddKey is charged per byte for: the sum over its
\* method names of (length + 1) (runtime/near-vm-runner/src/logic/utils.rs:4-6,
\* paid at host.rs:4078-4091); the receiver id and allowance are not charged
\* per byte.  An empty list (any method) is 0 bytes.  The model's names count
\* as written; WithMethodBytes(p, n) states the real byte count n instead,
\* for a model whose names are placeholders or abbreviated.
RECURSIVE NameBytes(_)
NameBytes(M) == IF M = {} THEN 0
                ELSE LET m == CHOOSE x \in M : TRUE IN Len(m) + 1 + NameBytes(M \ {m})
WithMethodBytes(p, n) == ("mb" :> n) @@ p
MethodBytes(p) == IF "mb" \in DOMAIN p THEN p.mb ELSE NameBytes(p.ms)

\* Constructors for key-action receipts on the creator's own account acct,
\* with the receipt's send + exec fee as the creator-side fee (gas mode),
\* per-byte part included (sir: the receipt is on the creator's account).
KeyFee(m, p) ==
    IF GasMode # "gas" THEN 0
    ELSE IF m = DELK THEN NearFeeTable!OneActionReceiptFee("delete_key", TRUE, "named")
    ELSE IF IsFull(p) THEN NearFeeTable!OneActionReceiptFee("add_key_full", TRUE, "named")
    ELSE NearFeeTable!OneActionReceiptFee("add_key_fc", TRUE, "named")
         + NearFeeTable!AddKeyFcBytesFee(TRUE, MethodBytes(p))
AddKeyRcpt(id, tx, acct, a, p, cb) == WithFee(Rcpt(id, tx, acct, acct, ADDK, a, 0, acct, cb), KeyFee(ADDK, p))
DelKeyRcpt(id, tx, acct, a, cb)    == WithFee(Rcpt(id, tx, acct, acct, DELK, a, 0, acct, cb), KeyFee(DELK, FullPerm))

\* Execute an AddKey / DeleteKey receipt.  k: key id, p: permission (AddKey only);
\* the model decodes them from its own r.a.
ExecKeyAct(r, k, p) ==
    /\ r.m \in {ADDK, DELK}
    /\ LET ok == /\ r.to = r.fr
                 /\ r.to \in KeyAccts
                 /\ IF r.m = DELK THEN KeyPresent(r.to, k) ELSE ~KeyPresent(r.to, k)
       IN IF ok
          THEN /\ rq'   = RemR(r)
               /\ post' = RemP(r)
               /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)
               /\ near' = [near EXCEPT ![r.to] = @ + r.dep]
               /\ keys' = IF r.m = DELK THEN KeysWithout(r.to, k) ELSE KeysWith(r.to, k, p)
               /\ rlog' = LogR(r, "ok")
               /\ UNCHANGED <<locked, proposal, epoch, nid, fails, paid, minted, oog, txsig, created,
                              burnt, blk, sigpaid>>
          ELSE FailP(r, FALSE) /\ UNCHANGED keyVars

----------------------------------------------------------------------------
(* Key actions inside a function-call receipt, e.g. [DeleteKey(k),         *)
(* FunctionCall(m)].  acts: the key actions that precede the call, in      *)
(* order (AddKeyAct / DelKeyAct).                                          *)
KAct(op, k, p) == [op |-> op, k |-> k, p |-> p]
AddKeyAct(k, p) == KAct("add", k, p)
DelKeyAct(k)    == KAct("del", k, FullPerm)

\* Fold acts over one account's key map: [ok, ks].
RECURSIVE KeysFold(_, _)
KeysFold(ks, acts) ==
    IF acts = <<>> THEN [ok |-> TRUE, ks |-> ks]
    ELSE LET x == Head(acts) IN
         IF x.op = "del"
         THEN IF x.k \in DOMAIN ks
              THEN KeysFold([y \in DOMAIN ks \ {x.k} |-> ks[y]], Tail(acts))
              ELSE [ok |-> FALSE, ks |-> ks]
         ELSE IF x.k \in DOMAIN ks
              THEN [ok |-> FALSE, ks |-> ks]
              ELSE KeysFold((x.k :> x.p) @@ ks, Tail(acts))

KeyActsOK(r, acts) ==
    acts = <<>> \/ (r.to = r.fr /\ r.to \in KeyAccts /\ KeysFold(keys[r.to], acts).ok)
KeysAfter(r, acts) ==
    IF acts = <<>> THEN keys ELSE [keys EXCEPT ![r.to] = KeysFold(keys[r.to], acts).ks]

\* The handler's outcome O for the function call, failed as a whole if a key
\* action fails (the call then does not run).
WithKeyActs(r, acts, O) == IF KeyActsOK(r, acts) THEN O ELSE OErr(O, "key action failed")
OkWithKeys(r, acts, O)  == Ok(r, WithKeyActs(r, acts, O))

\* Platform + keys part of running such a receipt.  The contract conjoins
\*   IF OkWithKeys(r, acts, O) THEN <its state := O's> ELSE UNCHANGED <its state>.
ExecWithKeys(r, acts, O) ==
    LET O2 == WithKeyActs(r, acts, O) IN
    /\ Exec(r, O2)
    /\ keys' = IF Ok(r, O2) THEN KeysAfter(r, acts) ELSE keys
    /\ UNCHANGED sigpaid

\* A function call to an account that has no contract (or does not exist).
\* Exec already fails such calls (NearAsync CallTargetOK); this is the same
\* rule as an explicit step for dispatchers.
FailNoCode(r) == IsCall(r) /\ ~HasCode(r.to) /\ FailP(r, FALSE)

----------------------------------------------------------------------------
(* Delegate actions (NEP-366, meta transactions).                          *)
(* The user s signs a delegate with its key k: nonce n, expiry height mbh  *)
(* and the inner receipt c (SignedDelegate).  A relayer rl sends a         *)
(* transaction to s carrying it (SubmitDelegate): rl is the signer, pays   *)
(* the gas and the inner deposit (runtime/runtime/src/config.rs:652-668).  *)
(* Its first receipt (DELEG, predecessor rl) runs on s: ExecDelegate       *)
(* checks the delegate and emits the inner receipt, with predecessor s,    *)
(* receiver c.to, and the outer receipt's signer, rl                       *)
(* (runtime/runtime/src/actions.rs:453-535, the receipt at :500-512).  The *)
(* inner receipt stays in rl's transaction, so Signer / SignerKey of it    *)
(* and of everything it spawns are rl and rl's key.  It is a new outgoing  *)
(* receipt, never local (runtime/runtime/src/lib.rs:1222-1234).            *)
(* Deposit refunds go to the failing receipt's predecessor                 *)
(* (core/primitives/src/receipt.rs:428-430; runtime/runtime/src/lib.rs:    *)
(* 1295-1303, :1402-1406): to rl if the outer receipt fails, to s if the   *)
(* inner one does.                                                         *)
(* A model builds a SignedDelegate only in a step of the user s itself     *)
(* (that is its signature); a relayer step that builds one for another     *)
(* account is a forgery, which nearcore rejects                            *)
(* (DelegateActionInvalidSignature, actions.rs:474-477).  A dispatcher     *)
(* routes IsDeleg(r) to ExecDelegate(r), before any contract handler (Exec *)
(* asserts on a DELEG receipt).                                            *)

\* mbh of a delegate without an expiry height.
NoExpiry == -1

\* Delegate nonces, per key, in the key record (field "nonce"; absent = 0).
\* A key re-added after a DeleteKey starts again at 0 (KeysWith); nearcore
\* starts a new key at (height - 1) * 1e6 (access_keys.rs:46-49, :240): an
\* over-approximation, see docs/SEMANTICS.md (K4).
KeyNonce(a, k) == IF "nonce" \in DOMAIN keys[a][k] THEN keys[a][k].nonce ELSE 0
KeysWithNonce(a, k, n) == [keys EXCEPT ![a][k] = ("nonce" :> n) @@ @]

\* The user s's signed delegate: its key k, nonce n (any integer; it must
\* exceed the key's last delegate nonce when it runs), expiry height mbh
\* (NoExpiry: none), and the inner receipt c, built with Rcpt: receiver,
\* method, args, deposit, and in gas mode its gas (WithGas).  c's id, tx,
\* fr, rto, cb and loc are set when the delegate runs.  A delegate cannot
\* carry a delegate (core/primitives/src/action/delegate.rs:371-433).
SignedDelegate(s, k, n, mbh, c) ==
    IF IsDeleg(c) THEN Assert(FALSE, <<"a delegate cannot carry a delegate", s, n>>)
    ELSE [snd |-> s, k |-> k, n |-> n, mbh |-> mbh, inner |-> c]

\* The relayer rl's first receipt: to the user, predecessor rl, the inner
\* deposit attached (paid by rl at submission; refunded to rl if this
\* receipt fails).  Action-only: it never runs out of gas.
DelegRcpt(id, tx, rl, sd) == Rcpt(id, tx, sd.snd, rl, DELEG, sd, sd.inner.dep, rl, 0)
\* The relayer's transaction, signed with its key k.  A function-call key
\* cannot sign it: it is not a function call (IsCall is FALSE;
\* runtime/runtime/src/verifier.rs:213-222).
SubmitDelegate(id, tx, rl, k, sd) == SubmitSigned(DelegRcpt(id, tx, rl, sd), rl, k)

\* Expiry: the delegate fails when block_height > max_block_height
\* (actions.rs:479-482), checked when the outer receipt runs.  With the
\* block clock (MaxBlk > 0) that is blk > mbh; without one (MaxBlk = 0) a
\* delegate with an expiry may fail at any time (an over-approximation).
DelegMayExpire(sd)  == sd.mbh # NoExpiry /\ (MaxBlk = 0 \/ blk > sd.mbh)
DelegMustExpire(sd) == sd.mbh # NoExpiry /\ MaxBlk > 0 /\ blk > sd.mbh

\* The inner receipt as the key check sees it (predecessor = the user).
DelegInner(r) == [r.a.inner EXCEPT !.fr = r.to]

\* The first failing check of the outer receipt r other than expiry, or "".
\* The account must exist and be initialised (actions.rs:861-886); the
\* delegate's sender must be r's receiver (:483-490); for a user in KeyAccts,
\* the key must exist (:587-602), the nonce must be above the key's
\* (:648-657), and a function-call key allows one zero-deposit function call
\* to its receiver and methods (:670-727; KeyCanSign, as for a transaction).
\* A user outside KeyAccts gets no key, nonce or permission check.
DelegErr(r) ==
    LET sd == r.a  s == r.to IN
    CASE ~AcctExists(s) \/ (s \in created /\ KindOf(s) = "universal") -> "AccountDoesNotExist"
      [] sd.snd # s                                           -> "SenderDoesNotMatchTxReceiver"
      [] s \in KeyAccts /\ ~KeyPresent(s, sd.k)               -> "AccessKeyNotFound"
      [] s \in KeyAccts /\ sd.n <= KeyNonce(s, sd.k)          -> "InvalidNonce"
      [] s \in KeyAccts /\ ~KeyCanSign(s, sd.k, DelegInner(r)) -> "AccessKeyError"
      [] OTHER                                                -> ""

\* Run the outer receipt r (IsDeleg(r)).  On success the key's nonce becomes
\* the delegate's (actions.rs:729-733) and the inner receipt is created with
\* a fresh id; the deposit travels with it.  On failure r fails like any
\* receipt: its deposit is refunded to rl (r.rto), no inner receipt.  The
\* contract conjoins UNCHANGED of its own variables.
ExecDelegate(r) ==
    /\ IsDeleg(r)
    /\ LET sd == r.a
           c  == [sd.inner EXCEPT !.id = nid, !.tx = r.tx, !.fr = r.to, !.rto = r.to,
                                  !.cb = 0, !.res = NoRes, !.loc = FALSE]
       IN \/ /\ ~DelegMustExpire(sd) /\ DelegErr(r) = ""
             /\ rq'   = RemR(r) \cup {c}
             /\ post' = RemP(r)
             /\ data' = RemD(r)
             /\ nid'  = nid + 1
             /\ keys' = IF r.to \in KeyAccts THEN KeysWithNonce(r.to, sd.k, sd.n) ELSE keys
             /\ rlog' = LogR(r, "ok")
             /\ UNCHANGED <<near, locked, proposal, epoch, fails, paid, minted, oog, txsig, created,
                            burnt, blk, sigpaid>>
          \/ /\ DelegMayExpire(sd) \/ DelegErr(r) # ""
             /\ FailP(r, FALSE)
             /\ UNCHANGED keyVars
=============================================================================
