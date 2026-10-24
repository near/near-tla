------------------------------ MODULE SelfTest ------------------------------
(***************************************************************************)
(* Library self-test: small deterministic scenarios, each a fixed script   *)
(* of transactions run one after another (the next is submitted once the   *)
(* previous one has settled).  Expect(s) is the end state nearcore         *)
(* produces for scenario s; Check holds once the script is done.  The      *)
(* runs set deadlock = true and stutter only when a script is done, so a   *)
(* receipt left stuck is reported as a deadlock.                           *)
(*                                                                         *)
(* Accounts: users u, w; contracts c, d (d is also the token receiver);    *)
(* c must keep 2 NEAR for storage, v 8 (liquid + locked);                  *)
(* v the staking account (a contract); nc exists without code; ft a        *)
(* standard FT + wNEAR; ghost, ghost2 (named) and 0xe, 0xf (eth-implicit)  *)
(* do not exist; neither does the universal account 0u1.  The rule each    *)
(* scenario checks is in docs/SEMANTICS.md with its nearcore citation      *)
(* (b7b4737); the comments in Expect name the source file.                 *)
(***************************************************************************)
EXTENDS Tokens, NearKeys

CONSTANT Scns       \* the scenarios explored by this run

VARIABLES scn, ntx, acc, ran, seen
mine == <<scn, ntx, acc, ran, seen>>
vars == <<platformVars, tk, keyVars, mine>>

U == "u"  W == "w"  C == "c"  D == "d"  NC == "nc"  V == "v"  FT == "ft"
GH == "ghost"  GH2 == "ghost2"  E1 == "0xe"  E2 == "0xf"  UA == "0u1"
Accts    == {U, W, C, D, NC, V, FT, GH, GH2, E1, E2, UA}
SExists  == Accts \ {GH, GH2, E1, E2, UA}
SCode    == {C, D, V, FT, UA}    \* UA: listed, but a universal account created by a Transfer has no code
SKinds   == [a \in Accts |-> CASE a \in {E1, E2} -> "eth_implicit"
                              [] a = UA -> "universal"
                              [] OTHER -> "named"]
SFloor   == [a \in Accts |-> CASE a = V -> 8 [] a = C -> 2 [] OTHER -> 0]
TxIds    == 1..10
NoTable  == [x \in {} |-> 0]

\* Tokens: ft is a standard FT and wNEAR; storage min 2; w is not registered.
STokHolders == [t \in {FT} |-> {U, W, C, D}]
STokMin     == [t \in {FT} |-> 2]
STokDev     == [t \in {FT} |-> {}]
STokReserve == [t \in {FT} |-> 10000]
ReserveShapes == [t \in {FT} |-> "reserve"]
Tok0 == [t \in {FT} |-> Ledger([h \in {U, W, C, D} |-> CASE h = U -> 5 [] h = C -> 3 [] OTHER -> 0],
                               {U, C, D})]

\* Keys: c has k0 (full), k1 (c, {ping}), k2 (c, any method); d has k0.
SKeyAccts == {C, D}
PermOf(k) == CASE k = "k0" -> FullPerm
               [] k = "k2" -> Perm(C, {}, FALSE)
               [] OTHER    -> Perm(C, {"ping"}, FALSE)
Keys0 == [a \in {C, D} |-> IF a = C THEN [k \in {"k0", "k1", "k2"} |-> PermOf(k)]
                                    ELSE ("k0" :> FullPerm)]

\* Gas tables (Ggas).
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
GB(b) == [base |-> b, per |-> 0]
SGasCall == ("work" :> GC(<<0>>, <<1>>, 0)) @@ ("ft_on_transfer" :> GC(<<>>, <<>>, 100))
SGasCallRes == ("ft.ft_resolve_transfer" :> GC(<<5000>>, <<0>>, 100)) @@ SGasCall
SGasBurn ==
       ("spawn0" :> GB(500)) @@ ("work" :> GB(300)) @@ ("boom" :> GB(100)) @@ ("c.boom" :> GB(5000))
    @@ ("mk" :> GB(500)) @@ ("multi" :> GB(3500))
    @@ ("c.multi/1" :> GB(1000)) @@ ("c.multi/2" :> GB(2500)) @@ ("c.multi/2big" :> GB(3500))
    @@ ("ft.ft_transfer_call" :> GB(1000)) @@ ("ft.ft_resolve_transfer" :> GB(800))
    @@ ("ft_on_transfer" :> GB(200)) @@ ("ft.ft_transfer" :> GB(2500)) @@ ("spend" :> GB(1000))
    @@ ("ft.batch/DC#near_deposit" :> GB(500)) @@ ("ft.batch/DC#ft_transfer_call" :> GB(1000))
    @@ ("ft.batch/DC" :> GB(1500)) @@ ("spawnx" :> GB(500)) @@ ("cb" :> GB(0)) @@ ("probe" :> GB(0))
    @@ ("c.boomk" :> GB(1000)) @@ ("c.multi/p" :> GB(2000)) @@ ("c.multi/pbig" :> GB(3500))
    @@ ("c.multi/phuge" :> GB(4500)) @@ ("c.multi2/1" :> GB(1000)) @@ ("c.multi2/2" :> GB(1000))
