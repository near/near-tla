------------------------------ MODULE ProbeConf ------------------------------
(***************************************************************************)
(* Conformance driver for the probe flows (conformance/flows/probes.toml). *)
(* One flow per run: the world of the flow spec is the initial state, and *)
(* the flow's transaction is submitted once at every prepaid value of     *)
(* Grid (Ggas).  Its After steps follow, each once nothing can run (as    *)
(* the sim's harness runs them once the chain is idle): a transaction at  *)
(* its own gas, or a block (BlockTick) that times out the parked yield.   *)
(* Report prints, in every terminal state, the number of yields still     *)
(* parked and the per-receipt outcome log of every transaction (PrintT is *)
(* TRUE, so TLC never stops); scripts/conform.py compares them with the   *)
(* sim's sweep.  Transactions are numbered 1, 2, ... in the order they    *)
(* are sent, counting only transactions (an expire step is a block), as   *)
(* the sim's sweep numbers them (from 0).                                 *)
(*                                                                         *)
(* The probe contract (conformance/probes/probe), on accounts "p" and "q": *)
(*   chain   creates kids (each its own function call with the static gas *)
(*           and weight in the payload); with several kids they are       *)
(*           joined (AndThen: cb waits on all of them), or with det all   *)
(*           but the last are detached and cb waits on the last kid       *)
(*   burn    burns n Ggas                       (key "<acct>.burn", sz n) *)
(*   ret     returns n KB                       (key "<acct>.ret", sz n)  *)
(*   on_read reads every result in full         (sz = result size, KB)    *)
(*   on_count only counts its results                                     *)
(*   send    a Transfer of amt to `to`, optionally then on_read           *)
(*   batch   one receipt holding the given function calls (a token batch) *)
(*   ft_on_transfer  NEP-141 receiver; msg keep / return / over / panic / *)
(*           burn20000 (burns 20 Tgas, keeps) / big2000 (2 KB, not a      *)
(*           number)                                                      *)
(* The async probe (conformance/probes/async-probe), on account "y":     *)
(*   yield_create  yields on_yield (YieldRcpt, static st, weight wt);     *)
(*           with rb >= 0 resumes it in the same call (rb bytes)          *)
(*   resume  resumes y's pending yield, if any (OResume)                  *)
(*   on_yield  the yield callback (payload or timeout)                    *)
(*   on_order  a joint callback that fails iff its first result failed    *)
(* A leaf's burn key is "<acct>.<method>", or "<acct>.<gk>" when its      *)
(* payload names one (a flow path, mkconf.py).                            *)
(* The tokens "ft_probe" and "wnear_probe" are the library's standard FT  *)
(* and wNEAR.  Token batches use the library's per-call accounting.       *)
(* Every receipt's burn key and size, and every child's exec fee, come    *)
(* from the calibration (CalibProbes.tla).                                *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS FirstRcpt,   \* the flow's transaction (its first receipt, gas set per run)
          Signer0,     \* its signer
          Grid,        \* prepaid values (Ggas)
          After        \* steps after it: [k |-> "tx" | "expire", to, m, a, fr, g]

VARIABLES pp, sent, ai   \* ai: After steps done
confVars == <<pp, sent, ai>>
vars == <<platformVars, tk, confVars>>

ProbeAccts == {"p", "q"}
Toks == {"ft_probe", "wnear_probe"}
Accts == {"alice", "dave", "p", "q", "y", "nobody", "nimp", "nimp_new", "eth", "eth_new"} \cup Toks
Missing == {"nobody", "nimp_new", "eth_new"}
ConfExists == Accts \ Missing
ConfKinds == AcctKinds({"eth", "eth_new"}, {"nimp", "nimp_new"})
ConfFloor == [a \in Accts |-> 0]
Holders == {"alice", "dave", "p", "q"}
ConfHolders == [t \in Toks |-> Holders]
ConfStorageMin == [t \in Toks |-> 1]
ConfDev == [t \in Toks |-> {}]
ConfReserve == [t \in Toks |-> 0]

\* Accounts with code (calls to any other account fail).
ConfContracts == {"p", "q", "y"} \cup Toks


\* Model units: 1 NEAR = 1000; the storage minimum is 1; 1 yocto is 1.
\* As after the spec's setup: alice minted 1000000 FT and sent p 100000;
\* alice deposited 10 NEAR of wNEAR, p 1 NEAR.
Bal0(t) == [h \in Holders |-> CASE h = "alice" -> (IF t = "ft_probe" THEN 900000 ELSE 10000)
                               [] h = "p"     -> (IF t = "ft_probe" THEN 100000 ELSE 1000)
                               [] OTHER       -> 0]
Reg0(t) == {"alice", "q", "p"}

----------------------------------------------------------------------------
(* Probe payloads (TokenCommon's cx slot): one record shape for all.       *)
\* A call a chain or batch makes: receiver, method, args, static, weight, deposit.
KidRec(to, m, a, st, wt, dep) == [to |-> to, m |-> m, a |-> a, st |-> st, wt |-> wt, dep |-> dep]
PA0 == [kids |-> <<>>, cb |-> <<>>, n |-> 0, to |-> "", amt |-> 0, gk |-> "", fee |-> 0, bargs |-> TA0,
        det |-> FALSE, st |-> 0, wt |-> 0, rb |-> -1]
PA(f) == CxArgs(f)
Px(r) == r.a.cx[1]

Sum1(s) == LET F[i \in 0..Len(s)] == IF i = 0 THEN 0 ELSE F[i - 1] + s[i].dep IN F[Len(s)]

\* chain: kids get ids nid .. nid+n-1, the callback nid+n.  Several kids,
\* not detached, with a callback: promise_and(kids).then(cb) (AndThen), the
\* data ids nid+n+1 .. nid+2n.  Detached: cb waits on the last kid.
HChain(r) ==
    LET x == Px(r)  n == Len(x.kids)  hasCb == x.cb # <<>>
        joint == n > 1 /\ ~x.det /\ hasCb
        cbId == nid + n
        Kid(i) == LET k == x.kids[i] IN
                  WithCall(Rcpt(nid + i - 1, r.tx, k.to, r.to, k.m, k.a, k.dep, r.to,
                                IF i = n /\ hasCb THEN cbId ELSE 0), <<k.st>>, <<k.wt>>)
        Cb == LET c == x.cb[1] IN
              WithCall(Rcpt(cbId, r.tx, c.to, r.to, c.m, c.a, 0, r.to, 0), <<c.st>>, <<c.wt>>)
        J == AndThen([i \in 1..n |-> Kid(i)], Cb, nid + n + 1)
    IN OKey(Outcome(IF joint THEN {J.kids[i] : i \in 1..n} ELSE {Kid(i) : i \in 1..n},
                    IF ~hasCb THEN {} ELSE IF joint THEN {J.cb} ELSE {Cb}, RVal(EMPTY),
                    Sum1(x.kids), n + (IF hasCb THEN 1 ELSE 0) + (IF joint THEN n ELSE 0)),
            r.to \o "." \o x.gk)

HSend(r) ==
    LET x == Px(r)  hasCb == x.cb # <<>>
        t == Rcpt(nid, r.tx, x.to, r.to, XFER, TA0, x.amt, r.to, IF hasCb THEN nid + 1 ELSE 0)
        Cb == LET c == x.cb[1] IN
              WithCall(Rcpt(nid + 1, r.tx, r.to, r.to, c.m, c.a, 0, r.to, 0), <<c.st>>, <<c.wt>>)
    IN OKey(Outcome({t}, IF hasCb THEN {Cb} ELSE {}, RVal(EMPTY), x.amt, IF hasCb THEN 2 ELSE 1),
            r.to \o "." \o x.gk)

HBatch(r) ==
    LET x == Px(r)
        b == WithFee(WithCall(Rcpt(nid, r.tx, x.to, r.to, "batch", x.bargs, Sum1(x.kids), r.to, 0),
                              [i \in 1..Len(x.kids) |-> x.kids[i].st],
                              [i \in 1..Len(x.kids) |-> x.kids[i].wt]), x.fee)
    IN OKey(Outcome({b}, {}, RVal(EMPTY), Sum1(x.kids), 1), r.to \o "." \o x.gk)

\* NEP-141 receiver, by msg.
HOnTransfer(r) ==
    LET msg == r.a.msg  amt == r.a.amt
        O == CASE msg = "keep"      -> Outcome({}, {}, RVal(0), 0, 0)
               [] msg = "return"    -> Outcome({}, {}, RVal(amt), 0, 0)
               [] msg = "over"      -> Outcome({}, {}, RVal(amt + 1), 0, 0)
               [] msg = "burn20000" -> Outcome({}, {}, RVal(0), 0, 0)
               [] msg = "big2000"   -> Outcome({}, {}, RValSz(NONEMPTY, 2), 0, 0)
               [] OTHER             -> OErr(Outcome({}, {}, RVal(0), 0, 0), "receiver panicked")
        k == r.to \o ".ft_on_transfer/" \o msg
    \* a panic's key is its burn up to the panic (out of gas before it: "oog")
    IN IF O.err # "" THEN OPanicKey(O, k) ELSE OKey(O, k)

LeafKey(r) == r.to \o "." \o (IF Px(r).gk = "" THEN r.m ELSE Px(r).gk)
Leaf(r, ret, sz) == OSz(OKey(Outcome({}, {}, ret, 0, 0), LeafKey(r)), sz)

\* on_read's size: every result read in full (failed ones count 0), KB.
ReadSz(r) == LET F[i \in 0..NRes(r)] == IF i = 0 THEN 0
                                        ELSE F[i - 1] + (IF ResAt(r, i).ok THEN ResAt(r, i).sz ELSE 0)
             IN F[NRes(r)]

\* The async probe.  A payload of b bytes is not a JSON number: NONEMPTY, b \div 1000 KB.
HYield(r) ==
    LET x == Px(r)
        Y == WithCall(YieldRcpt(nid, r, "on_yield", PA(PA0), 0, 0), <<x.st>>, <<x.wt>>)
        O == Outcome({}, {Y}, RVal(EMPTY), 0, 1)
    IN OKey(IF x.rb >= 0 THEN OResume(O, nid, NONEMPTY, x.rb \div 1000) ELSE O, r.to \o "." \o x.gk)

HResume(r) ==
    LET ys == PendingYieldsAt(r, {})  O == Outcome({}, {}, RVal(0), 0, 0) IN
    IF ys = {} THEN OKey(O, r.to \o ".resume/none")
    ELSE OKey(OResume([O EXCEPT !.ret = RVal(1)], CHOOSE y \in ys : TRUE, NONEMPTY, Px(r).n \div 1000),
              r.to \o ".resume/ok")

HOnYield(r) ==
    OKey(Outcome({}, {}, RVal(0), 0, 0), r.to \o ".on_yield/" \o (IF r.res.ok THEN "payload" ELSE "timeout"))

HOnOrder(r) ==
    IF NRes(r) >= 1 /\ ~ResAt(r, 1).ok
    THEN OErr(Leaf(r, RVal(0), 0), "first result failed")
    ELSE Leaf(r, RVal(NRes(r)), 0)

PH(r) ==
    CASE r.m = "chain"          -> HChain(r)
      [] r.m = "send"           -> HSend(r)
      [] r.m = "batch"          -> HBatch(r)
      [] r.m = "ft_on_transfer" -> HOnTransfer(r)
      [] r.m = "burn"           -> Leaf(r, RVal(EMPTY), Px(r).n)
      [] r.m = "ret"            -> Leaf(r, RValSz(NONEMPTY, Px(r).n), Px(r).n)
      [] r.m = "on_read"        -> Leaf(r, RVal(0), ReadSz(r))
      [] r.m = "on_count"       -> Leaf(r, RVal(1), 0)
      [] r.m = "fail"           -> OErr(Outcome({}, {}, RVal(0), 0, 0), "probe fail")
      [] r.m = "yield_create"   -> HYield(r)
      [] r.m = "resume"         -> HResume(r)
      [] r.m = "on_yield"       -> HOnYield(r)
      [] r.m = "on_order"       -> HOnOrder(r)
      [] OTHER                  -> OErr(Outcome({}, {}, RVal(0), 0, 0), "method not found")

----------------------------------------------------------------------------
Start ==
    /\ ~sent
    /\ SubmitAs(WithGas(FirstRcpt, pp), Signer0, DefaultKey)
    /\ sent' = TRUE
    /\ UNCHANGED <<tk, pp, ai>>

\* Nothing can run: the parked yield (no resume in flight, not timed out)
\* is all that may be left.
Quiet == Runnable = {}

\* The transaction id of After step i: 1 + the transactions among steps
\* 1..i (an expire step sends none).  NTx: the flow's transactions.
TxOf(i) == 1 + Cardinality({j \in 1..i : After[j].k = "tx"})
NTx == TxOf(Len(After))

\* The next After step, once nothing can run: transaction 2, 3, ... at its
\* own gas, or one block (the parked yield's timeout, YieldTicks = 1).
AfterStep ==
    /\ sent /\ ai < Len(After) /\ Quiet
    /\ LET s == After[ai + 1] IN
       IF s.k = "expire" THEN BlockTick
       ELSE SubmitAs(WithGas(Rcpt(nid, TxOf(ai + 1), s.to, s.fr, s.m, s.a, 0, s.fr, 0), s.g), s.fr, DefaultKey)
    /\ ai' = ai + 1
    /\ UNCHANGED <<tk, pp, sent>>

Run ==
    \E r \in Runnable :
       /\ IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED tk
          ELSE IF IsTokRcpt(r) THEN \E ch \in TokChoices(r) : TokStep(r, TokHandle(r, ch))
          ELSE Exec(r, PH(r)) /\ UNCHANGED tk
       /\ UNCHANGED confVars

Init ==
    /\ PlatformInit([a \in Accts |-> 1000000], 1..NTx)
    /\ tk = [t \in Toks |-> Ledger(Bal0(t), Reg0(t))]
    /\ pp \in Grid
    /\ sent = FALSE
    /\ ai = 0

Next == Start \/ Run \/ AfterStep
Spec == Init /\ [][Next]_vars

\* Every step done and nothing left but parked yields.  Report prints how
\* many (the sim's sweep records Sim::yields() at the same moment), so a
\* stale yield left in post does not pass as clean-up.
Done == sent /\ ai = Len(After) /\ Quiet /\ data = {} /\ \A p \in post : IsYield(p)
Parked == Cardinality({p \in post : IsYield(p)})
Report == Done => PrintT(<<"CONF", pp, Parked, rlog>>)
TypeOK == TokSupplyOK
=============================================================================
