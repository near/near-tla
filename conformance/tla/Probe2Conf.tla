------------------------------ MODULE Probe2Conf ------------------------------
(***************************************************************************)
(* Conformance driver for the probe2 flows (conformance/flows/probes2.toml,*)
(* the flow set probes2 of scripts/flowsets.py): ProbeConf's driver and    *)
(* world, plus the account "z" running the second generic probe            *)
(* (conformance/probes/probe2) and the plain account "bob".  The generated *)
(* cfg replaces ProbeConf's Accts, ConfContracts and Run by Accts2,        *)
(* ConfContracts2 and Run2 (TLC's `<-`), so ProbeConf and every probes run *)
(* stay as they are.  Run2 is ProbeConf's Run with z's handlers (PZ).      *)
(*                                                                         *)
(* probe2, on account "z" (payload Z0; a result size n is in KB):          *)
(*   refund_call  one call (kids[1]), its refund target rto ("" unset: z,   *)
(*           the predecessor); the call's deposit leaves z                 *)
(*   paid    panics ("paid fail"): its deposit is refunded to its rto      *)
(*   join    kids joined with promise_and, flat or nested (nest), then cb; *)
(*           the joint callback's inputs are the kids flattened in         *)
(*           argument order: "inner" ((k1 & k2) & k0) gives k1, k2, k0     *)
(*   on_expect  fails unless result i (0-based) is n KB, -1 for Failed     *)
(*   yield_id  yields on_yield (static st, weight 1) under the custom id  *)
(*           `id` ("" : a plain promise_yield_create) with deposit dep,    *)
(*           unless a yield of z with that id is pending (then nothing is  *)
(*           created: the host's u64::MAX); with twice, a second create in *)
(*           the same call (always a duplicate); with ret, the yield is    *)
(*           returned (its callback's result is the caller's)              *)
(*   resume  resumes z's pending yield with custom id `id` ("" : the plain *)
(*           yield) with n bytes, if any (OResume)                         *)
(*   on_yield  the yield callback: returns the payload (empty on a         *)
(*           timeout); with again, re-creates its own id (static          *)
(*           AgainGgas, weight 1) unless pending                           *)
(*   stake_then  a Stake of amt by z itself, then cb on its result         *)
(* The custom-id duplicate check is the handler's (NearAsync's             *)
(* PendingYieldRcpts; docs/SEMANTICS.md C7, "Left to the handler"): the id *)
(* is kept in each yield's payload.                                        *)
(* Burn keys follow the calibration's (CalibProbes2.tla): a method that    *)
(* shows several child shapes is keyed "<method>/<shape>/<path>" ("-": no *)
(* children); the handlers pick the shape and path by what they do.       *)
(***************************************************************************)
EXTENDS ProbeConf

Accts2 == {"alice", "dave", "p", "q", "y", "nobody", "nimp", "nimp_new", "eth", "eth_new", "z", "bob"} \cup Toks
ConfContracts2 == {"p", "q", "y", "z"} \cup Toks

\* The static gas of the yield on_yield re-creates (probe2's on_yield).
AgainGgas == 5000

Z0 == [kids |-> <<>>, cb |-> <<>>, gk |-> "", rto |-> "", nest |-> "flat", i |-> 0, n |-> 0,
       id |-> "", dep |-> 0, st |-> 0, twice |-> FALSE, ret |-> FALSE, again |-> FALSE, amt |-> 0]
ZA(f) == CxArgs(f)

ZKey(r, k) == r.to \o "." \o k

HRefundCall(r) ==
    LET x == Px(r)  k == x.kids[1]
        c == WithCall(Rcpt(nid, r.tx, k.to, r.to, k.m, k.a, k.dep, IF x.rto = "" THEN r.to ELSE x.rto, 0),
                      <<k.st>>, <<k.wt>>)
    IN OKey(Outcome({c}, {}, RVal(EMPTY), k.dep, 1), ZKey(r, x.gk))

\* A panic's key is its burn up to the panic.
HPaid(r) == OPanicKey(OErr(Outcome({}, {}, RVal(0), 0, 0), "paid fail"), LeafKey(r))

\* Kids get ids nid .. nid+n-1 in creation (argument) order, the callback
\* nid+n; the data ids nid+n+1 .. nid+2n follow the flattened join order.
HJoin(r) ==
    LET x == Px(r)  n == Len(x.kids)  cbId == nid + n
        ord == IF x.nest = "inner" THEN <<2, 3, 1>> ELSE [j \in 1..n |-> j]
        Kid(i) == LET k == x.kids[i] IN
                  WithCall(Rcpt(nid + i - 1, r.tx, k.to, r.to, k.m, k.a, k.dep, r.to, 0), <<k.st>>, <<k.wt>>)
        Cb == LET c == x.cb[1] IN
              WithCall(Rcpt(cbId, r.tx, c.to, r.to, c.m, c.a, 0, r.to, 0), <<c.st>>, <<c.wt>>)
        J == AndThen([j \in 1..n |-> Kid(ord[j])], Cb, nid + n + 1)
    IN OKey(Outcome({J.kids[j] : j \in 1..n}, {J.cb}, RVal(EMPTY), 0, 2 * n + 1), ZKey(r, x.gk))

HOnExpect(r) ==
    LET x == Px(r)  res == ResAt(r, x.i + 1)
        got == IF res.ok THEN res.sz ELSE -1
        O == Leaf(r, RVal(got), 0)
    IN IF got = x.n THEN O ELSE OErr(O, "result is not as expected")

\* A yield of z with custom id `id` is pending, as r's handler sees it (ps:
\* the yields it has created so far).
IdPending(r, ps, id) == \E y \in PendingYieldRcpts(r, ps) : Px(y).id = id

\* One create, two with twice: each makes a yield unless its custom id is
\* pending, the first's included.
HYieldId(r) ==
    LET x == Px(r)
        Y(id1, ret) == WithCall(YieldRcpt(id1, r, "on_yield", ZA([Z0 EXCEPT !.id = x.id, !.again = x.again]), x.dep,
                                          IF ret THEN r.cb ELSE 0), <<x.st>>, <<1>>)
        made1 == x.id = "" \/ ~IdPending(r, {}, x.id)
        ys1 == IF made1 THEN {Y(nid, x.ret)} ELSE {}
        made2 == x.twice /\ (x.id = "" \/ ~IdPending(r, ys1, x.id))
        ys == ys1 \cup (IF made2 THEN {Y(nid + Cardinality(ys1), FALSE)} ELSE {})
        dup == ~made1 \/ (x.twice /\ ~made2)
        O == Outcome({}, ys, IF x.ret /\ made1 THEN RProm ELSE RVal(EMPTY), x.dep * Cardinality(ys), Cardinality(ys))
        \* a flow's path names the whole key (mkconf.py); two yields would
        \* be shape "on_yield,on_yield", which the table lacks (TLC stops)
        k == IF x.gk # "" THEN x.gk
             ELSE "yield_id/" \o (IF ys = {} THEN "-" ELSE IF Cardinality(ys) = 1 THEN "on_yield" ELSE "on_yield,on_yield")
                  \o (IF dup THEN "/dup" ELSE "/new")
    IN OKey(O, ZKey(r, k))

HResume2(r) ==
    LET x == Px(r)
        ys == {y \in PendingYieldRcpts(r, {}) : Px(y).id = x.id}
        O == Outcome({}, {}, RVal(0), 0, 0)
    IN IF ys = {} THEN OKey(O, ZKey(r, "resume/none"))
       ELSE OKey(OResume([O EXCEPT !.ret = RVal(1)], (CHOOSE y \in ys : TRUE).id, NONEMPTY, x.n \div 1000),
                 ZKey(r, "resume/ok"))

HOnYield2(r) ==
    LET x == Px(r)  ok == r.res.ok
        made == x.again /\ ~IdPending(r, {}, x.id)
        A == WithCall(YieldRcpt(nid, r, "on_yield", ZA([Z0 EXCEPT !.id = x.id]), 0, 0), <<AgainGgas>>, <<1>>)
        O == Outcome({}, IF made THEN {A} ELSE {}, IF ok THEN RValSz(NONEMPTY, r.res.sz) ELSE RVal(EMPTY),
                     0, IF made THEN 1 ELSE 0)
    IN OKey(O, ZKey(r, "on_yield/" \o (IF made THEN "on_yield" ELSE "-") \o "/" \o (IF ok THEN "payload" ELSE "timeout")))

HStakeThen(r) ==
    LET x == Px(r)  c == x.cb[1]
        s == Rcpt(nid, r.tx, r.to, r.to, STAKE, [x1 |-> x.amt], 0, r.to, nid + 1)
        Cb == WithCall(Rcpt(nid + 1, r.tx, c.to, r.to, c.m, c.a, 0, r.to, 0), <<c.st>>, <<c.wt>>)
    IN OKey(Outcome({s}, {Cb}, RVal(EMPTY), 0, 2), ZKey(r, x.gk))

PZ(r) ==
    CASE r.m = "refund_call" -> HRefundCall(r)
      [] r.m = "paid"        -> HPaid(r)
      [] r.m = "join"        -> HJoin(r)
      [] r.m = "on_expect"   -> HOnExpect(r)
      [] r.m = "yield_id"    -> HYieldId(r)
      [] r.m = "resume"      -> HResume2(r)
      [] r.m = "on_yield"    -> HOnYield2(r)
      [] r.m = "stake_then"  -> HStakeThen(r)
      [] OTHER               -> OErr(Outcome({}, {}, RVal(0), 0, 0), "method not found")

PH2(r) == IF r.to = "z" THEN PZ(r) ELSE PH(r)

\* ProbeConf's Run, with PH2.
Run2 ==
    \E r \in Runnable :
       /\ IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<tk, keyVars>>
          ELSE IF IsDeleg(r) THEN ExecDelegate(r) /\ UNCHANGED tk
          ELSE IF IsTokRcpt(r) THEN \E ch \in TokChoices(r) : TokStep(r, TokHandle(r, ch)) /\ UNCHANGED keyVars
          ELSE Exec(r, PH2(r)) /\ UNCHANGED <<tk, keyVars>>
       /\ UNCHANGED confVars
=============================================================================