\* Path-specific burn keys (falling back to the method key when absent).
SGasPath ==
       ("ft.storage_deposit/new" :> GB(3000)) @@ ("ft.storage_deposit" :> GB(500))
    @@ ("ft.near_deposit/registered" :> GB(3000)) @@ ("ft.near_deposit" :> GB(500))
    @@ ("ft.ft_resolve_transfer/refund" :> GB(6000)) @@ SGasBurn

----------------------------------------------------------------------------
(* Contract code of c, d, v (one handler for all three).                   *)
\* Arguments of the contract's own receipts (in TA0's cx slot).
G(k, w, to, amt, cd, rto, key) ==
    CxArgs([k |-> k, w |-> w, to |-> to, amt |-> amt, cd |-> cd, rto |-> rto, key |-> key])
G0 == G("", "", "", 0, 0, "", "")
Ar(r) == r.a.cx[1]

Sn(r, tag, n) == [tx |-> r.tx, tag |-> tag, n |-> n]
ResTag(res) == IF ~res.ok THEN "fail"
               ELSE CASE res.v = NOPR -> "nopr" [] res.v = EMPTY -> "empty"
                      [] res.v = MAL -> "mal" [] res.v = NONEMPTY -> "bytes" [] OTHER -> "num"
SeenRes(r) == {Sn(r, ResTag(r.res), NumOr(r.res, 0)), Sn(r, "sz", r.res.sz)}
Out0 == Outcome({}, {}, RVal(0), 0, 0)
CbOf(r, id) == Rcpt(id, r.tx, r.to, r.to, "cb", G0, 0, r.to, r.cb)
H(r) ==
  LET a == Ar(r) IN
  CASE r.m = "spawn" ->     \* d.work(a.w) with deposit a.cd and refund_to a.rto, then self.cb
         LET ch == Rcpt(nid, r.tx, D, r.to, "work", G("", a.w, "", 0, 0, "", ""), a.cd,
                        IF a.rto = "" THEN r.to ELSE a.rto, nid + 1)
             O  == Outcome({ch}, {CbOf(r, nid + 1)}, RVal(0), a.cd, 2) IN
         [O |-> IF a.k = "fail" THEN OErr(O, "spawn panics") ELSE O, s |-> {}]
    [] r.m = "spawn3" ->    \* d.work, then self.cbf (panics), then self.cb waiting on cbf
         [O |-> Outcome({Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, nid + 1)},
                        {Rcpt(nid + 1, r.tx, r.to, r.to, "cbf", G0, 0, r.to, nid + 2), CbOf(r, nid + 2)},
                        RVal(0), 0, 3), s |-> {}]
    [] r.m = "cbf" -> [O |-> OErr(Out0, "cbf panics"), s |-> {}]
    [] r.m = "spawn0" ->    \* a function call left with no gas (static 0, weight 0); a.k = "cb":
                            \* d.work takes the whole leftover and the callback gets nothing
         IF a.k = "cb"
         THEN [O |-> Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, nid + 1), <<0>>, <<1>>)},
                             {WithCall(CbOf(r, nid + 1), <<0>>, <<0>>)}, RVal(0), 0, 2), s |-> {}]
         ELSE [O |-> Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>, <<0>>)},
                             {}, RVal(0), 0, 1), s |-> {}]
    [] r.m = "work" ->
         [O |-> (CASE a.w = "fail" -> OErr(Out0, "work panics")
                   [] a.w = "zero" -> Out0
                   [] a.w = "sz"   -> Outcome({}, {}, RValSz(1, 3), 0, 0)
                   [] OTHER        -> Outcome({}, {}, RVal(1), 0, 0)),
          s |-> {Sn(r, "work", GasOf(r))}]
    [] r.m \in {"cb", "probe"} -> [O |-> Out0, s |-> SeenRes(r)]
    [] r.m = "send" ->      \* Transfer a.amt to a.to, then self.cb
         [O |-> Outcome({Rcpt(nid, r.tx, a.to, r.to, XFER, G0, a.amt, r.to, nid + 1)},
                        {CbOf(r, nid + 1)}, RVal(0), a.amt, 2), s |-> {}]
    [] r.m = "spend" ->     \* Transfer a.amt to u
         [O |-> Outcome({Rcpt(nid, r.tx, U, r.to, XFER, G0, a.amt, r.to, 0)}, {}, RVal(0), a.amt, 1),
          s |-> {}]
    [] r.m = "dostake" ->   \* Stake(a.amt) on v, then self.cb
         [O |-> Outcome({Rcpt(nid, r.tx, V, r.to, STAKE, [x1 |-> a.amt], 0, r.to, nid + 1)},
                        {CbOf(r, nid + 1)}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "keyact" ->    \* AddKey / DeleteKey(a.key) on account a.to, then self.cb
         [O |-> Outcome({Rcpt(nid, r.tx, a.to, r.to, IF a.k = "add" THEN ADDK ELSE DELK,
                              G("", "", "", 0, 0, "", a.key), 0, r.to, nid + 1)},
                        {CbOf(r, nid + 1)}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "mk" ->        \* self.multi with two function-call actions: 3 + 3 Tgas;
                            \* 3 + 4 Tgas for the panics "p*"; self.multi2 with 3 + 5 Tgas for "two"
         LET g == CASE a.k = "two" -> <<3000, 5000>> [] a.k \in {"p1", "p2", "p2ok", "p2pre"} -> <<3000, 4000>>
                      [] OTHER -> <<3000, 3000>> IN
         [O |-> Outcome({WithCall(Rcpt(nid, r.tx, r.to, r.to, IF a.k = "two" THEN "multi2" ELSE "multi",
                                       G(a.k, "", "", 0, 0, "", ""), 0, r.to, 0), g, <<0, 0>>)},
                        {}, RVal(0), 0, 1),
          s |-> {}]
    [] r.m = "multi" ->     \* action 1 creates d.work (weight 1); action 2 creates nothing;
                            \* "p1" / "p2" / "p2ok" / "p2pre": a panic in action 1 / 2 / 2 / 2
                            \* (OPanicAt); "nopa": no pa; "pa1": pa for one action only
         LET pa == <<[gk |-> IF a.k = "p2pre" THEN "c.multi/2big" ELSE "c.multi/1", sz |-> 0, kids |-> {nid}],
                     [gk |-> IF a.k \in {"big", "p1"} THEN "c.multi/2big" ELSE "c.multi/2", sz |-> 0, kids |-> {}]>>
             O0 == Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>, <<1>>)},
                           {}, RVal(0), 0, 1)
             O  == CASE a.k = "nopa" -> O0 [] a.k = "pa1" -> [pa |-> SubSeq(pa, 1, 1)] @@ O0
                     [] OTHER -> [pa |-> pa] @@ O0
         IN [O |-> CASE a.k = "p1"    -> OPanicAt(OErr(O, "boom"), 1, "c.multi/pbig")
                     [] a.k = "p2"    -> OPanicAt(OErr(O, "boom"), 2, "c.multi/phuge")
                     [] a.k = "p2ok"  -> OPanicAt(OErr(O, "boom"), 2, "c.multi/pbig")
                     [] a.k = "p2pre" -> OPanicAt(OErr(O, "boom"), 2, "c.multi/p")
                     [] OTHER        -> O,
             s |-> {}]
    [] r.m = "multi2" ->    \* each action creates d.work (weight 1)
         LET Wk(id) == WithCall(Rcpt(id, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>, <<1>>)
             pa == <<[gk |-> "c.multi2/1", sz |-> 0, kids |-> {nid}],
                     [gk |-> "c.multi2/2", sz |-> 0, kids |-> {nid + 1}]>>
         IN [O |-> [pa |-> pa] @@ Outcome({Wk(nid), Wk(nid + 1)}, {}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "spawnx" ->    \* a function call with no GasCall entry and no WithCall
         [O |-> Outcome({Rcpt(nid, r.tx, D, r.to, "probe", G0, 0, r.to, 0)}, {}, RVal(0), 0, 1), s |-> {}]
    [] r.m = "boom" -> [O |-> OPanicKey(OErr(Out0, "boom"), CallKey(r.to, "boom")), s |-> {}]
    [] r.m = "boomk" ->     \* creates d.work (static 2 Tgas), then panics
         [O |-> OPanicKey(OErr(Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<2000>>, <<0>>)},
                                       {}, RVal(0), 0, 1), "boomk"), CallKey(r.to, "boomk")),
          s |-> {}]
    [] r.m = "bal" ->       \* ft.ft_balance_of(u), then self.cb
         [O |-> Outcome({Rcpt(nid, r.tx, FT, r.to, "ft_balance_of", FtArgs(U, 0, ""), 0, r.to, nid + 1)},
                        {CbOf(r, nid + 1)}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "unreg" ->     \* return ft.storage_unregister(force = true), 1 yocto attached
         [O |-> Outcome({Rcpt(nid, r.tx, FT, r.to, "storage_unregister", SuArgs(TRUE), TokYocto,
                              r.to, r.cb)}, {}, RProm, TokYocto, 1), s |-> {}]
    [] r.m = "ft_on_transfer" ->   \* msg "keep": keep everything; "chain": return c.unreg()
         IF r.a.msg = "chain"
         THEN [O |-> Outcome({Rcpt(nid, r.tx, C, r.to, "unreg", TA0, 0, r.to, r.cb)}, {}, RProm, 0, 1),
               s |-> {}]
         ELSE [O |-> Out0, s |-> {Sn(r, "onT", GasOf(r))}]
    [] OTHER -> [O |-> Out0, s |-> {}]

RunC(r) ==
    LET h == H(r)  O == h.O IN
    /\ Exec(r, O)
    /\ ran'  = IF Ok(r, O) THEN ran \cup {<<r.tx, r.to, r.m>>} ELSE ran
    /\ seen' = IF Ok(r, O) THEN seen \cup h.s ELSE seen
    /\ UNCHANGED <<tk, keyVars, scn, ntx, acc>>

\* kbundle: [AddKey(a.key), FunctionCall] in one receipt on c (atomic).
RunBundle(r) ==
    LET acts == <<AddKeyAct(Ar(r).key, PermOf(Ar(r).key))>> IN
    /\ ExecWithKeys(r, acts, Out0)
    /\ ran' = IF OkWithKeys(r, acts, Out0) THEN ran \cup {<<r.tx, r.to, r.m>>} ELSE ran
    /\ UNCHANGED <<tk, scn, ntx, acc, seen>>

RunTok(r) == \E ch \in TokChoices(r) : TokStep(r, TokHandle(r, ch)) /\ UNCHANGED <<keyVars, mine>>
RunKey(r) == ExecKeyAct(r, Ar(r).key, PermOf(Ar(r).key)) /\ UNCHANGED <<tk, mine>>

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<tk, keyVars, mine>>
         ELSE IF IsKeyRcpt(r) THEN RunKey(r)
         ELSE IF IsTokRcpt(r) THEN RunTok(r)
         ELSE IF r.m = "kbundle" THEN RunBundle(r)
         ELSE RunC(r)

----------------------------------------------------------------------------
(* Scripts.  A transaction: receiver, signer, method, args, deposit,       *)
(* prepaid gas, key ("" = unsigned Submit), static list (multi-call).      *)
T(to, fr, m, a, dep, gas, key, gs) ==
    [to |-> to, fr |-> fr, m |-> m, a |-> a, dep |-> dep, gas |-> gas, key |-> key, gs |-> gs]
Tx(to, fr, m, a, dep)       == T(to, fr, m, a, dep, 0, "", <<>>)
TxG(to, fr, m, a, dep, gas) == T(to, fr, m, a, dep, gas, "", <<>>)
TxK(to, fr, m, dep, key)    == T(to, fr, m, G0, dep, 0, key, <<>>)
Tick == Tx(V, V, "tick", G0, 0)   \* an epoch transition (EpochTick), not a transaction
Amt(n) == G("", "", "", n, 0, "", "")

Script(s) ==
  CASE s = "revert_children"  -> << Tx(C, U, "spawn", G("fail", "ok", "", 0, 0, "", ""), 2) >>
    [] s = "waiter_failed"    -> << Tx(C, U, "spawn", G("ok", "fail", "", 0, 0, "", ""), 0) >>
    [] s = "cb_chain"         -> << Tx(C, U, "spawn3", G0, 0) >>
    [] s = "refund_to"        -> << Tx(C, U, "spawn", G("ok", "fail", "", 0, 3, W, ""), 0) >>
    [] s = "named_not_created"-> << Tx(C, U, "send", G("", "", GH, 2, 0, "", ""), 0) >>
    [] s = "implicit_created" -> << Tx(C, U, "send", G("", "", E1, 2, 0, "", ""), 0),
                                    Tx(C, U, "spawn", G("ok", "fail", "", 0, 1, E1, ""), 0) >>
    [] s = "universal"        -> << Tx(C, U, "send", G("", "", UA, 2, 0, "", ""), 0),
                                    Tx(UA, U, "foo", G0, 1) >>
    [] s = "refund_burnt"     -> << Tx(C, U, "spawn", G("ok", "fail", "", 0, 2, E2, ""), 0) >>
    [] s = "no_code"          -> << Tx(NC, U, "foo", G0, 1), Tx(GH, U, "foo", G0, 1) >>
    [] s = "nopr_vs_zero"     -> << Tx(C, U, "probe", G0, 0),
                                    Tx(C, U, "spawn", G("ok", "zero", "", 0, 0, "", ""), 0) >>
    [] s = "transfer_empty"   -> << Tx(C, U, "send", G("", "", D, 1, 0, "", ""), 0) >>
    [] s = "result_size"      -> << Tx(C, U, "spawn", G("ok", "sz", "", 0, 0, "", ""), 0) >>
    [] s = "stake_ok"         -> << Tx(V, V, "dostake", Amt(4), 0) >>
    [] s = "stake_actor"      -> << Tx(C, U, "dostake", Amt(4), 0) >>
    [] s = "stake_signer"     -> << Tx(C, V, "dostake", Amt(4), 0), Tx(V, U, "dostake", Amt(4), 0) >>
    [] s = "stake_fails"      -> << Tx(V, V, "dostake", Amt(20), 0), Tx(V, V, "dostake", Amt(1), 0),
                                    Tx(V, V, "dostake", Amt(0), 0) >>
    [] s = "stake_restake"    -> << Tx(V, V, "dostake", Amt(4), 0), Tx(V, V, "dostake", Amt(6), 0),
                                    Tx(V, V, "dostake", Amt(2), 0), Tick >>
    [] s = "floor_locked"     -> << Tx(V, V, "spend", Amt(2), 0), Tx(V, V, "spend", Amt(1), 0),
                                    Tx(C, U, "spend", Amt(4), 0) >>
    [] s = "liquid_negative"  -> << Tx(V, V, "spend", Amt(5), 0), Tx(V, V, "spend", Amt(4), 0) >>
    [] s = "addkey_present"   -> << Tx(C, C, "keyact", G("add", "", C, 0, 0, "", "k1"), 0),
                                    Tx(C, C, "keyact", G("add", "", C, 0, 0, "", "k3"), 0) >>
    [] s = "delkey_absent"    -> << Tx(C, C, "keyact", G("del", "", C, 0, 0, "", "k9"), 0),
                                    Tx(C, C, "keyact", G("del", "", C, 0, 0, "", "k2"), 0) >>
    [] s = "keys_bundled"     -> << Tx(C, C, "kbundle", G("", "", "", 0, 0, "", "k1"), 0),
                                    Tx(C, C, "kbundle", G("", "", "", 0, 0, "", "k5"), 0) >>
    [] s = "key_other_acct"   -> << Tx(C, C, "keyact", G("del", "", D, 0, 0, "", "k0"), 0) >>
    [] s = "fc_keys"          -> << TxK(C, C, "ping", 0, "k1"),       \* ok
                                    TxK(C, C, "ping", 1, "k1"),       \* deposit
                                    TxK(D, C, "ping", 0, "k1"),       \* receiver
                                    TxK(C, C, "pong", 0, "k1"),       \* method
                                    TxK(C, C, "pong", 0, "k2"),       \* ok: empty list = any
                                    TxK(C, C, XFER, 0, "k2"),         \* not a function call
                                    T(C, C, "ping", G0, 0, 0, "k2", <<0, 0>>),  \* two calls
                                    TxK(D, C, "ping", 1, "k0"),       \* full access: ok
                                    TxK(C, C, ADDK, 0, "k2") >>       \* a key action
    [] s = "zero_gas_child"   -> << TxG(C, U, "spawn0", G0, 0, 10000) >>
    [] s = "zero_gas_cb"      -> << TxG(C, U, "spawn0", G("cb", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "zero_gas_split"   -> << TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 6100),
                                    TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 6101) >>
    [] s = "panic_oog"        -> << TxG(C, U, "boom", G0, 0, 3000), TxG(C, U, "boom", G0, 0, 6000),
                                    TxG(C, U, "boom", G0, 0, 5000),
                                    TxG(C, U, "boomk", G0, 0, 2500), TxG(C, U, "boomk", G0, 0, 3000) >>
    [] s = "panic_plain"      -> << TxG(FT, U, "ft_transfer", FtArgs(W, 1, ""), 1, 2000) >>
    [] s = "oog_and_broke"    -> << TxG(C, U, "spend", Amt(6), 0, 500), TxG(C, U, "spend", Amt(6), 0, 2000) >>
    [] s = "per_action"       -> << TxG(C, U, "mk", G0, 0, 10000),
                                    TxG(C, U, "mk", G("big", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "per_action_two"   -> << TxG(C, U, "mk", G("two", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "per_action_panic" -> << TxG(C, U, "mk", G("p1", "", "", 0, 0, "", ""), 0, 10000),
                                    TxG(C, U, "mk", G("p2", "", "", 0, 0, "", ""), 0, 10000),
                                    TxG(C, U, "mk", G("p2ok", "", "", 0, 0, "", ""), 0, 10000),
                                    TxG(C, U, "mk", G("p2pre", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "assert_pool"      -> << TxG(C, U, "mk", G("nopa", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "assert_pa_len"    -> << TxG(C, U, "mk", G("pa1", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "assert_empty_gs"  -> << TxG(C, U, "spawnx", G0, 0, 10000) >>
    [] s = "ft_std_gas"       -> << TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 20000),
                                    TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 9000) >>
    [] s = "ft_reserve_gas"   -> << TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 20000),
                                    TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 9000) >>
    [] s \in {"batch_per_action", "batch_pooled"} -> << T(FT, U, "batch", BatchArgs(2, 0, "", "ft_transfer_call", D, 1, "keep"),
                                      3, 22000, "", <<2000, 20000>>),
                                    T(FT, U, "batch", BatchArgs(2, 0, "", "ft_transfer_call", D, 1, "keep"),
                                      3, 20300, "", <<300, 20000>>),
                                    T(FT, U, "batch", BatchArgs(2, 0, "", "ft_transfer_call", D, 1, "keep"),
                                      2, 22000, "", <<2000, 20000>>) >>   \* wrong deposit: a plain failure
    [] s = "path_keys"        -> << TxG(FT, U, "storage_deposit", SdArgs(W), 3, 2000),
                                    TxG(FT, U, "storage_deposit", SdArgs(U), 1, 2000),
                                    TxG(FT, U, "near_deposit", TA0, 1, 2000),
                                    TxG(FT, W, "near_deposit", TA0, 5, 2000),
                                    TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 20000),
                                    TxG(FT, U, "ft_transfer_call", FtArgs(D, 1, "keep"), 1, 6101) >>
    [] s = "ft_rules"         -> << Tx(FT, U, "ft_transfer", FtArgs(U, 1, ""), 1),
                                    Tx(FT, U, "ft_transfer", FtArgs(W, 1, ""), 1),
                                    Tx(FT, U, "ft_transfer", FtArgs(C, 0, ""), 1),
                                    Tx(FT, U, "ft_transfer", FtArgs(C, 1, ""), 0),
                                    Tx(FT, U, "ft_transfer", FtArgs(C, 1, ""), 1) >>
    [] s = "storage"          -> << Tx(FT, U, "storage_deposit", SdArgs(W), 1),
                                    Tx(FT, U, "storage_deposit", SdArgs(U), 5),
                                    Tx(FT, U, "storage_deposit", SdArgs(W), 3) >>
    [] s = "wnear"            -> << Tx(FT, W, "near_deposit", TA0, 1),
                                    Tx(FT, W, "near_deposit", TA0, 5),
                                    Tx(FT, U, "near_withdraw", NwArgs(2), 1) >>
    [] s = "batch"            -> << Tx(FT, U, "batch", BatchArgs(2, 0, "", "ft_transfer", C, 1, ""), 2),
                                    Tx(FT, U, "batch", BatchArgs(2, 0, "", "ft_transfer", C, 1, ""), 3) >>
    [] s = "views"            -> << Tx(C, U, "bal", G0, 0) >>
    [] s = "resolve_private"  -> << Tx(FT, U, "ft_resolve_transfer", ResArgs(U, C, 1), 0) >>
    [] s = "unregister_force" -> << Tx(FT, U, "storage_unregister", SuArgs(FALSE), 1),
                                    Tx(FT, U, "storage_unregister", SuArgs(TRUE), 1) >>
    [] s = "resolver_burn"    -> << Tx(FT, C, "ft_transfer_call", FtArgs(D, 3, "chain"), 1) >>

Near0(s) == [a \in Accts |-> CASE a \in {U, W, V, FT} ->
                                  (IF s \in {"floor_locked", "liquid_negative"} /\ a = V THEN 4 ELSE 10)
                               [] a = C -> 5
                               [] OTHER -> 0]
Locked0(s) == CASE s = "floor_locked" -> 5 [] s = "liquid_negative" -> 20 [] OTHER -> 0
Total0(s) == LET n == Near0(s) IN
             n[U] + n[W] + n[V] + n[FT] + n[C] + Locked0(s)

MkTx(e, id, t) ==
    LET r0 == Rcpt(id, t, e.to, e.fr, e.m, e.a, e.dep, e.fr, 0)
        r1 == IF e.gs # <<>> THEN WithStatic(r0, e.gs) ELSE r0
    IN IF GasMode # "gas" THEN r1
       ELSE IF Len(e.gs) > 1 THEN [r1 EXCEPT !.g = e.gs]   \* one gas per function-call action
       ELSE WithGas(r1, e.gas)
CanSign(a, k, r) == (a \in KeyAccts) => KeyCanSign(a, k, r)

Send ==
    /\ Idle
    /\ ntx < Len(Script(scn))
    /\ LET e == Script(scn)[ntx + 1]  r == MkTx(e, nid, ntx + 1) IN
       IF e.m = "tick" THEN EpochTick /\ acc' = Append(acc, TRUE) /\ UNCHANGED keyVars
       ELSE IF e.key = "" THEN Submit(r) /\ acc' = Append(acc, TRUE) /\ UNCHANGED keyVars
       ELSE IF CanSign(e.fr, e.key, r) THEN SubmitSigned(r, e.fr, e.key) /\ acc' = Append(acc, TRUE)
       ELSE acc' = Append(acc, FALSE) /\ UNCHANGED <<platformVars, keyVars>>
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<tk, scn, ran, seen>>

Done == ntx = Len(Script(scn)) /\ Idle

Init ==
    /\ scn \in Scns
    /\ PlatformInitStaked(Near0(scn), Locked0(scn), TxIds)
    /\ tk = Tok0
    /\ KeysInit(Keys0)
    /\ ntx = 0 /\ acc = <<>> /\ ran = {} /\ seen = {}

Next == Send \/ Run \/ (Done /\ UNCHANGED vars)
Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Expected end states                                                     *)
L == tk[FT]
S1(tag, n) == [tx |-> 1, tag |-> tag, n |-> n]
S2(tag, n) == [tx |-> 2, tag |-> tag, n |-> n]
S(t, tag, n) == [tx |-> t, tag |-> tag, n |-> n]

Expect(s) ==
  CASE s = "revert_children" ->   \* a failed receipt's children never run; deposit back
         \* lib.rs:1078-1088, :1303
         ran = {} /\ seen = {} /\ near[U] = 10 /\ near[C] = 5
    [] s = "waiter_failed" ->     \* the callback waiting on a failed receipt sees Failed
         \* lib.rs:1172-1176
         ran = {<<1, C, "spawn">>, <<1, C, "cb">>} /\ seen = {S1("fail", 0), S1("sz", 0)}
    [] s = "cb_chain" ->          \* a failed callback also sends Failed downstream
         \* lib.rs:1172-1176
         seen = {S1("work", 0), S1("fail", 0), S1("sz", 0)} /\ <<1, C, "cbf">> \notin ran
    [] s = "refund_to" ->         \* the deposit of a failed receipt goes to refund_to
         \* receipt.rs:428-430
         near[W] = 13 /\ near[C] = 2 /\ near[D] = 0 /\ near[U] = 10
    [] s = "named_not_created" -> \* a Transfer to a missing named account fails, no account
         \* actions.rs:842-850
         GH \notin created /\ near[C] = 5 /\ S1("fail", 0) \in seen
    [] s = "implicit_created" ->  \* ... to a missing eth-implicit account creates it;
         \* a later refund to it is credited (it exists now)
         \* actions.rs:929-946, lib.rs:1046-1054
         created = {E1} /\ near[E1] = 3 /\ near[C] = 2 /\ burnt = 0 /\ S1("empty", 0) \in seen
    [] s = "universal" ->         \* a Transfer creates a universal account; it has no code
         \* actions.rs:880-887, :943-945
         created = {UA} /\ near[UA] = 2 /\ near[U] = 10 /\ <<2, UA, "foo">> \notin ran
    [] s = "refund_burnt" ->      \* a refund never creates an account; it is burnt
         \* lib.rs:1046-1054
         created = {} /\ burnt = 2 /\ near[E2] = 0 /\ near[C] = 3
    [] s = "no_code" ->           \* calls to an account without code / a missing one fail
         \* actions.rs:874-879, function_call.rs:309-312
         ran = {} /\ near[U] = 10 /\ near[NC] = 0
    [] s = "nopr_vs_zero" ->      \* no promise results is not the number 0
         \* host.rs:4583
         seen = {S1("nopr", 0), S1("sz", 0), S2("work", 0), S2("num", 0), S2("sz", 0)}
    [] s = "transfer_empty" ->    \* a Transfer's result is empty bytes
         S1("empty", 0) \in seen /\ near[D] = 1
    [] s = "result_size" ->       \* the result size reaches the callback
         \* lib.rs:1152-1176
         seen = {S1("work", 0), S1("num", 1), S1("sz", 3)}
    [] s = "stake_ok" ->          \* liquid + locked covers the floor; result is empty bytes
         \* verifier.rs:48-79, lib.rs:1172-1176
         locked = 4 /\ proposal = 4 /\ near[V] = 6 /\ S1("empty", 0) \in seen
    [] s = "stake_actor" ->       \* only the account itself may stake
         \* actions.rs:755-801
         locked = 0 /\ near[V] = 10 /\ S1("fail", 0) \in seen
    [] s = "stake_signer" ->      \* the actor is the predecessor, not the signer
         \* actions.rs:755-801
         locked = 4 /\ near[V] = 6 /\ S1("fail", 0) \in seen /\ S2("empty", 0) \in seen
    [] s = "stake_fails" ->       \* more than liquid; below the minimum stake; unstake with nothing staked
         \* actions.rs:58-109
         locked = 0 /\ near[V] = 10 /\ proposal = 0
         /\ S1("fail", 0) \in seen /\ S2("fail", 0) \in seen /\ S(3, "fail", 0) \in seen
    [] s = "stake_restake" ->     \* a re-stake locks only the increment; a lower stake is
         \* released at the epoch change.  actions.rs:58-109, lib.rs:1717-1790
         locked = 2 /\ proposal = 2 /\ epoch = 1 /\ near[V] = 8
         /\ {S1("empty", 0), S2("empty", 0), S(3, "empty", 0)} \subseteq seen
    [] s = "floor_locked" ->      \* storage check uses liquid + locked (locked only for v)
         \* verifier.rs:48-79
         near[V] = 3 /\ near[U] = 11 /\ locked = 5 /\ near[C] = 5
    [] s = "liquid_negative" ->   \* locked covers the storage but not a spend beyond liquid
         \* lib.rs:1008-1023, verifier.rs:48-79
         near[V] = 0 /\ near[U] = 14 /\ locked = 20
    [] s = "addkey_present" ->    \* adding a present key fails
         \* access_keys.rs:158
         DOMAIN keys[C] = {"k0", "k1", "k2", "k3"} /\ S1("fail", 0) \in seen /\ S2("empty", 0) \in seen
    [] s = "delkey_absent" ->     \* deleting an absent key fails
         \* access_keys.rs:84
         DOMAIN keys[C] = {"k0", "k1"} /\ S1("fail", 0) \in seen /\ S2("empty", 0) \in seen
    [] s = "keys_bundled" ->      \* [AddKey(present), call] fails as a whole
         \* lib.rs:946-1005, access_keys.rs:158
         DOMAIN keys[C] = {"k0", "k1", "k2", "k5"} /\ ran = {<<2, C, "kbundle">>}
    [] s = "key_other_acct" ->    \* key actions only on the predecessor's own account
         \* actions.rs:755-801
         DOMAIN keys[D] = {"k0"} /\ S1("fail", 0) \in seen
    [] s = "fc_keys" ->           \* function-call key limits
         \* verifier.rs:209-250
         acc = <<TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, TRUE, FALSE>> /\ near[D] = 1
    [] s = "zero_gas_child" ->    \* a child call with 0 gas fails its creator
         \* action_validation.rs:350-351
         ran = {} /\ oog = {}
    [] s = "zero_gas_cb" ->       \* ... also a callback with 0 gas
         \* action_validation.rs:350-351
         ran = {} /\ oog = {}
    [] s = "zero_gas_split" ->    \* static 0 + weight 1 with leftover 0 is 0 gas: fails the
         \* creator; with 1 Ggas left the child runs and runs out
         \* action_validation.rs:350-351, gas_counter.rs:155-174
         oog = {<<2, "ft_on_transfer">>} /\ seen = {} /\ L.bal[U] = 5 /\ L.bal[D] = 0 /\ near[FT] = 11
    [] s = "panic_oog" ->         \* a panic the gas cannot reach is out of gas; the
         \* children created before it count (limit prepaid - promises gas); exact fit is a panic
         \* gas_counter.rs:136-141, :155-174
         oog = {<<1, "boom">>, <<4, "boomk">>}
    [] s = "panic_plain" ->       \* a panic without a panic-path key is a panic
         oog = {} /\ L.bal[U] = 5 /\ near[U] = 10
    [] s = "oog_and_broke" ->     \* out of gas before the balance check
         \* gas_counter.rs:155-174, lib.rs:1008-1023
         oog = {<<1, "spend">>} /\ near[C] = 5
    [] s = "per_action" ->        \* each action's leftover goes to its own children
         \* function_call.rs:61, :343-345
         S1("work", 2000) \in seen /\ oog = {<<2, "multi">>}
    [] s = "per_action_two" ->    \* two actions, each with a weighted child
         \* function_call.rs:61, :343-345
         seen = {S1("work", 2000), S1("work", 4000)}
    [] s = "per_action_panic" ->  \* a panic in action i: the actions before it, and i up to
         \* the panic, against their own gas.  function_call.rs:61, gas_counter.rs:155-174
         oog = {<<1, "multi">>, <<2, "multi">>, <<4, "multi">>} /\ seen = {}
    [] s \in {"assert_pool", "assert_pa_len", "assert_empty_gs"} -> FALSE   \* never done: an Assert fires
    [] s = "ft_std_gas" ->        \* 5.x: ft_on_transfer static 0, weight 1; resolver 5 Tgas
         \* (no reserve check: 9 Tgas works, ft_on_transfer gets 9000 - 6100)
         seen = {S1("onT", 13900), S2("onT", 2900)} /\ L.bal[U] = 3 /\ L.bal[D] = 2
    [] s = "ft_reserve_gas" ->    \* 3.x: static prepaid - reserve; prepaid <= reserve panics
         seen = {S1("onT", 10000)} /\ L.bal[U] = 4 /\ L.bal[D] = 1
    [] s = "batch_per_action" ->  \* a batch per action: own gas, own leftover, own out-of-gas
         \* function_call.rs:61, :343-345
         seen = {S1("onT", 13900)} /\ oog = {<<2, "batch">>}
         /\ L.bal[U] = 6 /\ L.bal[D] = 1 /\ near[U] = 7
    [] s = "batch_pooled" ->      \* TokBatchPerAction <- FALSE, PooledGasOK: one pool, whole-batch key
         seen = {S1("onT", 15400), S2("onT", 13700)} /\ oog = {}
         /\ L.bal[U] = 7 /\ L.bal[D] = 2 /\ near[U] = 4
    [] s = "path_keys" ->         \* path-specific burn keys, falling back to the method key
         oog = {<<1, "storage_deposit">>, <<3, "near_deposit">>, <<6, "ft_on_transfer">>, <<6, "ft_resolve_transfer">>}
         /\ seen = {S(5, "onT", 13900)} /\ L.bal[W] = 3 /\ L.bal[U] = 3 /\ L.bal[D] = 2
    [] s = "ft_rules" ->          \* self, unregistered receiver, zero, no yocto all fail
         L.bal[U] = 4 /\ L.bal[C] = 4 /\ near[U] = 9 /\ near[FT] = 11
    [] s = "storage" ->           \* below min fails; registered: full refund; excess refunded
         L.reg = {U, C, D, W} /\ near[U] = 8 /\ near[FT] = 12
    [] s = "wnear" ->             \* near_deposit min; near_withdraw burns and pays + 1 yocto
         L.bal[W] = 3 /\ L.bal[U] = 3 /\ L.sup = 9 /\ near[W] = 5 /\ near[U] = 12 /\ near[FT] = 13
    [] s = "batch" ->             \* a batch with the wrong total deposit fails as a whole
         L.bal[U] = 6 /\ L.bal[C] = 4 /\ L.sup = 10 /\ near[U] = 7
    [] s = "views" ->             \* ft_balance_of returns the balance
         S1("num", 5) \in seen
    [] s = "resolve_private" ->   \* the resolver is private
         L.bal[U] = 5 /\ L.bal[C] = 3
    [] s = "unregister_force" ->  \* positive balance needs force; force burns it
         \* storage_impl.rs:8-36
         U \notin L.reg /\ L.bal[U] = 0 /\ L.sup = 3 /\ near[U] = 12 /\ near[FT] = 8
    [] s = "resolver_burn" ->     \* sender unregistered meanwhile: the refund is burnt
         L.sup = 5 /\ C \notin L.reg /\ L.bal[C] = 0 /\ L.bal[D] = 0 /\ near[C] = 6 /\ near[FT] = 9

Check == Done => Expect(scn)
NoNegDeposit == \A x \in rq \cup post : x.dep >= 0
Sane  == /\ NearConserved(Total0(scn)) /\ NoOrphans /\ NoNegDeposit
         /\ TokSupplyOK /\ TokTypeOK
         /\ GasBounded(LAMBDA t : IF t <= Len(Script(scn)) THEN Script(scn)[t].gas ELSE 0)
=============================================================================
