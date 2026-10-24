------------------------------- MODULE Escrow -------------------------------
(***************************************************************************)
(* A payee can delete its account while a payment to it is in flight.      *)
(*                                                                         *)
(* Escrow E holds a claim for payee P.  Payer A deposits into it           *)
(* (deposit(), the attached NEAR); P withdraws (withdraw(): E zeroes the   *)
(* claim and Transfers it to the caller).  Anyone may call withdraw; E     *)
(* refuses a caller other than P.  Meanwhile P (or A, see below) may       *)
(* delete its account, with beneficiary B (docs/SEMANTICS.md, A7).         *)
(*                                                                         *)
(* A Transfer to a deleted named account fails, and its deposit returns to *)
(* the sender, E (A7; actions.rs:842-849).  Without a callback E never     *)
(* hears of it: the claim is 0 and the NEAR sits in E, owned by no one     *)
(* (FundsClaimable fails, run escrow_pays_deleted).  With WithCb, E        *)
(* chains on_paid(n) after the Transfer and restores the claim when the    *)
(* Transfer failed (run escrow_pays_cb).                                   *)
(*                                                                         *)
(* Run refund_to_deleted_burns: a platform demonstration, not a contract   *)
(* bug.  A deposits, then deletes its own account before the deposit       *)
(* receipt runs; the deposit fails (a forced fault), and its refund to A,  *)
(* which no longer exists, is burnt (lib.rs:1046-1054): NoBurn fails.      *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS
    WithCb,     \* E chains on_paid after the Transfer and restores a failed payment
    Leaver      \* the account that may delete itself: P, or A

VARIABLES claim, sent   \* claim: E's record of what P may withdraw; sent: steps submitted
mine == <<claim, sent>>
vars == <<platformVars, mine>>

A == "a"  E == "e"  P == "p"  B == "b"
Accts   == {A, E, P, B}
TxIds   == 1..4      \* 1 deposit, 2 P's withdraw, 3 A's withdraw, 4 the delete
Near0   == [x \in Accts |-> CASE x = A -> 4 [] x = P -> 1 [] OTHER -> 0]
Total0  == 5
Floor0  == [x \in Accts |-> 0]
EscCode == {E}
NoTable == [x \in {} |-> 0]
Arg(n)  == [n |-> n]
Out0    == Outcome({}, {}, RVal(0), 0, 0)

\* E's handlers: [O |-> outcome, c |-> claim after it].
H(r) ==
    CASE r.m = "deposit" -> [O |-> Out0, c |-> claim + r.dep]
      [] r.m = "withdraw" ->
           IF r.fr # P \/ claim = 0 THEN [O |-> OErr(Out0, "nothing to withdraw"), c |-> claim]
           ELSE LET pay == Rcpt(nid, r.tx, r.fr, E, XFER, Arg(claim), claim, E, IF WithCb THEN nid + 1 ELSE 0)
                    cb  == Rcpt(nid + 1, r.tx, E, E, "on_paid", Arg(claim), 0, E, 0)
                IN IF WithCb THEN [O |-> Outcome({pay}, {cb}, RVal(0), claim, 2), c |-> 0]
                   ELSE [O |-> Outcome({pay}, {}, RVal(0), claim, 1), c |-> 0]
      [] r.m = "on_paid" ->     \* the Transfer failed: P may withdraw again
           [O |-> Out0, c |-> IF IsFailed(r.res) THEN claim + r.a.n ELSE claim]

RunE(r) ==
    LET h == H(r) IN
    /\ Exec(r, h.O)
    /\ claim' = IF Ok(r, h.O) THEN h.c ELSE claim
    /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE IF IsAcctRcpt(r) THEN ExecAcct(r) /\ UNCHANGED mine
         ELSE RunE(r)

\* Each step once, in any order.  Submit refuses a deleted signer (CanSubmit).
Step(s, t, r) == /\ s \notin sent /\ Submit(r) /\ sent' = sent \cup {s} /\ UNCHANGED claim
Deposit  == Step("dep",  1, Rcpt(nid, 1, E, A, "deposit", Arg(0), 2, A, 0))
WithdrawP == Step("wdP", 2, Rcpt(nid, 2, E, P, "withdraw", Arg(0), 0, P, 0))
WithdrawA == Step("wdA", 3, Rcpt(nid, 3, E, A, "withdraw", Arg(0), 0, A, 0))
Delete   == Step("del",  4, DeleteAcctRcpt(nid, 4, Leaver, Arg(0), B, 0))

Init == PlatformInit(Near0, TxIds) /\ claim = 0 /\ sent = {}
Next == \/ Deposit \/ WithdrawP \/ WithdrawA \/ Delete \/ Run
        \/ \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine
Spec == Init /\ [][Next]_vars

\* Once settled, every NEAR E holds is someone's claim: none is stranded.
FundsClaimable == Idle => near[E] = claim
\* E pays only P: no withdraw transaction (2, 3) credits A (paid: what the
\* platform's Transfer and refund receipts credited, per transaction).
PaysOnlyPayee == \A t \in {2, 3} : paid[t][A] = 0
\* Nothing is burnt.
NoBurn == burnt = 0
Sane == NearConserved(Total0) /\ NoOrphans
=============================================================================
