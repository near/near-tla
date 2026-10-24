------------------------------- MODULE Payout -------------------------------
(***************************************************************************)
(* Detached work: the library's DetachedVoided (docs/SEMANTICS.md, F2).    *)
(*                                                                         *)
(* Payroll P owes payee B one payment (item 1, amount 1 NEAR).  Anyone may *)
(* call P.pay(): P marks the item done under a fresh ticket (here the      *)
(* call's transaction id) and hands the payment to a Transfer to B, marked *)
(* WithDetached: the work the Transfer carries.  B may delete              *)
(* its account meanwhile (beneficiary Z); a Transfer to a deleted named    *)
(* account fails and its NEAR returns to P (A4, A7).                       *)
(*                                                                         *)
(* DetachedVoided(Undone): once the transaction of a failed payout has     *)
(* settled, its ticket is not done any more (the item can be paid again;   *)
(* nothing counts that payout as paid).  The model states only what        *)
(* "voided" means for its work; the library finds the failed detached      *)
(* receipts.  Undone names the ticket, not the item: after a reopen a      *)
(* second pay legitimately marks the item done again.                      *)
(*                                                                         *)
(* WithCb = FALSE: P sends the Transfer and forgets it: the item stays     *)
(* done while the NEAR sits in P (payout_detached fails).  WithCb = TRUE:  *)
(* P chains on_paid(item) and reopens the item when the Transfer failed    *)
(* (payout_cb passes).                                                     *)
(*                                                                         *)
(* BothMarks = TRUE marks the Transfer WithOwed too (a library check, not  *)
(* a design): its failure is then recorded once with both marks, and each  *)
(* check sees it (payout_detached_both fails PayVoided, payout_cb_both     *)
(* fails OwedOK).                                                          *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS WithCb, BothMarks

VARIABLES done, sent   \* done: P's <<item, ticket>> pairs marked paid; sent: steps submitted
mine == <<done, sent>>
vars == <<platformVars, mine>>

P == "p"  B == "b"  Z == "z"  X == "x"
Accts  == {P, B, Z, X}
TxIds  == 1..3          \* 1 pay, 2 pay again, 3 B's delete
Near0  == [a \in Accts |-> CASE a = P -> 2 [] a = B -> 1 [] OTHER -> 0]   \* P: the payment and 1 of its own
Total0 == 3
Floor0 == [a \in Accts |-> 0]
PCode  == {P}
NoTable == [x \in {} |-> 0]
Item   == 1
Out0   == Outcome({}, {}, RVal(EMPTY), 0, 0)
Paid   == \E d \in done : d[1] = Item

\* P's handlers: [O |-> outcome, d |-> done after it].
H(r) ==
    CASE r.m = "pay" ->
           IF Paid THEN [O |-> OErr(Out0, "already paid"), d |-> done]
           ELSE LET w   == [k |-> Item, t |-> r.tx]
                    xfer == WithDetached(Rcpt(nid, r.tx, B, P, XFER, w, 1, P, IF WithCb THEN nid + 1 ELSE 0))
                    pay  == IF BothMarks THEN WithOwed(xfer) ELSE xfer
                    cb  == Rcpt(nid + 1, r.tx, P, P, "on_paid", w, 0, P, 0)
                IN IF WithCb THEN [O |-> Outcome({pay}, {cb}, RVal(EMPTY), 1, 2), d |-> done \cup {<<Item, r.tx>>}]
                   ELSE [O |-> Outcome({pay}, {}, RVal(EMPTY), 1, 1), d |-> done \cup {<<Item, r.tx>>}]
      [] r.m = "on_paid" ->     \* the Transfer failed: the ticket is void, the item open again
           [O |-> Out0, d |-> IF IsFailed(r.res) THEN done \ {<<r.a.k, r.a.t>>} ELSE done]

RunP(r) ==
    LET h == H(r) IN
    /\ Exec(r, h.O)
    /\ done' = IF Ok(r, h.O) THEN h.d ELSE done
    /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE IF IsAcctRcpt(r) THEN ExecAcct(r) /\ UNCHANGED mine
         ELSE RunP(r)

\* Each step once, in any order.  Submit refuses a deleted signer (CanSubmit).
Step(s, r) == /\ s \notin sent /\ Submit(r) /\ sent' = sent \cup {s} /\ UNCHANGED done
Pay1   == Step("pay1", Rcpt(nid, 1, P, X, "pay", [k |-> Item, t |-> 0], 0, X, 0))
Pay2   == Step("pay2", Rcpt(nid, 2, P, X, "pay", [k |-> Item, t |-> 0], 0, X, 0))
Delete == Step("del",  DeleteAcctRcpt(nid, 3, B, [k |-> 0, t |-> 0], Z, 0))

Init == PlatformInit(Near0, TxIds) /\ done = {} /\ sent = {}
Next == Pay1 \/ Pay2 \/ Delete \/ Run
Spec == Init /\ [][Next]_vars

\* A failed payout's ticket is void once its transaction has settled.
Undone(x) == <<x.a.k, x.a.t>> \notin done
PayVoided == DetachedVoided(Undone)
\* Once settled, P holds its own 1 NEAR, plus the payment while the item is open.
Funded == Idle => near[P] = 1 + (IF Paid THEN 0 ELSE 1)
Sane == NearConserved(Total0) /\ NoOrphans
=============================================================================
