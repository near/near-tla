-------------------------------- MODULE Vault --------------------------------
(***************************************************************************)
(* Per-byte storage staking (docs/SEMANTICS.md, B2): a write the balance   *)
(* cannot cover fails the whole receipt with LackBalanceForState.          *)
(*                                                                         *)
(* Vault V owes each user one unit.  withdraw() pays it with a Transfer    *)
(* and records the payout in the books: a new record of RecBytes bytes.   *)
(* A lock (an existing field: no new bytes) stops a second withdraw while  *)
(* one is in flight.                                                       *)
(*  Wrong = TRUE: withdraw locks and pays; the callback on_paid writes the *)
(*    record once the Transfer succeeded.  The payout lowered V's balance  *)
(*    and the record raises the bytes it must cover, so on_paid can fail   *)
(*    for storage after the money left: paid, not recorded.                *)
(*  Wrong = FALSE: the record is written in the paying receipt, so a       *)
(*    storage shortfall fails the payout with it.                          *)
(* The model gives both storage descriptions; StoragePerByte picks one:    *)
(*  FALSE: the 0.1.0 rule, a fixed StorageFloor (VFloor: the 1000 bytes V  *)
(*    starts with, 10 units).  The records' growth is invisible, so the    *)
(*    wrong vault passes: a false pass.                                    *)
(*  TRUE: V's bytes (VStor, then each record's RecBytes via OStor) priced  *)
(*    at Cost.  The second record needs more than V has left.              *)
(* Units: 1 unit = 1 milliNEAR, so 1e19 yocto per byte is 100 bytes per    *)
(* unit (Cost = <<1, 100>>).  V starts with V0 = 13 units and 1000 bytes.  *)
(*                                                                         *)
(* Books     once idle, the NEAR each user received equals the payouts     *)
(*           recorded for them.                                            *)
(* PaidOnce  no user is paid twice.                                        *)
(* NobodyPaid  (must fail) some payout commits: the correct vault's pass   *)
(*           is not vacuous.                                               *)
(* VaultCovered  V's balance covers its bytes (per byte only).            *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS Users, V, MaxTx, Wrong, RecBytes, V0

VARIABLES lockd, rec, ntx
mine == <<lockd, rec, ntx>>
vars == <<platformVars, mine>>

Accts == Users \cup {V}
TxIds == 1..MaxTx
NoGasTable == [x \in {} |-> 0]
Cost   == <<1, 100>>
VFloor == [a \in Accts |-> IF a = V THEN 10 ELSE 0]
VStor  == [a \in Accts |-> IF a = V THEN 1000 ELSE 0]

\* A handler's outcome that writes u's record: RecBytes new bytes.
Rec(O) == OStor(O, RecBytes)
Out0 == Outcome({}, {}, RVal(0), 0, 0)

Ask == /\ ntx < MaxTx
       /\ \E u \in Users : Submit(Rcpt(nid, ntx + 1, V, u, "withdraw", [u |-> u], 0, u, 0))
       /\ ntx' = ntx + 1
       /\ UNCHANGED <<lockd, rec>>

\* Handlers return the outcome and V's new lock and books.
H(r) ==
  LET u == r.a.u
      Pay(cb) == Rcpt(nid, r.tx, u, V, XFER, r.a, 1, V, cb) IN
  CASE r.m = "withdraw" /\ (lockd[u] \/ rec[u] > 0) ->
         [O |-> OErr(Out0, "already paid"), l |-> lockd, c |-> rec]
    [] r.m = "withdraw" /\ Wrong ->        \* lock, pay, then on_paid records
         [O |-> Outcome({Pay(nid + 1)}, {Rcpt(nid + 1, r.tx, V, V, "on_paid", r.a, 0, V, 0)}, RVal(0), 1, 2),
          l |-> [lockd EXCEPT ![u] = TRUE], c |-> rec]
    [] r.m = "withdraw" ->                 \* record and pay in one receipt
         [O |-> Rec(Outcome({Pay(0)}, {}, RVal(0), 1, 1)),
          l |-> lockd, c |-> [rec EXCEPT ![u] = 1]]
    [] r.m = "on_paid" /\ r.res.ok ->      \* the Transfer arrived: record it
         [O |-> Rec(Out0), l |-> lockd, c |-> [rec EXCEPT ![u] = 1]]
    [] r.m = "on_paid" ->                  \* it did not: unlock
         [O |-> Out0, l |-> [lockd EXCEPT ![u] = FALSE], c |-> rec]

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE LET h == H(r) IN
              /\ Exec(r, h.O)
              /\ lockd' = IF Ok(r, h.O) THEN h.l ELSE lockd
              /\ rec'   = IF Ok(r, h.O) THEN h.c ELSE rec
              /\ UNCHANGED ntx

Init == /\ PlatformInit([a \in Accts |-> IF a = V THEN V0 ELSE 0], TxIds)
        /\ lockd = [u \in Users |-> FALSE] /\ rec = [u \in Users |-> 0] /\ ntx = 0

Next == Ask \/ Run
Spec == Init /\ [][Next]_vars

Books      == Idle => \A u \in Users : near[u] = rec[u]
PaidOnce   == \A u \in Users : near[u] <= 1
NobodyPaid == \A u \in Users : rec[u] = 0
\* V's balance covers its bytes at Cost, written out here: StorageCovered uses
\* the library's own check, so it cannot see that check go missing.
VaultCovered == StoragePerByte => near[V] * Cost[2] >= stor[V] * Cost[1]
\* Library sanity: NEAR conserved; with StoragePerByte, every balance covers its
\* bytes; no orphans (the wrong vault's on_paid waits on the Transfer's result).
Sane       == NearConserved(V0) /\ StorageCovered /\ NoOrphans
=============================================================================
