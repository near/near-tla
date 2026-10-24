-------------------------------- MODULE Relay --------------------------------
(***************************************************************************)
(* Worst-case trie gas is not monotone downstream (docs/SEMANTICS.md, G6). *)
(*                                                                         *)
(* U calls V.go with Prepaid Ggas.  go writes one key (OWriteKey) and      *)
(* calls W.work with all its leftover (static 0, weight 1).  work calls    *)
(*     X.ping().then(W.on_ping())                                          *)
(* on_ping is owed (WithOwed) and gets work's leftover (static 0, weight   *)
(* 1); it burns 12 Ggas.                                                   *)
(*                                                                         *)
(* go's write costs 0 to 214 nodes more than calibrated (a 64-byte account *)
(* id and a 40-byte key), 0 to 488 Ggas, and work gets 500 Ggas less that. *)
(*   0 extra:   work gets 500, on_ping 445: it commits.                    *)
(*   488 extra: work gets 12, below its own 55: work runs out of gas and   *)
(*              creates no on_ping.  Nothing owed fails.                   *)
(*   434 extra (190 nodes): work gets 66 and commits; on_ping gets 11 of   *)
(*              its 12 and runs out.  OwedOK fails.                        *)
(* So the two ends alone (TrieGasEnds) pass, and the library's default,    *)
(* every node count, finds the failure.  With Prepaid 660 Ggas work has    *)
(* 67 at the bound and on_ping 12: every node count passes.                *)
(*                                                                         *)
(* ILLUSTRATIVE burns, not measured; the trie-node price and bound are     *)
(* nearcore's (88).                                                        *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, V, W, X,
    Prepaid,    \* gas U attaches to go, Ggas
    KeyLen      \* bytes of the key go writes

VARIABLES sent
vars == <<platformVars, sent>>

Accts   == {U, V, W, X}
Floor0  == [a \in Accts |-> 0]

GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
LGasCall == ("work"    :> GC(<<0>>, <<1>>, 5))
         @@ ("ping"    :> GC(<<5>>, <<0>>, 5))
         @@ ("on_ping" :> GC(<<0>>, <<1>>, 5))
LGasBurn == ("go"      :> [base |-> 100, per |-> 0])
         @@ ("work"    :> [base |-> 40, per |-> 0])
         @@ ("ping"    :> [base |-> 3, per |-> 0])
         @@ ("on_ping" :> [base |-> 12, per |-> 0])

Out0 == Outcome({}, {}, RVal(EMPTY), 0, 0)

O(r) ==
    CASE r.m = "go"   -> OWriteKey(Outcome({Rcpt(nid, r.tx, W, V, "work", 0, 0, V, 0)}, {}, RVal(EMPTY), 0, 1), KeyLen)
      [] r.m = "work" -> Outcome({Rcpt(nid, r.tx, X, W, "ping", 0, 0, W, nid + 1)},
                                 {WithOwed(Rcpt(nid + 1, r.tx, W, W, "on_ping", 0, 0, W, r.cb))}, RProm, 0, 2)
      [] OTHER        -> Out0

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED sent
         ELSE Exec(r, O(r)) /\ UNCHANGED sent

Go == /\ ~sent
      /\ Submit(WithGas(Rcpt(nid, 1, V, U, "go", 0, 0, U, 0), Prepaid))
      /\ sent' = TRUE

Init == PlatformInit([a \in Accts |-> 0], {1}) /\ sent = FALSE
Next == Go \/ Run
Spec == Init /\ [][Next]_vars

Sane == NearConserved(0) /\ NoOrphans
=============================================================================
