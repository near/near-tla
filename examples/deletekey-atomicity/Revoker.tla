------------------------------- MODULE Revoker -------------------------------
(***************************************************************************)
(* Actions of one receipt are atomic: in a receipt                         *)
(* [DeleteKey(k), FunctionCall(m)], a DeleteKey of an absent key fails the *)
(* whole receipt, so m's state change is reverted too.                     *)
(*                                                                         *)
(* Account A runs a contract and has access keys k0 and k1.  The owner     *)
(* signs, with k0, transactions A.revoke(k1); two may be in flight at      *)
(* once.  revoke emits, to A itself, the key deletion and a call to        *)
(* A.on_revoked, which counts revocations.                                  *)
(*                                                                         *)
(* Correct A: one receipt [DeleteKey(k1), FunctionCall(on_revoked)].  The  *)
(* second revocation finds k1 absent; the whole receipt fails and the     *)
(* count is not bumped.                                                    *)
(* Wrong A (Wrong = TRUE): two separate receipts, [DeleteKey(k1)] and      *)
(* [FunctionCall(on_revoked)].  The second DeleteKey fails on its own     *)
(* while its on_revoked still commits, so A counts two revocations of one *)
(* key.                                                                    *)
(*                                                                         *)
(* Counted: once idle, the count equals the number of keys deleted.        *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS A, MaxTx, Wrong

VARIABLES revoked, ntx
vars == <<platformVars, keyVars, revoked, ntx>>

Accts == {A}
TxIds == 1..MaxTx
Keys0 == [a \in {A} |-> ("k0" :> FullPerm) @@ ("k1" :> FullPerm)]
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Arg(k) == [k |-> k]

Revoke == /\ ntx < MaxTx
          /\ SubmitSigned(Rcpt(nid, ntx + 1, A, A, "revoke", Arg("k1"), 0, A, 0), A, "k0")
          /\ ntx' = ntx + 1
          /\ UNCHANGED revoked

\* revoke(k): the key deletion and the counting call, bundled or not.
HRevoke(r) ==
    LET k == r.a.k
        on == Rcpt(nid, r.tx, A, A, "on_revoked", Arg(k), 0, A, 0)
        dk == DelKeyRcpt(nid + 1, r.tx, A, Arg(k), 0)
    IN IF Wrong THEN Outcome({on, dk}, {}, RVal(0), 0, 2)
       ELSE Outcome({on}, {}, RVal(0), 0, 1)

\* Key actions that precede the FunctionCall in an on_revoked receipt.
Acts(r) == IF Wrong THEN <<>> ELSE <<DelKeyAct(r.a.k)>>

RunA(r) ==
    IF r.m = "revoke"
    THEN Exec(r, HRevoke(r)) /\ UNCHANGED <<keyVars, revoked, ntx>>
    ELSE LET O == Outcome({}, {}, RVal(0), 0, 0) IN
         /\ ExecWithKeys(r, Acts(r), O)
         /\ revoked' = IF OkWithKeys(r, Acts(r), O) THEN revoked + 1 ELSE revoked
         /\ UNCHANGED ntx

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<keyVars, revoked, ntx>>
           [] IsKeyRcpt(r) -> ExecKeyAct(r, r.a.k, FullPerm) /\ UNCHANGED <<revoked, ntx>>
           [] OTHER        -> RunA(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ KeysInit(Keys0)
        /\ revoked = 0 /\ ntx = 0

Next == Revoke \/ Run
Spec == Init /\ [][Next]_vars

Counted == Idle => revoked = Cardinality({"k0", "k1"} \ DOMAIN keys[A])
\* k0 signs every transaction and is never deleted.
OwnerKeyKept == "k0" \in DOMAIN keys[A]
\* Library sanity: native NEAR conserved, and no orphans.
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
