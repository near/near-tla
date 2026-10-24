------------------------------ MODULE NearKeys ------------------------------
(***************************************************************************)
(* Access keys on top of NearAsync (the signer itself is in NearAsync).    *)
(*                                                                         *)
(*  1. Access keys.  keys[a] : key id -> permission                        *)
(*     Perm(rcv, ms, all): a function-call key for receiver rcv, methods   *)
(*     ms (or any method if all); FullPerm: a full-access key.             *)
(*     A function-call key may only sign a zero-deposit function call to   *)
(*     its receiver with a permitted method                                *)
(*     (runtime/runtime/src/verifier.rs:205-250).                          *)
(*  2. SubmitSigned(r, a, k): a transaction signed by a with key k.        *)
(*  3. AddKey / DeleteKey receipts (ADDK / DELK, ExecKeyAct).  Key actions *)
(*     are only allowed on the predecessor's own account                   *)
(*     (runtime/runtime/src/actions.rs:755-775, ActorNoPermission);        *)
(*     deleting an absent key (access_keys.rs:84) or adding a present key  *)
(*     (access_keys.rs:158) fails the receipt.                             *)
(*  4. Multi-action receipts such as [DeleteKey(k), FunctionCall]: the     *)
(*     actions of one receipt run in order and are atomic                  *)
(*     (runtime/runtime/src/lib.rs:944-1006: the first failing action      *)
(*     stops the receipt, and the whole receipt rolls back,                *)
(*     lib.rs:1078-1088).  WithKeyActs / ExecWithKeys.                     *)
(*  5. A function call to an account without code, or to a missing        *)
(*     account, fails: FailNoCode (function_call.rs:309-312 CodeDoesNotExist; *)
(*     actions.rs:874-879 AccountDoesNotExist).                            *)
(*  6. Ghost sigpaid[a]: transactions signed by a's keys (a pays the gas). *)
(*                                                                         *)
(* A model that uses keys conjoins UNCHANGED keyVars to every step that    *)
(* does not touch keys, like any contract variable.                        *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS KeyAccts,    \* accounts whose access keys are modelled
          Contracts    \* accounts with deployed code (function calls elsewhere fail)

VARIABLES keys, sigpaid
keyVars == <<keys, sigpaid>>

ADDK == "ADDKEY"
DELK == "DELKEY"
IsKeyRcpt(r) == r.m \in {ADDK, DELK}

Perm(rcv, ms, all) == [rcv |-> rcv, ms |-> ms, all |-> all]
FullPerm == [rcv |-> "", ms |-> {}, all |-> TRUE, full |-> TRUE]
IsFull(p) == "full" \in DOMAIN p /\ p.full

KeyPresent(a, k) == k \in DOMAIN keys[a]
KeyAllows(a, k, to, m) ==
    /\ KeyPresent(a, k)
    /\ \/ IsFull(keys[a][k])
       \/ /\ keys[a][k].rcv = to
          /\ (keys[a][k].all \/ m \in keys[a][k].ms)
KeysWithout(a, k) == [keys EXCEPT ![a] = [x \in DOMAIN keys[a] \ {k} |-> keys[a][x]]]
KeysWith(a, k, p)  == [keys EXCEPT ![a] = (k :> p) @@ keys[a]]

\* Init helper: keys0 : [KeyAccts -> (key id -> permission)].
KeysInit(keys0) == keys = keys0 /\ sigpaid = [a \in Accounts |-> 0]

\* Submit a signed transaction.  A key of a \in KeyAccts must permit the call;
\* a function-call key cannot attach a deposit (verifier.rs:222-227).
SubmitSigned(r, a, k) ==
    /\ (a \in KeyAccts) => (KeyAllows(a, k, r.to, r.m) /\ (IsFull(keys[a][k]) \/ r.dep = 0))
    /\ SubmitAs(r, a, k)
    /\ sigpaid' = [sigpaid EXCEPT ![a] = @ + 1]
    /\ UNCHANGED keys

----------------------------------------------------------------------------
(* AddKey / DeleteKey receipts                                             *)

\* Constructors for key-action receipts on the creator's own account acct,
\* with the receipt's send + exec fee as the creator-side fee (gas mode).
KeyFee(m, p) ==
    IF GasMode # "gas" THEN 0
    ELSE IF m = DELK THEN NearFeeTable!OneActionReceiptFee("delete_key", TRUE, "named")
    ELSE IF IsFull(p) THEN NearFeeTable!OneActionReceiptFee("add_key_full", TRUE, "named")
    ELSE NearFeeTable!OneActionReceiptFee("add_key_fc", TRUE, "named")   \* per-byte part not modelled
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
                              sigpaid>>
          ELSE FailP(r, FALSE) /\ UNCHANGED keyVars

----------------------------------------------------------------------------
(* Key actions inside a function-call receipt, e.g. [DeleteKey(k),         *)
(* FunctionCall(m)].  acts: the key actions that precede the call, in       *)
(* order (AddKeyAct / DelKeyAct).                                           *)
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
FailNoCode(r) ==
    /\ r.m \notin {XFER, REFND, STAKE, ADDK, DELK}
    /\ r.to \notin Contracts
    /\ FailP(r, FALSE)
=============================================================================
