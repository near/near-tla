------------------------------ MODULE ProbeConf ------------------------------
(***************************************************************************)
(* Conformance driver for the probe flows (conformance/flows/probes.toml). *)
(* One flow per run: the world of the flow spec is the initial state, and *)
(* the flow's transaction is submitted once at every prepaid value of     *)
(* Grid (Ggas).  Report prints the per-receipt outcome log of that        *)
(* transaction in every terminal state (PrintT is TRUE, so TLC never      *)
(* stops); scripts/conform.py compares it with the sim's sweep.           *)
(*                                                                         *)
(* The probe contract (conformance/probes/probe), on accounts "p" and "q": *)
(*   chain   creates kids (each its own function call with the static gas *)
(*           and weight in the payload); with several kids all but the    *)
(*           last are detached; cb (if any) waits on the last kid         *)
(*   burn    burns n Ggas                       (key "<acct>.burn", sz n) *)
(*   ret     returns n KB                       (key "<acct>.ret", sz n)  *)
(*   on_read reads every result in full         (sz = result size, KB)    *)
(*   on_count only counts its results                                     *)
(*   send    a Transfer of amt to `to`, optionally then on_read           *)
(*   batch   one receipt holding the given function calls (a token batch) *)
(*   ft_on_transfer  NEP-141 receiver; msg keep / return / over / panic / *)
(*           burn20000 (burns 20 Tgas, keeps) / big2000 (2 KB, not a      *)
(*           number)                                                      *)
(* The tokens "ft" and "wrap" are the library's standard FT and wNEAR.     *)
(* Every receipt's burn key and size, and every child's exec fee, come    *)
(* from the calibration (CalibProbes.tla).                                *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS FirstRcpt,   \* the flow's transaction (its first receipt, gas set per run)
          Signer0,     \* its signer
          Grid         \* prepaid values (Ggas)

VARIABLES pp, sent
confVars == <<pp, sent>>
vars == <<platformVars, tk, confVars>>

ProbeAccts == {"p", "q"}
Accts == {"alice", "dave", "p", "q", "ft", "wrap", "nobody", "nimp", "nimp_new", "eth", "eth_new"}
Missing == {"nobody", "nimp_new", "eth_new"}
ConfExists == Accts \ Missing
ConfKinds == AcctKinds({"eth", "eth_new"}, {"nimp", "nimp_new"})
ConfFloor == [a \in Accts |-> 0]
Holders == {"alice", "dave", "p", "q"}
ConfHolders == [t \in {"ft", "wrap"} |-> Holders]
ConfStorageMin == [t \in {"ft", "wrap"} |-> 1]
ConfDev == [t \in {"ft", "wrap"} |-> {}]
ConfReserve == [t \in {"ft", "wrap"} |-> 0]

\* Accounts with code (calls to any other account fail).
ConfContracts == {"p", "q", "ft", "wrap"}

\* Per-call burns of a token batch (cfg: BatchPA <- ConfBatchPA, with
\* TokBatchPerAction <- TRUE): the key "<acct>.batch/<shape>#<method>", the
\* burn of that call at its place in the batch (CalibProbes, --batch-actions);
\* the library's BatchPA keys each call by its standalone method.
ConfBatchPA(r, a, n0, n1, n2, n3) ==
    LET Act(m, lo, hi) == <<[gk |-> CallKey(r.to, BatchKey(a) \o "#" \o m), sz |-> 0, kids |-> lo..(hi - 1)]>> IN
    (IF a.nd > 0 THEN Act("near_deposit", n0, n1) ELSE <<>>)
    \o (IF a.sd > 0 THEN Act("storage_deposit", n1, n2) ELSE <<>>)
    \o (IF a.xf # "" THEN Act(a.xf, n2, n3) ELSE <<>>)
ConfTrue == TRUE

\* Model units: 1 NEAR = 1000; the storage minimum is 1; 1 yocto is 1.
\* As after the spec's setup: alice minted 1000000 FT and sent p 100000;
\* alice deposited 10 NEAR of wNEAR, p 1 NEAR.
Bal0(t) == [h \in Holders |-> CASE h = "alice" -> (IF t = "ft" THEN 900000 ELSE 10000)
                               [] h = "p"     -> (IF t = "ft" THEN 100000 ELSE 1000)
                               [] OTHER       -> 0]
Reg0(t) == IF t = "ft" THEN {"alice", "q", "p"} ELSE {"alice", "q", "p"}

----------------------------------------------------------------------------
(* Probe payloads (TokenCommon's cx slot): one record shape for all.       *)
\* A call a chain or batch makes: receiver, method, args, static, weight, deposit.
KidRec(to, m, a, st, wt, dep) == [to |-> to, m |-> m, a |-> a, st |-> st, wt |-> wt, dep |-> dep]
PA0 == [kids |-> <<>>, cb |-> <<>>, n |-> 0, to |-> "", amt |-> 0, gk |-> "", fee |-> 0, bargs |-> TA0]
PA(f) == CxArgs(f)
Px(r) == r.a.cx[1]

Sum1(s) == LET F[i \in 0..Len(s)] == IF i = 0 THEN 0 ELSE F[i - 1] + s[i].dep IN F[Len(s)]

\* chain: kids get ids nid .. nid+n-1, the callback nid+n.
HChain(r) ==
    LET x == Px(r)  n == Len(x.kids)  hasCb == x.cb # <<>>
        cbId == nid + n
        Kid(i) == LET k == x.kids[i] IN
                  WithCall(Rcpt(nid + i - 1, r.tx, k.to, r.to, k.m, k.a, k.dep, r.to,
                                IF i = n /\ hasCb THEN cbId ELSE 0), <<k.st>>, <<k.wt>>)
        Cb == LET c == x.cb[1] IN
              WithCall(Rcpt(cbId, r.tx, r.to, r.to, c.m, c.a, 0, r.to, 0), <<c.st>>, <<c.wt>>)
    IN OKey(Outcome({Kid(i) : i \in 1..n}, IF hasCb THEN {Cb} ELSE {}, RVal(EMPTY),
                    Sum1(x.kids), n + (IF hasCb THEN 1 ELSE 0)),
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
    IN OKey(O, r.to \o ".ft_on_transfer/" \o msg)

Leaf(r, ret, sz) == OSz(OKey(Outcome({}, {}, ret, 0, 0), r.to \o "." \o r.m), sz)

PH(r) ==
    CASE r.m = "chain"          -> HChain(r)
      [] r.m = "send"           -> HSend(r)
      [] r.m = "batch"          -> HBatch(r)
      [] r.m = "ft_on_transfer" -> HOnTransfer(r)
      [] r.m = "burn"           -> Leaf(r, RVal(EMPTY), Px(r).n)
      [] r.m = "ret"            -> Leaf(r, RValSz(NONEMPTY, Px(r).n), Px(r).n)
      [] r.m = "on_read"        -> Leaf(r, RVal(0), IF r.res.ok THEN r.res.sz ELSE 0)
      [] r.m = "on_count"       -> Leaf(r, RVal(1), 0)
      [] OTHER                  -> OErr(Outcome({}, {}, RVal(0), 0, 0), "method not found")

----------------------------------------------------------------------------
Start ==
    /\ ~sent
    /\ SubmitAs(WithGas(FirstRcpt, pp), Signer0, DefaultKey)
    /\ sent' = TRUE
    /\ UNCHANGED <<tk, pp>>

Run ==
    \E r \in Runnable :
       /\ IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED tk
          ELSE IF IsTokRcpt(r) THEN \E ch \in TokChoices(r) : TokStep(r, TokHandle(r, ch))
          ELSE Exec(r, PH(r)) /\ UNCHANGED tk
       /\ UNCHANGED confVars

Init ==
    /\ PlatformInit([a \in Accts |-> 1000000], {1})
    /\ tk = [t \in {"ft", "wrap"} |-> Ledger(Bal0(t), Reg0(t))]
    /\ pp \in Grid
    /\ sent = FALSE

Next == Start \/ Run
Spec == Init /\ [][Next]_vars

Done == sent /\ Idle
Report == Done => PrintT(<<"CONF", pp, {x \in rlog : x.tx = 1}>>)
TypeOK == TokSupplyOK
=============================================================================
