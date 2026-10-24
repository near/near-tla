------------------------------ MODULE SelfTest ------------------------------
(***************************************************************************)
(* Library self-test: small deterministic scenarios, each a fixed script   *)
(* of transactions run one after another (the next is submitted once the   *)
(* previous one has settled; a yield waiting for a resume or a block may   *)
(* stay pending).  Expect(s) is the end state nearcore                     *)
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
(* Delegate actions (the deleg_ scenarios): a script entry Dl is a        *)
(* relayer's transaction carrying a user's signed delegate; u relays with  *)
(* its key "ku" (u's keys are not modelled), c and d are the users.        *)
(* Per-byte storage (the stor_ scenarios, run with StoragePerByte): one    *)
(* unit covers 100 bytes (SCost); v starts with 900 bytes, c and d with    *)
(* 700 (exempt: at most 770), ft with 1000, and one ft registration is 200 *)
(* bytes (its storage minimum, 2 units).                                   *)
(* Account lifecycle (the acct_, del_ and recreate scenarios): s.c, a      *)
(* sub-account of c, top (top-level; only w, the TopCreator here, may      *)
(* create it) and nimp (NEAR-implicit) do not exist; 0xa (eth-implicit,    *)
(* with code) does.  A script entry Ac is an ACCOUNT transaction           *)
(* (CreateAccount, Transfer, key actions, DeleteAccount); s.c, nimp and    *)
(* 0u1 have modelled keys (universal_off: without UniversalOn 0u1 is an    *)
(* ordinary id).  The lifecycle_storage run gives w 10,001 bytes and v     *)
(* 10,500, 600 of them code, at 2,000 bytes a unit.  A script entry AcD    *)
(* adds a DeployContract(t) (A9); the code tags' sizes are SCodeLen.       *)
(***************************************************************************)
EXTENDS Tokens, NearKeys

CONSTANT Scns       \* the scenarios explored by this run

\* Mutant switch: TRUE checks promise_yield_create_with_id's duplicates with
\* the state view PendingYields(r.to) instead of PendingYieldsAt (the check
\* the docs prescribed before; the yield_id runs must then fail).
OldDupCheck == FALSE

VARIABLES scn, ntx, acc, ran, seen
mine == <<scn, ntx, acc, ran, seen>>
vars == <<platformVars, tk, keyVars, mine>>

U == "u"  W == "w"  C == "c"  D == "d"  NC == "nc"  V == "v"  FT == "ft"
GH == "ghost"  GH2 == "ghost2"  E1 == "0xe"  E2 == "0xf"  UA == "0u1"
SB == "s.c"  TL == "top"  NI == "nimp"  EA == "0xa"
Accts    == {U, W, C, D, NC, V, FT, GH, GH2, E1, E2, UA, SB, TL, NI, EA}
SExists  == Accts \ {GH, GH2, E1, E2, UA, SB, TL, NI}
SCode    == {C, D, V, FT, UA, EA}    \* UA: listed, but a universal account created by a Transfer has no code
SKinds   == [a \in Accts |-> CASE a \in {E1, E2, EA} -> "eth_implicit"
                              [] a = UA -> "universal"
                              [] a = NI -> "near_implicit"
                              [] OTHER -> "named"]
SParents == Parents({<<SB, C>>})    \* s.c is c's sub-account; the others are top-level
SFloor   == [a \in Accts |-> CASE a = V -> 8 [] a = C -> 2 [] OTHER -> 0]
TxIds    == 1..10
NoTable  == [x \in {} |-> 0]

\* Tokens: ft is a standard FT and wNEAR; storage min 2; w is not registered.
STokHolders == [t \in {FT} |-> {U, W, C, D}]
STokMin     == [t \in {FT} |-> 2]
STokDev     == [t \in {FT} |-> {}]
STokReserve == [t \in {FT} |-> 10000]
ReserveShapes == [t \in {FT} |-> "reserve"]
\* Per-byte storage (selftest_storage): bytes at the start, 1 unit per 100 bytes.
SStor     == [a \in Accts |-> CASE a = V -> 900 [] a \in {C, D} -> 700 [] a = FT -> 1000 [] OTHER -> 0]
SCost     == <<1, 100>>
\* lifecycle_storage: w over the 10,000-byte delete limit; v under it once its code is subtracted.
LStor     == [a \in Accts |-> CASE a = W -> 10001 [] a = V -> 10500 [] OTHER -> 0]
LCost     == <<1, 2000>>
LCode     == [a \in Accts |-> IF a = V THEN 600 ELSE 0]
\* DeployContract: the code tags' bytes.
SCodeLen  == ("big" :> 1000) @@ ("tiny" :> 10) @@ ("huge" :> 10000) @@ ("child" :> 0)
STokBytes == [t \in {FT} |-> [h \in STokHolders[t] |-> IF h = W THEN 180 ELSE 150]]   \* ids of different lengths
Tok0 == [t \in {FT} |-> Ledger([h \in {U, W, C, D} |-> CASE h = U -> 5 [] h = C -> 3 [] OTHER -> 0],
                               {U, C, D})]

\* Keys: c has k0 (full), k1 (c, {ping}), k2 (c, any method); d has k0; s.c, nimp and 0u1 none.
SKeyAccts == {C, D, SB, NI, UA}
PermOf(k) == CASE k = "k0" -> FullPerm
               [] k = "k2" -> Perm(C, {}, FALSE)
               [] OTHER    -> Perm(C, {"ping"}, FALSE)
Keys0 == [a \in SKeyAccts |-> CASE a = C -> [k \in {"k0", "k1", "k2"} |-> PermOf(k)]
                                [] a = D -> ("k0" :> FullPerm)
                                [] OTHER -> <<>>]

\* Gas tables (Ggas).
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
GB(b) == [base |-> b, per |-> 0]
SGasCall == ("work" :> GC(<<0>>, <<1>>, 0)) @@ ("ft_on_transfer" :> GC(<<>>, <<>>, 100))
            @@ ("jcb" :> GC(<<1000>>, <<1>>, 0)) @@ ("ycb" :> GC(<<500>>, <<1>>, 0))
            @@ ("dcb" :> GC(<<1000>>, <<1>>, 0)) @@ ("reqr" :> GC(<<0>>, <<1>>, 0))
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
    @@ ("j" :> GB(500)) @@ ("jcb" :> GB(0)) @@ ("req" :> GB(400)) @@ ("req2" :> GB(400))
    @@ ("reqr" :> GB(400)) @@ ("callreq" :> GB(300)) @@ ("ans" :> GB(100)) @@ ("ycb" :> GB(0))
    @@ ("dcb" :> GB(0)) @@ ("who" :> GB(100)) @@ ("whoc" :> GB(300))
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
\* promise_yield_create_with_id: the custom id k is kept in the args (amt),
\* with a generation number (cd); only ycbid yields carry one.
YidArgs(k, gen) == G("", "", "", k, gen, "", "")
YidOf(p) == IF p.m = "ycbid" THEN Ar(p).amt ELSE -1
YidTaken(r, ps, k) ==
    IF OldDupCheck THEN \E p \in post : p.id \in PendingYields(r.to) /\ YidOf(p) = k
    ELSE \E p \in PendingYieldRcpts(r, ps) : YidOf(p) = k
YieldId(id, r, k, gen) == YieldRcpt(id, r, "ycbid", YidArgs(k, gen), 0, 0)
CbOf(r, id) == Rcpt(id, r.tx, r.to, r.to, "cb", G0, 0, r.to, r.cb)
\* "who:<receiver><-<predecessor> signer <signer>/<signer key>", with the receipt's gas.
Who(r) == Sn(r, "who:" \o r.to \o "<-" \o r.fr \o " signer " \o Signer(r) \o "/" \o SignerKey(r), GasOf(r))
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
                            \* d.work takes the whole leftover and the callback gets nothing;
                            \* a.k = "two": two d.work calls, static 0, weight 1 each;
                            \* a.k = "one": one d.work call, static 0, weight 1;
                            \* a.k = "heavy": two d.work calls, static 0, weights 1 and 10^9
         IF a.k = "two"
         THEN [O |-> Outcome({WithCall(Rcpt(nid + i, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>, <<1>>) : i \in 0..1},
                             {}, RVal(0), 0, 2), s |-> {}]
         ELSE IF a.k = "one"
         THEN [O |-> Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>, <<1>>)},
                             {}, RVal(0), 0, 1), s |-> {}]
         ELSE IF a.k = "heavy"
         THEN [O |-> Outcome({WithCall(Rcpt(nid + i, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>,
                                       <<IF i = 0 THEN 1 ELSE 1000000000>>) : i \in 0..1},
                             {}, RVal(0), 0, 2), s |-> {}]
         ELSE IF a.k = "cb"
         THEN [O |-> Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, nid + 1), <<0>>, <<1>>)},
                             {WithCall(CbOf(r, nid + 1), <<0>>, <<0>>)}, RVal(0), 0, 2), s |-> {}]
         ELSE [O |-> Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "work", G0, 0, r.to, 0), <<0>>, <<0>>)},
                             {}, RVal(0), 0, 1), s |-> {}]
    [] r.m = "work" ->
         [O |-> (CASE a.w = "fail" -> OErr(Out0, "work panics")
                   [] a.w = "zero" -> Out0
                   [] a.w = "sz"   -> Outcome({}, {}, RValSz(1, 3), 0, 0)
                   [] a.w = "grow" -> OStor(Outcome({}, {}, RVal(1), 0, 0), 100)   \* writes 100 bytes
                   [] OTHER        -> Outcome({}, {}, RVal(1), 0, 0)),
          s |-> {Sn(r, "work", GasOf(r))}]
    [] r.m \in {"cb", "probe"} -> [O |-> Out0, s |-> SeenRes(r)]
    [] r.m = "send" ->      \* Transfer a.amt to a.to, then self.cb
         [O |-> Outcome({Rcpt(nid, r.tx, a.to, r.to, XFER, G0, a.amt, r.to, nid + 1)},
                        {CbOf(r, nid + 1)}, RVal(0), a.amt, 2), s |-> {}]
    [] r.m = "put" ->       \* writes a.amt bytes (a.amt < 0: frees them)
         [O |-> OStor(Out0, a.amt), s |-> {Sn(r, "put", a.amt)}]
    [] r.m = "putpay" ->    \* writes a.amt bytes and Transfers a.cd to u, then self.cb
         [O |-> OStor(Outcome({Rcpt(nid, r.tx, U, r.to, XFER, G0, a.cd, r.to, nid + 1)},
                              {CbOf(r, nid + 1)}, RVal(0), a.cd, 2), a.amt),
          s |-> {Sn(r, "putpay", a.amt)}]
    [] r.m = "spend" ->     \* Transfer a.amt to u
         [O |-> Outcome({Rcpt(nid, r.tx, U, r.to, XFER, G0, a.amt, r.to, 0)}, {}, RVal(0), a.amt, 1),
          s |-> {}]
    [] r.m = "mkacct" ->    \* CreateAccount a.to with a.amt NEAR (a factory), then self.cb
         [O |-> Outcome({CreateAcctRcpt(nid, r.tx, a.to, r.to, G0, a.amt, nid + 1)},
                        {CbOf(r, nid + 1)}, RVal(0), a.amt, 2), s |-> {}]
    [] r.m = "mkinit" ->    \* the factory batch [CreateAccount, Transfer(a.amt), AddKey(a.key)?,
                            \* DeployContract(a.w)?, FunctionCall(init), DeleteAccount(a.rto)?]
                            \* on a.to, init adding a.cd bytes; then self.cb
         LET cc == WithCreate(Rcpt(nid, r.tx, a.to, r.to, "init", G("", "", "", a.cd, 0, "", ""), a.amt, r.to, nid + 1))
             c0 == IF a.w = "" THEN cc ELSE WithDeploy(cc, a.w)
             c1 == IF a.key = "" THEN c0 ELSE WithAcctKeys(c0, <<AddKeyAct(a.key, PermOf(a.key))>>)
             c  == IF a.rto = "" THEN c1 ELSE WithDeleteTo(c1, a.rto) IN
         [O |-> Outcome({c}, {CbOf(r, nid + 1)}, RVal(0), a.amt, 2), s |-> {}]
    [] r.m = "init" ->      \* the new account's init: adds a.amt bytes, returns 7; records its
                            \* attached deposit ("idep") and its balance ("ibal")
         [O |-> OStor(Outcome({}, {}, RVal(7), 0, 0), a.amt),
          s |-> {Sn(r, "init", 1), Sn(r, "idep", r.dep), Sn(r, "ibal", BalSeen(r))}]
    [] r.m = "closecall" -> \* [FunctionCall(last), DeleteAccount(u)] on a.to (c itself, or not)
         [O |-> Outcome({WithDeleteTo(Rcpt(nid, r.tx, a.to, r.to, "last", G("", "", "", a.amt, a.cd, "", ""), 0, r.to, 0), U)},
                        {}, RVal(0), 0, 1), s |-> {}]
    [] r.m = "closeprom" -> \* [FunctionCall(lastp), DeleteAccount(u)] on c itself, then d.cb
         [O |-> Outcome({WithDeleteTo(Rcpt(nid, r.tx, r.to, r.to, "lastp", G0, 0, r.to, nid + 1), U)},
                        {Rcpt(nid + 1, r.tx, D, r.to, "cb", G0, 0, r.to, 0)}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "lastp" ->     \* returns a promise: a Transfer of 1 to u, wired to r.cb (tail.cb := r.cb)
         [O |-> Outcome({Rcpt(nid, r.tx, U, r.to, XFER, G0, 1, r.to, r.cb)}, {}, RProm, 1, 1),
          s |-> {Sn(r, "lastp", 1)}]
    [] r.m = "last" ->      \* sends a.amt to u and adds a.cd bytes, before the delete
         [O |-> OStor(Outcome(IF a.amt > 0 THEN {Rcpt(nid, r.tx, U, r.to, XFER, G0, a.amt, r.to, 0)} ELSE {},
                              {}, RVal(0), a.amt, IF a.amt > 0 THEN 1 ELSE 0), a.cd),
          s |-> {Sn(r, "last", 1)}]
    [] r.m = "bye" ->       \* c closes: DeleteAccount(c -> u), instant, and d.relay(c.probe)
         [O |-> Outcome({DeleteAcctRcpt(nid, r.tx, r.to, G0, U, 0),
                         Rcpt(nid + 1, r.tx, D, r.to, "relay", G("", "", r.to, 0, 0, "", ""), 0, r.to, 0)},
                        {}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "byeb" ->      \* c closes: DeleteAccount(c -> d), and d.seebal
         [O |-> Outcome({DeleteAcctRcpt(nid, r.tx, r.to, G0, D, 0),
                         Rcpt(nid + 1, r.tx, D, r.to, "seebal", G0, 0, r.to, 0)},
                        {}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "relay" ->     \* calls a.to.probe
         [O |-> Outcome({Rcpt(nid, r.tx, a.to, r.to, "probe", G0, 0, r.to, 0)}, {}, RVal(0), 0, 1), s |-> {}]
    [] r.m = "seebal" ->    \* records the receiver's balance when it runs
         [O |-> Out0, s |-> {Sn(r, "bal", BalSeen(r))}]
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
    [] r.m = "j" ->         \* promise_and(d.work(fail), d.work(ok)).then(self.jcb); legs static
                            \* 2 Tgas, weight 0.  a.k: "zero" jcb with no gas; "starve" both legs
                            \* ok, leg 2 with static 200 Ggas (below its burn)
         LET Leg(id, w, st) == WithCall(Rcpt(id, r.tx, D, r.to, "work", G("", w, "", 0, 0, "", ""), 0, r.to, 0),
                                        <<st>>, <<0>>)
             cb0 == Rcpt(nid + 2, r.tx, r.to, r.to, "jcb", G0, 0, r.to, r.cb)
             j == AndThen(<<Leg(nid, IF a.k = "" THEN "fail" ELSE "ok", 2000),
                            Leg(nid + 1, "ok", IF a.k = "starve" THEN 200 ELSE 2000)>>,
                          IF a.k = "zero" THEN WithCall(cb0, <<0>>, <<0>>) ELSE cb0, nid + 3)
         IN [O |-> Outcome({j.kids[1], j.kids[2]}, {j.cb}, RVal(0), 0, 5), s |-> {}]
    [] r.m = "jcb" ->       \* the joint callback: count, results in order, r.res, gas
         [O |-> Out0,
          s |-> {Sn(r, "nres", NRes(r)), Sn(r, "res:" \o ResTag(r.res), 0),
                 Sn(r, "r1:" \o ResTag(ResAt(r, 1)), NumOr(ResAt(r, 1), 0)),
                 Sn(r, "r2:" \o ResTag(ResAt(r, 2)), NumOr(ResAt(r, 2), 0)), Sn(r, "jgas", GasOf(r))}]
    [] r.m = "req" ->       \* yield self.ycb (a.k = "zero": with no gas)
         LET y0 == YieldRcpt(nid, r, "ycb", G0, 0, 0) IN
         [O |-> Outcome({}, {IF a.k = "zero" THEN WithCall(y0, <<0>>, <<0>>) ELSE y0}, RVal(0), 0, 1),
          s |-> {Sn(r, "y", nid)}]
    [] r.m = "req2" ->      \* yield self.ycb and resume it twice in the same call (5, then 6)
         [O |-> OResume(OResume(Outcome({}, {YieldRcpt(nid, r, "ycb", G0, 0, 0)}, RVal(0), 0, 1),
                                nid, 5, 0), nid, 6, 0), s |-> {}]
    [] r.m = "reqr" ->      \* yield self.ycb and return it
         [O |-> Outcome({}, {YieldRcpt(nid, r, "ycb", G0, 0, r.cb)}, RProm, 0, 1), s |-> {}]
    [] r.m = "callreq" ->   \* c.reqr().then(self.dcb)
         [O |-> Outcome({Rcpt(nid, r.tx, C, r.to, "reqr", G0, 0, r.to, nid + 1)},
                        {Rcpt(nid + 1, r.tx, r.to, r.to, "dcb", G0, 0, r.to, r.cb)}, RVal(0), 0, 2), s |-> {}]
    [] r.m = "dcb" -> [O |-> Out0, s |-> {Sn(r, "dcb:" \o ResTag(r.res), NumOr(r.res, 0))}]
    [] r.m = "ans" ->       \* promise_yield_resume(a.amt, a.cd); n = its return value
         [O |-> OResume(Out0, a.amt, a.cd, 0), s |-> {Sn(r, "ans", IF CanResume(r, a.amt) THEN 1 ELSE 0)}]
    [] r.m = "reqid" ->     \* promise_yield_create_with_id(a.amt) for self.ycbid;
                            \* yid 1: created, 0: a duplicate (u64::MAX, nothing created)
         IF YidTaken(r, {}, a.amt) THEN [O |-> Out0, s |-> {Sn(r, "yid", 0)}]
         ELSE [O |-> Outcome({}, {YieldId(nid, r, a.amt, 0)}, RVal(0), 0, 1), s |-> {Sn(r, "yid", 1)}]
    [] r.m = "reqid2" ->    \* the same, twice in one call; yid2: the second one
         LET y1 == YieldId(nid, r, a.amt, 0) IN
         IF YidTaken(r, {y1}, a.amt)
         THEN [O |-> Outcome({}, {y1}, RVal(0), 0, 1), s |-> {Sn(r, "yid", 1), Sn(r, "yid2", 0)}]
         ELSE [O |-> Outcome({}, {y1, YieldId(nid + 1, r, a.amt, 0)}, RVal(0), 0, 2),
               s |-> {Sn(r, "yid", 1), Sn(r, "yid2", 1)}]
    [] r.m = "ycbid" ->     \* the custom-id callback, resumed or timed out: generation 0
                            \* re-creates its own custom id; reyid 1: created, 0: a duplicate
         IF a.cd # 0 THEN [O |-> Out0, s |-> {}]
         ELSE IF YidTaken(r, {}, a.amt) THEN [O |-> Out0, s |-> {Sn(r, "reyid", 0)}]
         ELSE [O |-> Outcome({}, {YieldId(nid, r, a.amt, 1)}, RVal(0), 0, 1), s |-> {Sn(r, "reyid", 1)}]
    [] r.m = "who" ->       \* records receiver, predecessor, signer, signer key and its gas
         [O |-> Out0, s |-> {Who(r)}]
    [] r.m = "whoc" ->      \* the same, and d.who as a child (static 1000, weight 1)
         [O |-> Outcome({WithCall(Rcpt(nid, r.tx, D, r.to, "who", G0, 0, r.to, 0), <<1000>>, <<1>>)},
                        {}, RVal(0), 0, 1), s |-> {Who(r)}]
    [] r.m = "ycb" ->       \* the yield callback: returns the payload; panics on a timeout
         [O |-> IF IsFailed(r.res) THEN OErr(Out0, "timed out") ELSE Outcome({}, {}, RVal(r.res.v), 0, 0),
          s |-> {Sn(r, "ycb", NumOr(r.res, 0)), Sn(r, "ygas", GasOf(r))}]
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

\* An ACCOUNT receipt; an instant one is recorded in seen ("inst").
RunAcct(r) == /\ ExecAcctK(r)
              /\ seen' = IF IsInstant(r) THEN seen \cup {Sn(r, "inst", 1)} ELSE seen
              /\ UNCHANGED <<tk, scn, ntx, acc, ran>>

\* A call receipt with account actions (A8): with its key actions (ExecK, OkK).
RunAcC(r) ==
    LET h == H(r)  O == h.O IN
    /\ ExecK(r, O)
    /\ ran'  = IF OkK(r, O) THEN ran \cup {<<r.tx, r.to, r.m>>} ELSE ran
    /\ seen' = IF OkK(r, O) THEN seen \cup h.s ELSE seen
    /\ UNCHANGED <<tk, scn, ntx, acc>>

RunTok(r) == \E ch \in TokChoices(r) : TokStep(r, TokHandle(r, ch)) /\ UNCHANGED <<keyVars, mine>>
RunKey(r) == ExecKeyAct(r, Ar(r).key, PermOf(Ar(r).key)) /\ UNCHANGED <<tk, mine>>

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltinK(r) /\ UNCHANGED <<tk, mine>>
         ELSE IF IsKeyRcpt(r) THEN RunKey(r)
         ELSE IF IsDeleg(r) THEN ExecDelegate(r) /\ UNCHANGED <<tk, mine>>
         ELSE IF IsAcctRcpt(r) THEN RunAcct(r)
         ELSE IF IsTokRcpt(r) THEN RunTok(r)
         ELSE IF r.m = "kbundle" THEN RunBundle(r)
         ELSE IF HasAc(r) THEN RunAcC(r)
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
BTick == Tx(C, C, "btick", G0, 0) \* one block (BlockTick), not a transaction
Ans(to, y, v) == TxG(to, to, "ans", G("", "", "", y, v, "", ""), 0, 10000)   \* resume y with v
Amt(n) == G("", "", "", n, 0, "", "")
\* A relayer rl's transaction (signed with its key rk) carrying user s's delegate: key k,
\* nonce n, expiry mbh; the inner call to.m with deposit dep and (gas mode) 10 Tgas.
Dl(rl, rk, s, k, n, mbh, to, m, dep) ==
    T(s, rl, DELEG, [k |-> k, n |-> n, mbh |-> mbh, ito |-> to, im |-> m], dep, 10000, rk, <<>>)
\* An ACCOUNT transaction from fr to to: [CreateAccount if mk, Transfer(dep) if dep > 0,
\* the key actions ka, DeleteAccount(bnf) if bnf # ""].
Ac(to, fr, mk, dep, bnf, ka) == T(to, fr, ACCT, [mk |-> mk, bnf |-> bnf, ka |-> ka], dep, 0, "", <<>>)
\* The same with DeployContract(t) after the key actions.
AcD(to, fr, mk, dep, bnf, ka, t) ==
    T(to, fr, ACCT, [mk |-> mk, bnf |-> bnf, ka |-> ka, dpl |-> t], dep, 0, "", <<>>)
AddK(k) == AddKeyAct(k, PermOf(k))

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
    [] s = "zero_gas_share"   -> << TxG(C, U, "spawn0", G("two", "", "", 0, 0, "", ""), 0, 501) >>
    [] s = "zero_gas_left0"   -> << TxG(C, U, "spawn0", G("one", "", "", 0, 0, "", ""), 0, 500) >>
    [] s = "zero_gas_heavy"   -> << TxG(C, U, "spawn0", G("heavy", "", "", 0, 0, "", ""), 0, 501) >>
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
    \* v0.2 scenarios.  Yield ids are receipt ids, deterministic here: tx 1's yield is 2.
    [] s = "and_order"        -> << TxG(C, U, "j", G0, 0, 10000) >>
    [] s = "and_zero_cb"      -> << TxG(C, U, "j", G("zero", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "and_starved_leg"  -> << TxG(C, U, "j", G("starve", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "resume_twice"     -> << TxG(C, U, "req", G0, 0, 10000), Ans(C, 2, 5), Ans(C, 2, 6) >>
    [] s = "resume_same_call" -> << TxG(C, U, "req2", G0, 0, 10000) >>
    [] s = "timeout_then_resume" -> << TxG(C, U, "req", G0, 0, 10000), BTick, Ans(C, 2, 5) >>
    [] s = "resume_beats_timeout" -> << TxG(C, U, "req", G0, 0, 10000), Ans(C, 2, 5), BTick >>
    [] s = "resume_other_acct" -> << TxG(C, U, "req", G0, 0, 10000), Ans(D, 2, 5), BTick >>
    [] s = "yield_returned"   -> << TxG(D, U, "callreq", G0, 0, 20000), Ans(C, 4, 5) >>
    [] s = "yield_zero_cb"    -> << TxG(C, U, "req", G("zero", "", "", 0, 0, "", ""), 0, 10000) >>
    [] s = "yield_id_recreate" -> << TxG(C, U, "reqid", YidArgs(7, 0), 0, 10000), Ans(C, 2, 5) >>
    [] s = "yield_id_recreate_timeout" -> << TxG(C, U, "reqid", YidArgs(7, 0), 0, 10000), BTick >>
    [] s = "yield_id_same_call" -> << TxG(C, U, "reqid2", YidArgs(7, 0), 0, 10000) >>
    \* Delegate actions.  u relays; d (key k0) and c (keys k0, k1, k2) sign.
    [] s = "deleg_ok"         -> << Dl(U, "ku", D, "k0", 1, NoExpiry, C, "whoc", 0),
                                    Dl(U, "ku", D, "k0", 2, NoExpiry, W, XFER, 2) >>
    [] s = "deleg_replay"     -> << Dl(U, "ku", D, "k0", 1, NoExpiry, C, "who", 1),
                                    Dl(U, "ku", D, "k0", 1, NoExpiry, C, "who", 1),   \* replay
                                    Dl(U, "ku", D, "k0", 5, NoExpiry, C, "who", 1),   \* a gap: ok
                                    Dl(U, "ku", D, "k0", 3, NoExpiry, C, "who", 1) >> \* below 5
    [] s = "deleg_expired"    -> << Dl(U, "ku", D, "k0", 1, 0, C, "who", 1),          \* at 0: ok
                                    BTick,
                                    Dl(U, "ku", D, "k0", 2, 0, C, "who", 1),          \* at 1: expired
                                    Dl(U, "ku", D, "k0", 2, 1, C, "who", 1) >>        \* nonce 2 still free
    [] s = "deleg_inner_fail" -> << Dl(U, "ku", D, "k0", 1, NoExpiry, C, "boom", 2) >>
    [] s = "deleg_fc_key"     -> << Dl(U, "ku", C, "k1", 1, NoExpiry, C, "ping", 0),  \* ok
                                    Dl(U, "ku", C, "k1", 2, NoExpiry, C, "ping", 1),  \* deposit
                                    Dl(U, "ku", C, "k1", 2, NoExpiry, D, "ping", 0),  \* receiver
                                    Dl(U, "ku", C, "k1", 2, NoExpiry, C, "pong", 0),  \* method
                                    Dl(U, "ku", C, "k2", 1, NoExpiry, C, "pong", 0),  \* ok: any method
                                    Dl(U, "ku", C, "k2", 2, NoExpiry, C, XFER, 1) >>  \* not a call
    [] s = "deleg_fc_relayer" -> << Dl(C, "k2", C, "k0", 1, NoExpiry, C, "ping", 0),  \* c's FC key
                                    Dl(C, "k0", C, "k0", 1, NoExpiry, C, "ping", 0) >>
    [] s = "deleg_checks"     -> << Tx(C, C, "keyact", G("del", "", C, 0, 0, "", "k2"), 0),
                                    Dl(U, "ku", C, "k2", 1, NoExpiry, C, "pong", 0),  \* key deleted
                                    Dl(U, "ku", GH, "k0", 1, NoExpiry, C, "who", 1) >> \* no such sender
    \* Per-byte storage (StoragePerByte).  Bytes: v 900, c and d 700, ft 1000; 100 bytes a unit.
    [] s = "stor_grow"        -> << Tx(V, U, "put", Amt(100), 0),     \* 1000 bytes, 10 units: ok
                                    Tx(V, U, "put", Amt(1), 0),       \* 1001: fails
                                    Tx(V, U, "put", Amt(1), 1) >>     \* with 1 more unit: ok
    [] s = "stor_revert"      -> << Tx(V, U, "putpay", G("", "", "", 300, 2, "", ""), 1),
                                    Tx(C, U, "spawn", G("", "grow", "", 0, 0, "", ""), 0) >>
    [] s = "stor_shrink"      -> << Tx(V, V, "spend", Amt(2), 0),     \* 8 units left for 900 bytes
                                    Tx(V, U, "put", Amt(-100), 0),
                                    Tx(V, V, "spend", Amt(2), 0) >>   \* 8 units for 800 bytes: ok
    [] s = "stor_zero_balance"-> << Tx(D, U, "put", Amt(70), 0),      \* d has 0 units: 770 bytes ok
                                    Tx(D, U, "put", Amt(1), 0) >>     \* 771: fails
    [] s = "stor_locked"      -> << Tx(V, V, "spend", Amt(1), 0),     \* liquid 4, locked 5, 900 bytes
                                    Tx(V, U, "put", Amt(-100), 0),
                                    Tx(V, V, "spend", Amt(1), 0) >>   \* 3 + 5 cover 800 bytes
    [] s = "stor_keys"        -> << Tx(C, C, "keyact", G("add", "", C, 0, 0, "", "k3"), 0),
                                    Tx(C, C, "keyact", G("del", "", C, 0, 0, "", "k2"), 0),
                                    Tx(C, C, "keyact", G("add", "", C, 0, 0, "", "k3"), 0),
                                    Tx(C, C, "kbundle", G("", "", "", 0, 0, "", "k5"), 0) >>
    [] s = "stor_implicit"    -> << Tx(C, U, "send", G("", "", E1, 2, 0, "", ""), 0) >>
    [] s = "stor_signer"      -> << Tx(C, V, "probe", G0, 2),         \* leaves v 8 units for 900 bytes
                                    Tx(C, V, "probe", G0, 1) >>
    [] s = "stor_tokens"      -> << Tx(FT, U, "storage_deposit", SdArgs(W), 3),
                                    Tx(FT, U, "storage_unregister", SuArgs(TRUE), 1),
                                    Tx(FT, U, "storage_deposit", SdArgs(U), 2) >>
    \* Account lifecycle.  s.c's parent is c; w is the TopCreator.
    [] s = "acct_create"      -> << Tx(C, U, "mkacct", G("", "", SB, 1, 0, "", ""), 0),   \* ok
                                    Tx(C, U, "mkacct", G("", "", SB, 1, 0, "", ""), 0),   \* exists
                                    Ac(SB, C, TRUE, 1, "", <<>>) >>                       \* exists
    [] s = "acct_keys"        -> << Ac(SB, C, TRUE, 2, "", <<AddK("k0"), AddK("k0")>>),    \* key twice
                                    Ac(SB, C, TRUE, 2, "", <<AddK("k0"), AddK("k1")>>) >>
    [] s = "acct_not_parent"  -> << Ac(SB, U, TRUE, 1, "", <<>>), Ac(SB, W, TRUE, 1, "", <<>>) >>
    [] s = "acct_implicit"    -> << Ac(NI, U, TRUE, 1, "", <<>>), Ac(E1, U, TRUE, 1, "", <<>>),
                                    Ac(UA, U, TRUE, 1, "", <<>>) >>
    [] s = "acct_top"         -> << Ac(TL, U, TRUE, 1, "", <<>>), Ac(TL, W, TRUE, 1, "", <<>>) >>
    [] s = "acct_fee"         -> << >>
    [] s = "del_beneficiary"  -> << Ac(C, U, FALSE, 0, U, <<>>),     \* u is not c: refused
                                    Ac(W, W, FALSE, 0, U, <<>>) >>
    [] s = "del_absent"       -> << Ac(W, W, FALSE, 0, GH, <<>>) >>
    [] s = "del_self"         -> << Ac(W, W, FALSE, 0, W, <<>>) >>
    [] s = "del_staking"      -> << Tx(V, V, "dostake", Amt(4), 0), Ac(V, V, FALSE, 0, U, <<>>) >>
    [] s = "del_receipts"     -> << Ac(D, D, FALSE, 0, U, <<>>),
                                    Tx(D, U, "foo", G0, 1),                              \* a call
                                    Tx(C, U, "send", G("", "", D, 2, 0, "", ""), 0),     \* a Transfer
                                    Tx(D, D, "keyact", G("add", "", D, 0, 0, "", "k3"), 0) >>  \* d signs
    [] s = "recreate"         -> << Ac(SB, C, TRUE, 2, "", <<AddK("k0")>>),
                                    Ac(SB, SB, FALSE, 0, C, <<>>),
                                    Ac(SB, C, TRUE, 1, "", <<>>) >>
    [] s = "implicit_recreate"-> << Tx(C, U, "send", G("", "", NI, 1, 0, "", ""), 0),
                                    Ac(NI, NI, FALSE, 0, U, <<>>),
                                    Tx(C, U, "send", G("", "", NI, 1, 0, "", ""), 0) >>
    [] s = "stale_cb_recreate"-> << TxG(EA, U, "req", G0, 0, 10000),                     \* yield 2 on 0xa
                                    Ac(EA, EA, FALSE, 0, U, <<>>),
                                    Tx(C, U, "send", G("", "", EA, 1, 0, "", ""), 0),    \* 0xa again
                                    Ans(EA, 2, 5) >>
    \* Instant receipts.
    [] s = "instant_close"    -> << Tx(C, U, "bye", G0, 0) >>
    [] s = "instant_payout"   -> << Tx(C, U, "byeb", G0, 0) >>
    [] s = "instant_deleg"    -> << Dl(U, "ku", D, "k0", 1, NoExpiry, D, ACCT, 0) >>
    [] s = "instant_deleg_local" -> << Dl(D, "k0", D, "k0", 1, NoExpiry, D, ACCT, 0) >>
    [] s = "instant_tx"       -> << Ac(W, W, FALSE, 0, U, <<>>) >>
    [] s = "del_large"        -> << Ac(W, W, FALSE, 0, U, <<>>), Ac(V, V, FALSE, 0, U, <<>>) >>
    \* Call receipts with account actions (A8).  c is s.c's parent.
    [] s = "accall_nocode"    -> << Tx(C, U, "mkinit", G("", "", SB, 2, 0, "", ""), 0) >>
    [] s = "accall_delete"    -> << Tx(C, U, "closecall", G("", "", C, 0, 0, "", ""), 0) >>
    [] s = "accall_actor"     -> << Tx(C, U, "closecall", G("", "", D, 0, 0, "", ""), 0) >>
    [] s = "accall_init"      -> << Tx(C, U, "mkinit", G("", "", SB, 2, 0, "", "k0"), 0) >>
    [] s = "accall_exists"    -> << Ac(SB, C, TRUE, 1, "", <<>>),
                                    Tx(C, U, "mkinit", G("", "", SB, 2, 0, "", ""), 0) >>
    [] s = "accall_recreate"  -> << Ac(SB, C, TRUE, 1, "", <<AddK("k0")>>),
                                    Ac(SB, SB, FALSE, 0, C, <<>>),
                                    Tx(C, U, "mkinit", G("", "", SB, 2, 0, "", ""), 0) >>
    [] s = "accall_create_del"-> << Tx(C, U, "mkinit", G("", "", SB, 2, 0, C, ""), 0) >>
    [] s = "accall_not_parent"-> << Tx(D, U, "mkinit", G("", "", SB, 0, 0, "", ""), 0) >>
    [] s = "accall_bytes"     -> << Tx(C, U, "mkinit", G("", "", SB, 1, 0, "", "k0"), 0) >>
    [] s = "accall_lackstate" -> << Tx(C, U, "mkinit", G("", "", SB, 0, 1000, "", ""), 0) >>
    [] s = "accall_prom"      -> << Tx(C, U, "closeprom", G0, 0) >>
    [] s = "code_off_missing" -> << Tx(GH, U, "foo", G0, 1),                              \* missing
                                    Tx(C, U, "send", G("", "", UA, 2, 0, "", ""), 0),
                                    Tx(UA, U, "foo", G0, 1) >>                            \* uninitialised
    [] s = "accall_del_stor"  -> << Tx(C, U, "closecall", G("", "", C, 4, 5000, "", ""), 0) >>
    \* Without UniversalOn (protocol < 87) 0u1 is a named top-level id.
    [] s = "universal_off"    -> << Ac(UA, W, TRUE, 2, "", <<AddK("k0")>>),             \* w creates it
                                    Ac(UA, UA, FALSE, 0, "", <<AddK("k1")>>),            \* a key action
                                    Dl(U, "ku", UA, "k1", 1, NoExpiry, C, "ping", 0),    \* a delegate (k1)
                                    Ac(UA, UA, FALSE, 0, W, <<>>) >>                     \* a delete
    \* DeployContract (A9).
    [] s = "deploy_self"      -> << AcD(W, W, FALSE, 0, "", <<>>, "wc"),                 \* w deploys
                                    Tx(W, U, "foo", G0, 1) >>                            \* and runs code
    [] s = "deploy_actor"     -> << AcD(C, U, FALSE, 0, "", <<>>, "x") >>                \* u on c
    [] s = "deploy_init"      -> << Tx(C, U, "mkinit", G("", "child", SB, 2, 0, "", ""), 0) >>
    [] s = "deploy_recreate"  -> << AcD(SB, C, TRUE, 2, "", <<AddK("k0")>>, "child"),
                                    Ac(SB, SB, FALSE, 0, C, <<>>),
                                    Ac(SB, C, TRUE, 1, "", <<>>),
                                    Tx(SB, U, "foo", G0, 1) >>                           \* no code now
    [] s = "deploy_bytes"     -> << AcD(SB, C, TRUE, 1, "", <<AddK("k0")>>, "big") >>
    [] s = "deploy_replace"   -> << AcD(V, V, FALSE, 0, "", <<>>, "big"),
                                    AcD(V, V, FALSE, 0, "", <<>>, "tiny") >>
    [] s = "deploy_del_large" -> << AcD(V, V, FALSE, 0, "", <<>>, "big"),
                                    Ac(V, V, FALSE, 0, U, <<>>) >>
    [] s = "deploy_del_same"  -> << AcD(V, V, FALSE, 0, U, <<>>, "big") >>
    [] s = "deploy_lackstate" -> << AcD(W, W, FALSE, 0, "", <<>>, "huge") >>
    [] s = "eth_wallet_call"  -> << Tx(C, U, "send", G("", "", E2, 1, 0, "", ""), 0),    \* 0xf (not in SCode)
                                    Tx(E2, U, "foo", G0, 1) >>
    [] s = "eth_recreate_code"-> << AcD(EA, EA, FALSE, 0, "", <<>>, "local"),             \* 0xa's own code
                                    Ac(EA, EA, FALSE, 0, U, <<>>),                       \* deleted
                                    Tx(C, U, "send", G("", "", EA, 1, 0, "", ""), 0),    \* 0xa again
                                    Tx(EA, U, "foo", G0, 1) >>
    [] s = "acct_bytes"       -> << Ac(SB, C, TRUE, 1, "", <<AddK("k0")>>) >>
    [] s = "acct_bytes_del"   -> << Ac(SB, C, TRUE, 1, "", <<AddK("k0")>>),
                                    Ac(SB, SB, FALSE, 0, C, <<>>) >>

Near0(s) == [a \in Accts |-> CASE a \in {U, W, V, FT} ->
                                  (IF s \in {"floor_locked", "liquid_negative", "stor_locked"} /\ a = V
                                   THEN 4 ELSE 10)
                               [] a = C -> 5
                               [] OTHER -> 0]
Locked0(s) == CASE s \in {"floor_locked", "stor_locked"} -> 5 [] s = "liquid_negative" -> 20 [] OTHER -> 0
Total0(s) == LET n == Near0(s) IN
             n[U] + n[W] + n[V] + n[FT] + n[C] + Locked0(s)

MkTx(e, id, t) ==
    LET r0 == Rcpt(id, t, e.to, e.fr, e.m, e.a, e.dep, e.fr, 0)
        r1 == IF e.gs # <<>> THEN WithStatic(r0, e.gs) ELSE r0
    IN IF e.m = ACCT   \* an action-only receipt: no gas of its own
       THEN LET a0 == WithAcctKeys(AcctRcpt(id, t, e.to, e.fr, G0, e.dep, 0, e.a.mk, e.a.bnf), e.a.ka) IN
            IF "dpl" \in DOMAIN e.a THEN WithDeploy(a0, e.a.dpl) ELSE a0
       ELSE IF GasMode # "gas" THEN r1
       ELSE IF Len(e.gs) > 1 THEN [r1 EXCEPT !.g = e.gs]   \* one gas per function-call action
       ELSE WithGas(r1, e.gas)
CanSign(a, k, r) == (a \in KeyAccts) => KeyCanSign(a, k, r)
\* A delegate entry's signed delegate (the user's signature) and its inner call.
\* An inner ACCT is [DeleteAccount(user -> u)].
DInner(e) == LET c == IF e.a.im = ACCT THEN DeleteAcctRcpt(0, 0, e.to, G0, U, 0)
                     ELSE Rcpt(0, 0, e.a.ito, e.to, e.a.im, G0, e.dep, e.to, 0) IN
             IF GasMode = "gas" /\ IsCall(c) THEN WithGas(c, e.gas) ELSE c
SD(e) == SignedDelegate(e.to, e.a.k, e.a.n, e.a.mbh, DInner(e))

\* A yield is pending and nothing can run except yield callbacks that have a
\* resume payload (a parked yield, or receipts waiting on one, may remain).
Parked == rq = {} /\ (\E p \in post : IsYield(p)) /\ \A x \in Runnable : IsYield(x) /\ x.res.ok
\* The next transaction may go once the previous one has settled, or once it
\* is Parked (so that a second resume can race the first one's callback).
\* Without yields this is Idle.
Quiet == Idle \/ Parked

Send ==
    /\ Quiet
    /\ ntx < Len(Script(scn))
    /\ LET e == Script(scn)[ntx + 1]  r == MkTx(e, nid, ntx + 1) IN
       IF e.m = "tick" THEN EpochTick /\ acc' = Append(acc, TRUE) /\ UNCHANGED keyVars
       ELSE IF e.m = "btick" THEN BlockTick /\ acc' = Append(acc, TRUE) /\ UNCHANGED keyVars
       ELSE IF e.m = DELEG
            THEN LET d == DelegRcpt(nid, ntx + 1, e.fr, SD(e)) IN
                 IF CanSign(e.fr, e.key, d) /\ CanSubmit(d, e.fr)
                 THEN SubmitDelegate(nid, ntx + 1, e.fr, e.key, SD(e)) /\ acc' = Append(acc, TRUE)
                 ELSE acc' = Append(acc, FALSE) /\ UNCHANGED <<platformVars, keyVars>>
       \* A transaction nearcore refuses (CanSubmit, CanSign) is recorded as FALSE.
       ELSE IF ~CanSubmit(r, e.fr) THEN acc' = Append(acc, FALSE) /\ UNCHANGED <<platformVars, keyVars>>
       ELSE IF e.key = "" THEN Submit(r) /\ acc' = Append(acc, TRUE) /\ UNCHANGED keyVars
       ELSE IF CanSign(e.fr, e.key, r) THEN SubmitSigned(r, e.fr, e.key) /\ acc' = Append(acc, TRUE)
       ELSE acc' = Append(acc, FALSE) /\ UNCHANGED <<platformVars, keyVars>>
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<tk, scn, ran, seen>>

Done == ntx = Len(Script(scn)) /\ (Idle \/ (Parked /\ Runnable = {}))

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
GV(g) == IF GasMode = "gas" THEN g ELSE 0
S1(tag, n) == [tx |-> 1, tag |-> tag, n |-> n]
S2(tag, n) == [tx |-> 2, tag |-> tag, n |-> n]
S(t, tag, n) == [tx |-> t, tag |-> tag, n |-> n]
TxsSeen == {x.tx : x \in seen}

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
    [] s = "zero_gas_share" ->    \* two calls, static 0 + weight 1, share a leftover of 1 Ggas.
         \* nearcore gives each 0.5 Ggas: the creator commits, both run out of gas.  "up": each
         \* gets floor(1/2) = 0 Ggas but has a share, so the same.  "nearest": the first gets
         \* 0 Ggas and fails the creator (the last gets 1).
         \* receipt_manager.rs:679-719, action_validation.rs:350-351
         IF NearFeeTable!FeeRounding = "up"
         THEN ran = {<<1, C, "spawn0">>} /\ oog = {<<1, "work">>}
         ELSE ran = {} /\ oog = {}
    [] s = "zero_gas_left0" ->    \* one call, static 0 + weight 1, and a model leftover of 0.
         \* nearcore's leftover is at least the model's (fees and burns are upper bounds): if it is
         \* 0 the call has 0 gas and fails the creator; if it is 0.5 Ggas the call gets it, the
         \* creator commits and the call runs out of gas.  "up" keeps both; "nearest" fails it.
         \* receipt_manager.rs:686-716, action_validation.rs:350-351, lib.rs:968-978
         IF NearFeeTable!FeeRounding = "up"
         THEN \/ ran = {} /\ oog = {}
              \/ ran = {<<1, C, "spawn0">>} /\ oog = {<<1, "work">>}
         ELSE ran = {} /\ oog = {}
    [] s = "zero_gas_heavy" ->    \* two calls, static 0, weights 1 and 10^9, share a leftover
         \* of 1 Ggas.  With exactly 1 Ggas nearcore gives [0, 10^9] gas units and the first fails
         \* the creator; with 1.5 Ggas it gives the first 1 unit and the creator commits.  "up"
         \* keeps both; "nearest" (the first gets 0 Ggas) fails the creator.
         \* receipt_manager.rs:701-716, host.rs:3501-3503, action_validation.rs:350-351
         IF NearFeeTable!FeeRounding = "up"
         THEN \/ ran = {} /\ oog = {}
              \/ ran = {<<1, C, "spawn0">>} /\ oog = {<<1, "work">>}
         ELSE ran = {} /\ oog = {}
    [] s = "zero_gas_split" ->    \* static 0 + weight 1 with a model leftover of 0: 0 gas fails
         \* the creator; under "up" nearcore's leftover may be larger, so tx 1 may also commit and
         \* its ft_on_transfer run out of gas (as zero_gas_left0).  With 1 Ggas left the child runs
         \* and runs out.
         \* action_validation.rs:350-351, gas_counter.rs:155-174
         LET c1 == <<1, "ft_on_transfer">> \in oog IN
         /\ c1 => NearFeeTable!FeeRounding = "up"
         /\ oog \ {<<1, "ft_on_transfer">>} = {<<2, "ft_on_transfer">>}
         /\ seen = {} /\ L.bal[U] = 5 /\ L.bal[D] = 0 /\ near[FT] = IF c1 THEN 12 ELSE 11
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

    \* v0.2.  GV(g): the gas value in gas mode, 0 in fault mode (GasOf of an ungassed receipt).
    [] s = "and_order" ->         \* one callback, results in promise_and order whatever the
         \* arrival order, Failed and Successful mixed, r.res is JointMark; the callback's
         \* gas is its static 1000 + the leftover 10000 - 500 - 2 x 2000 - 1000
         \* lib.rs:861-899, :1646-1712; receipt_manager.rs:679-721
         seen = {S1("work", GV(2000)), S1("nres", 2), S1("res:fail", 0), S1("r1:fail", 0),
                 S1("r2:num", 1), S1("jgas", GV(5500))}
    [] s = "and_zero_cb" ->       \* a joint callback with 0 gas fails its creator
         \* action_validation.rs:350-351, applied at lib.rs:968-978
         seen = {} /\ post = {} /\ oog = {}
    [] s = "and_starved_leg" ->   \* one input out of gas: Failed at its position only
         \* lib.rs:1172-1176; static 1000 + 10000 - 500 - 2000 - 200 - 1000
         seen = {S1("work", 2000), S1("nres", 2), S1("res:fail", 0), S1("r1:num", 1),
                 S1("r2:fail", 0), S1("jgas", 7300)} /\ oog = {<<1, "work">>}
    [] s = "resume_twice" ->      \* resume returns 1 until the callback runs; the callback
         \* runs once, with the first resume to arrive; a later one returns 0
         \* ext.rs:406-430, lib.rs:1616-1622.  Gas: static 500 + 10000 - 400 - 500
         /\ \E v \in {5, 6} : S1("ycb", v) \in seen
         /\ S2("ans", 1) \in seen
         /\ (S(3, "ans", 0) \in seen => S1("ycb", 5) \in seen)
         /\ Cardinality({x \in seen : x.tag = "ycb"}) = 1
         /\ S1("ygas", GV(9600)) \in seen
    [] s = "resume_same_call" ->  \* yield and two resumes in one call: one wins
         \* ext.rs:365-370, :406-430
         \E v \in {5, 6} : seen = {S1("ycb", v), S1("ygas", GV(9600))}
    [] s = "timeout_then_resume" -> \* past the deadline the callback gets Failed (it panics,
         \* reverting only itself); a resume after it returns 0.  lib.rs:3113-3221, ext.rs:406-430
         seen = {S1("y", 2), S(3, "ans", 0)} /\ post = {}
    [] s = "resume_beats_timeout" -> \* a resume in flight at the deadline still wins
         \* lib.rs:1555-1563
         S1("ycb", 5) \in seen
    [] s = "resume_other_acct" -> \* only the yielding account can resume
         \* ext.rs:410-417 (keyed by the current account)
         S2("ans", 0) \in seen /\ post = {} /\ ~\E x \in seen : x.tag = "ycb"
    [] s = "yield_returned" ->    \* a returned yield: the caller's callback gets the yield
         \* callback's value.  lib.rs:1152-1168
         S1("dcb:num", 5) \in seen
    [] s = "yield_zero_cb" ->     \* a yield callback with 0 gas fails its creator
         \* verifier.rs:711-717, action_validation.rs:350-351
         seen = {} /\ post = {}
    [] s \in {"yield_id_recreate", "yield_id_recreate_timeout"} ->
         \* a custom-id callback (resumed, or timed out) may re-create its own id: the
         \* yield, its status and the id mapping are removed before it runs
         \* lib.rs:1572-1591, :903; ext.rs:375-385
         /\ seen = {S1("yid", 1), S1("reyid", 1)}
                   \cup (IF s = "yield_id_recreate" THEN {S2("ans", 1)} ELSE {})
         /\ {YidOf(p) : p \in post} = {7} /\ Cardinality(post) = 1
    [] s = "yield_id_same_call" -> \* a second create_with_id of a pending id in the same call
         \* is a duplicate: u64::MAX, nothing created.  ext.rs:380-385, host.rs:4391-4399
         seen = {S1("yid", 1), S1("yid2", 0)} /\ Cardinality(post) = 1

    \* Delegate actions (NEP-366).  TxsSeen: the transactions that recorded something.
    [] s = "deleg_ok" ->          \* the inner call's predecessor is the user, its signer (and
         \* every child's) the relayer with the relayer's key; the relayer pays the deposit;
         \* the nonce is the delegate's.  actions.rs:500-512, :729-733; function_call.rs:172-174;
         \* config.rs:652-668
         /\ seen = {S1("who:c<-d signer u/ku", GV(10000)), S1("who:d<-c signer u/ku", GV(9700))}
         /\ near[W] = 12 /\ near[U] = 8 /\ near[D] = 0 /\ sigpaid[U] = 2 /\ sigpaid[D] = 0
         /\ KeyNonce(D, "k0") = 2
    [] s = "deleg_replay" ->      \* a nonce at or below the key's fails the outer receipt; its
         \* deposit goes back to the relayer, its predecessor; nonces may skip.
         \* actions.rs:648-657; lib.rs:1295-1303, :1402-1406; receipt.rs:428-430
         TxsSeen = {1, 3} /\ near[U] = 8 /\ near[C] = 7 /\ KeyNonce(D, "k0") = 5
    [] s = "deleg_expired" ->     \* block height > max_block_height fails; the bound is
         \* inclusive; a failed delegate leaves the nonce.  actions.rs:479-482, :729-733
         TxsSeen = {1, 4} /\ near[U] = 8 /\ KeyNonce(D, "k0") = 2 /\ blk = 1
    [] s = "deleg_inner_fail" ->  \* the inner call fails: its deposit goes to the user (the
         \* inner predecessor), not to the relayer who paid it.  actions.rs:514-519, receipt.rs:428-430
         near[D] = 2 /\ near[U] = 8 /\ near[C] = 5 /\ ran = {} /\ KeyNonce(D, "k0") = 1
    [] s = "deleg_fc_key" ->      \* a function-call key signs one zero-deposit call to its
         \* receiver and methods, as for a transaction.  actions.rs:670-727
         /\ ran = {<<1, C, "ping">>, <<5, C, "pong">>} /\ near[U] = 10
         /\ KeyNonce(C, "k1") = 1 /\ KeyNonce(C, "k2") = 1
    [] s = "deleg_fc_relayer" ->  \* a function-call key cannot sign the relayer's transaction:
         \* a Delegate is not a function call.  verifier.rs:213-222
         acc = <<FALSE, TRUE>> /\ ran = {<<2, C, "ping">>} /\ sigpaid[C] = 1
    [] s = "deleg_checks" ->      \* the key must exist when the outer receipt runs; so must the
         \* sender.  actions.rs:587-602, :861-886
         TxsSeen = {1} /\ ~\E x \in ran : x[3] = "pong" /\ DOMAIN keys[C] = {"k0", "k1"} /\ near[U] = 10

    \* Per-byte storage.  Liquid + locked must cover the bytes after the receipt, at most 770
    \* bytes always pass; LackBalanceForState fails and reverts the whole receipt.
    \* lib.rs:1008-1031, verifier.rs:48-90
    [] s = "stor_grow" ->         \* growth within the balance commits, the boundary inclusive;
         \* one byte more fails; an attached deposit counts.  host.rs:5062-5070
         stor[V] = 1001 /\ near[V] = 11 /\ near[U] = 9
         /\ seen = {S1("put", 100), S(3, "put", 1)}
    [] s = "stor_revert" ->       \* growth beyond the balance fails the receipt: no bytes, no
         \* Transfer, no callback, the deposit refunded; a callback on it sees Failed.
         \* lib.rs:1008-1031, :1078-1088, :1172-1176
         stor[V] = 900 /\ near[V] = 10 /\ near[U] = 10 /\ stor[D] = 700
         /\ seen = {S2("fail", 0), S2("sz", 0)} /\ <<2, D, "work">> \notin ran
    [] s = "stor_shrink" ->       \* a spend below the cover fails; freeing bytes lowers it.
         \* host.rs:5198-5208
         stor[V] = 800 /\ near[V] = 8 /\ near[U] = 12
    [] s = "stor_zero_balance" -> \* NEP-448: at most 770 bytes need no balance.
         \* verifier.rs:25, :77-79, :88-90
         stor[D] = 770 /\ seen = {S1("put", 70)}
    [] s = "stor_locked" ->       \* locked counts: 3 liquid + 5 locked cover 800 bytes.
         \* verifier.rs:64-74
         stor[V] = 800 /\ near[V] = 3 /\ locked = 5 /\ near[U] = 11
    [] s = "stor_keys" ->         \* a function-call key (c, {ping}) is 109 bytes with a 10-byte
         \* receiver id, (c, any) 101: AddKey over the cover fails, DeleteKey frees, a bundled
         \* [AddKey, call] is checked once, at the end.  access_keys.rs:17-29, :136-147, :240-252
         DOMAIN keys[C] = {"k0", "k1", "k3"} /\ stor[C] = 708
         /\ S1("fail", 0) \in seen /\ S2("empty", 0) \in seen /\ S(3, "empty", 0) \in seen
         /\ ~\E x \in ran : x[3] = "kbundle"
    [] s = "stor_implicit" ->     \* an eth-implicit account created by a Transfer: 100 + 32 bytes
         \* actions.rs:255-269
         created = {E1} /\ stor[E1] = 132
    [] s = "stor_signer" ->       \* a transaction whose deposit would leave the signer uncovered
         \* is refused.  verifier.rs:375-386
         acc = <<FALSE, TRUE>> /\ near[V] = 9 /\ near[C] = 6
    [] s = "stor_tokens" ->       \* a registration adds its holder's TokRegBytes (w 180, u 150),
         \* kept from the deposit; unregistering frees them.  storage_impl.rs:8-36, :51-78;
         \* core_impl.rs:51-57
         stor[FT] = 1180 /\ L.reg = {U, C, D, W} /\ near[FT] = 12 /\ near[U] = 8

    \* Account lifecycle (docs/SEMANTICS.md A6, A7; sim: conformance/tests/lifecycle.rs).
    \* A failed ACCOUNT receipt fails as a whole: its deposit goes back to its predecessor.
    [] s = "acct_create" ->       \* a factory creates s.c (it starts at 0 and gets the deposit);
         \* a second create fails AccountAlreadyExists: the deposit returns to the factory, the
         \* callback sees Failed.  actions.rs:202-208, :822-828; lib.rs:1303, :1172-1176
         created = {SB} /\ near[SB] = 1 /\ near[C] = 4 /\ near[U] = 10
         /\ S1("empty", 0) \in seen /\ S2("fail", 0) \in seen
    [] s = "acct_keys" ->         \* [CreateAccount, Transfer, AddKey..] is atomic: a duplicate key
         \* fails it all.  lib.rs:946-1005, access_keys.rs:158
         created = {SB} /\ DOMAIN keys[SB] = {"k0", "k1"} /\ near[SB] = 2 /\ near[C] = 3
    [] s = "acct_not_parent" ->   \* only the direct parent creates a sub-account, not even the
         \* TopCreator.  actions.rs:190-197
         created = {} /\ near[U] = 10 /\ near[W] = 10
    [] s = "acct_implicit" ->     \* implicit ids (NEAR, eth, universal) only by a Transfer
         \* actions.rs:829-840
         created = {} /\ near[U] = 10
    [] s = "acct_top" ->          \* a top-level id only by the registrar_account_id (TopCreator)
         \* actions.rs:175-186
         created = {TL} /\ near[TL] = 1 /\ near[W] = 9 /\ near[U] = 10
    [] s = "acct_fee" ->          \* creator-side fees (gas mode, "up"): [CreateAccount, Transfer,
         \* AddKey(full)] costs what a NEAR-implicit Transfer costs; [DeleteAccount] 218 + 296.
         \* config.rs:98-108, :143
         LET r1 == WithAcctKeys(CreateAcctRcpt(0, 0, SB, C, G0, 1, 0), <<AddKeyAct("k0", FullPerm)>>)
             r2 == DeleteAcctRcpt(0, 0, W, G0, U, 0)
             \* A8: a call receipt's account actions add their send + exec fees to the call's.
             c0 == Rcpt(0, 0, SB, C, "init", G0, 1, C, 0)
             c1 == WithCreate(c0)
             c2 == WithDeleteTo(Rcpt(0, 0, C, C, "last", G0, 0, C, 0), U)
             \* A9: [DeployContract] of 1000 bytes ("big") on w by w; the same in a factory batch.
             d0 == DeployRcpt(0, 0, W, G0, "big", 0)
             c3 == WithDeploy(c1, "big") IN
         GasMode = "gas" =>
           /\ r1.gf = NearFeeTable!TransferFeeTotal(FALSE, "near_implicit")
           /\ c1.gf = c0.gf + NearFeeTable!ActionFee("create_account", FALSE, "named")
                             + NearFeeTable!ActionFee("transfer", FALSE, "named")
           /\ NearFeeTable!FeeRounding = "up" =>
                /\ r1.gf = 8354 /\ r2.gf = 514
                /\ c1.gf - c0.gf = 7700 + NearFeeTable!ActionFee("transfer", FALSE, "named")
                /\ c2.gf - Rcpt(0, 0, C, C, "last", G0, 0, C, 0).gf = 296
                \* receipt base 218, deploy_base 370, 1000 bytes 72 (same account) or 113
                /\ d0.gf = 660 /\ c3.gf - c1.gf = 370 + 113
    [] s = "del_beneficiary" ->   \* only the account deletes itself; its balance goes to the
         \* beneficiary in a later receipt.  actions.rs:776-783, :380-386
         deleted = {W} /\ near[W] = 0 /\ near[U] = 20 /\ near[C] = 5 /\ burnt = 0
    [] s = "del_absent" ->        \* the payout to a missing beneficiary is burnt; no account is
         \* created.  lib.rs:1046-1054
         deleted = {W} /\ burnt = 10 /\ created = {}
    [] s = "del_self" ->          \* beneficiary = the account: deleted by the time the payout
         \* runs, so it is burnt
         deleted = {W} /\ burnt = 10 /\ near[W] = 0
    [] s = "del_staking" ->       \* an account with locked balance cannot be deleted
         \* actions.rs:784-790
         deleted = {} /\ locked = 4 /\ near[V] = 6
    [] s = "del_receipts" ->      \* a deleted account: a call fails (deposit back), a Transfer
         \* fails (back to the sender, its callback sees Failed), it cannot sign; keys gone.
         \* actions.rs:842-849, :862-879; verifier.rs:170-175; core/store/src/utils/mod.rs:504-575
         deleted = {D} /\ DOMAIN keys[D] = {} /\ near[D] = 0 /\ near[U] = 10 /\ near[C] = 5
         /\ acc = <<TRUE, TRUE, TRUE, FALSE>> /\ S(3, "fail", 0) \in seen /\ <<2, D, "foo">> \notin ran
    [] s = "recreate" ->          \* deleted, then created again: a new account with no keys
         \* actions.rs:202-208
         created = {SB} /\ deleted = {} /\ DOMAIN keys[SB] = {} /\ near[SB] = 1 /\ near[C] = 4
    [] s = "implicit_recreate" -> \* a Transfer creates a deleted NEAR-implicit account again,
         \* with its full-access key.  actions.rs:221-240, :929-946
         created = {NI} /\ deleted = {} /\ keys[NI] = (ImplicitKeyId :> FullPerm)
         /\ near[NI] = 1 /\ near[U] = 11 /\ near[C] = 3
    [] s = "stale_cb_recreate" -> \* D4: a yield outlives its account's deletion; the account
         \* created again (0xa keeps its global contract) resumes it and the callback runs there.
         \* core/store/src/utils/mod.rs:504-575; ext.rs:406-428
         deleted = {} /\ EA \in created /\ near[EA] = 1 /\ post = {}
         /\ S1("ycb", 5) \in seen /\ S(4, "ans", 1) \in seen
    \* Call receipts with account actions (docs/SEMANTICS.md A8).
    [] s = "accall_nocode" ->     \* [CreateAccount, Transfer, FunctionCall(init)]: the new account has
         \* no code, so init fails and the batch with it; the deposit goes back to c, the callback
         \* sees Failed.  actions.rs:202-208; function_call.rs:309-312; lib.rs:946-1005
         created = {} /\ near[C] = 5 /\ S1("fail", 0) \in seen /\ <<1, SB, "init">> \notin ran
    [] s = "accall_delete" ->     \* [FunctionCall, DeleteAccount] on c by c: the call runs, then the
         \* delete; the payout to u.  actions.rs:776-783, :380-386
         deleted = {C} /\ near[C] = 0 /\ near[U] = 15 /\ DOMAIN keys[C] = {} /\ S1("last", 1) \in seen
    [] s = "accall_actor" ->      \* the same on d by c: ActorNoPermission, before the call runs
         deleted = {} /\ near[D] = 0 /\ <<1, D, "last">> \notin ran
    [] s = "accall_init" ->       \* CallsNeedCode = FALSE: the batch commits; init runs on s.c, which
         \* has the deposit and the key; the callback sees init's value.  actions.rs:202-208
         created = {SB} /\ near[SB] = 2 /\ near[C] = 3 /\ keys[SB] = ("k0" :> FullPerm)
         /\ S1("init", 1) \in seen /\ S1("num", 7) \in seen
         \* init's attached deposit is its own, 0, not the Transfer's 2.  function_call.rs:273
         /\ S1("idep", 0) \in seen
         \* ... but its balance includes the Transfer.  function_call.rs:269; logic.rs:45-49
         /\ S1("ibal", 2) \in seen
    [] s = "accall_exists" ->     \* AccountAlreadyExists comes first: init does not run
         \* actions.rs:822-828
         near[SB] = 1 /\ near[C] = 4 /\ S2("fail", 0) \in seen /\ <<2, SB, "init">> \notin ran
    [] s = "accall_recreate" ->   \* a deleted id created again by a factory batch: the call sees the
         \* new account (not AccountDoesNotExist); no keys
         created = {SB} /\ deleted = {} /\ near[SB] = 2 /\ near[C] = 3 /\ DOMAIN keys[SB] = {}
         /\ <<3, SB, "init">> \in ran
    [] s = "accall_create_del" -> \* [CreateAccount, Transfer, FunctionCall(init), DeleteAccount(c)]:
         \* the result is the delete's, empty bytes, not init's 7; the 2 NEAR come back as payout.
         \* lib.rs:507-513, :1172-1175
         created = {SB} /\ deleted = {SB} /\ near[C] = 5 /\ S1("init", 1) \in seen
         /\ S1("empty", 0) \in seen /\ S1("num", 7) \notin seen
    [] s = "accall_not_parent" -> \* d is not s.c's parent: CreateAccountNotAllowed.  actions.rs:190-197
         created = {} /\ S1("fail", 0) \in seen
    [] s = "accall_bytes" ->      \* the new account's bytes: 100 + its key 82 + init's 0
         created = {SB} /\ stor[SB] = 182 /\ near[SB] = 1
    [] s = "accall_lackstate" ->  \* 100 + 1000 bytes on 0 balance: LackBalanceForState, all reverted.
         \* lib.rs:1008-1031
         created = {} /\ stor[SB] = 0 /\ near[C] = 5 /\ S1("fail", 0) \in seen
    \* DeployContract (docs/SEMANTICS.md A9; sim: lifecycle.rs deploy_storage_delta).
    [] s = "deploy_self" ->       \* w deploys code to itself; a call then runs.  actions.rs:290-328
         code = (W :> "wc") /\ HasCode(W) /\ <<2, W, "foo">> \in ran /\ near[W] = 11 /\ near[U] = 9
    [] s = "deploy_actor" ->      \* only the account deploys to itself: ActorNoPermission.
         \* actions.rs:755-776
         DOMAIN code = {} /\ CodeOf(C) = "code" /\ near[U] = 10 /\ acc = <<TRUE>>
    [] s = "deploy_init" ->       \* the factory batch with DeployContract: init finds code
         \* (CallsNeedCode = TRUE) and runs on s.c.  actions.rs:202-208, :290-328
         created = {SB} /\ code = (SB :> "child") /\ near[SB] = 2 /\ near[C] = 3
         /\ S1("init", 1) \in seen /\ S1("num", 7) \in seen
    [] s = "deploy_recreate" ->   \* deleted with its code; created again it has none, so the call
         \* fails.  core/store/src/utils/mod.rs:504-510
         created = {SB} /\ deleted = {} /\ DOMAIN code = {} /\ ~HasCode(SB) /\ near[SB] = 1
         /\ near[C] = 4 /\ near[U] = 10 /\ <<4, SB, "foo">> \notin ran /\ acc = <<TRUE, TRUE, TRUE, TRUE>>
    [] s = "deploy_bytes" ->      \* 100 + key 82 + code 1000 bytes
         created = {SB} /\ code = (SB :> "big") /\ stor[SB] = 1182 /\ near[SB] = 1
    [] s = "deploy_replace" ->    \* usage - old code + new code; data kept: 10,500 - 600 + 1000,
         \* then - 1000 + 10.  actions.rs:300-310, :426-451
         code = (V :> "tiny") /\ stor[V] = 9910
    [] s = "deploy_del_large" ->  \* after the deploy v holds 10,900 bytes, 1000 of them code: 9,900
         \* besides it, so the delete passes (with the initial 600 it would not).  actions.rs:342-369
         deleted = {V} /\ DOMAIN code = {} /\ near[U] = 20
    [] s = "deploy_del_same" ->   \* the same in one receipt: the delete subtracts the new code
         deleted = {V} /\ DOMAIN code = {} /\ near[U] = 20
    [] s = "deploy_lackstate" ->  \* 10,001 + 10,000 bytes need more than w's 10 NEAR: the deploy
         \* fails LackBalanceForState, nothing changes.  lib.rs:1008-1031
         DOMAIN code = {} /\ stor[W] = 10001 /\ near[W] = 10 /\ acc = <<TRUE>>
    [] s = "eth_wallet_call" ->   \* a Transfer creates an eth-implicit account with the wallet
         \* contract, also one the model lists without code (outside Contracts).  actions.rs:255-268
         created = {E2} /\ CodeOf(E2) = EthWalletCode /\ <<2, E2, "foo">> \in ran /\ near[E2] = 2
    [] s = "eth_recreate_code" -> \* an eth-implicit account created again by a Transfer gets the
         \* protocol's wallet contract, not its earlier code (initial or deployed).
         \* actions.rs:255-268
         EA \in created /\ deleted = {} /\ DOMAIN code = {} /\ CodeOf(EA) = EthWalletCode
         /\ CodeOf(EA) # "code" /\ <<4, EA, "foo">> \in ran /\ near[EA] = 2
    [] s = "accall_prom" ->       \* [FunctionCall(lastp), DeleteAccount(u)]: lastp returns a
         \* promise; the receipt succeeds, its Transfer child runs, and d.cb gets the delete's
         \* empty bytes, not the promise's result.  lib.rs:507-514, :1146-1189
         deleted = {C} /\ near[U] = 15 /\ near[D] = 0 /\ S1("lastp", 1) \in seen /\ S1("empty", 0) \in seen
    [] s = "code_off_missing" ->  \* CallsNeedCode = FALSE: a missing receiver still fails the call
         \* (AccountDoesNotExist), as does an uninitialised universal one.  actions.rs:874-887
         near[U] = 10 /\ near[UA] = 2 /\ GH \notin created /\ <<1, GH, "foo">> \notin ran
         /\ <<3, UA, "foo">> \notin ran
    [] s = "accall_del_stor" ->   \* the call adds 5000 bytes and leaves c 1 NEAR (2000 bytes'
         \* worth), but the storage check is skipped for an account the receipt deletes.
         \* lib.rs:1008-1031, the skip at :1010
         deleted = {C} /\ stor[C] = 0 /\ near[U] = 15 /\ S1("last", 1) \in seen
    [] s = "universal_off" ->     \* before 87 a 0u id is named: created by CreateAccount, it is an
         \* ordinary account (no AccountNotInitialized): its key action, its delegate (signed with
         \* the key it added) and its delete succeed.  actions.rs:880-887, :918-924
         created = {UA} /\ deleted = {UA} /\ DOMAIN keys[UA] = {} /\ near[UA] = 0 /\ near[W] = 10
         /\ acc = <<TRUE, TRUE, TRUE, TRUE>> /\ <<3, C, "ping">> \in ran /\ burnt = 0
    \* Instant receipts (docs/SEMANTICS.md S5): a lone DeleteAccount made by a receipt runs
    \* right after it.  receipt.rs:468-491, lib.rs:1222-1224, :2747-2775
    [] s = "instant_close" ->     \* c's delete runs before d.relay, so c.probe finds c deleted
         \* (no "inst" clause: selftest_instant_off must fail on the probe alone)
         deleted = {C} /\ near[U] = 15 /\ <<1, D, "relay">> \in ran /\ <<1, C, "probe">> \notin ran
    [] s = "instant_payout" ->    \* the payout is a later refund receipt, not instant: d.seebal
         \* may run before or after it (both are reachable: selftest_payout_*)
         deleted = {C} /\ near[D] = 5 /\ S1("inst", 1) \in seen
         /\ (S1("bal", 0) \in seen \/ S1("bal", 5) \in seen)
    [] s = "instant_deleg" ->     \* a delegate's inner [DeleteAccount] is instant.  Sim:
         \* lifecycle.rs instant_delete_via_delegate
         deleted = {D} /\ S1("inst", 1) \in seen /\ DOMAIN keys[D] = {}
    [] s = "instant_deleg_local" -> \* also when the relayer is the user (a local creator)
         deleted = {D} /\ S1("inst", 1) \in seen
    [] s = "instant_tx" ->        \* a transaction's own [DeleteAccount] is not instant
         deleted = {W} /\ seen = {} /\ near[U] = 20
    [] s = "del_large" ->         \* storage minus code over 10,000 bytes: DeleteAccountWithLargeState
         \* actions.rs:342-369, account.rs:248
         deleted = {V} /\ stor[W] = 10001 /\ stor[V] = 0 /\ near[U] = 20 /\ near[W] = 10
    [] s = "acct_bytes" ->        \* a new account is 100 bytes, plus its full-access key (82)
         \* actions.rs:202-208, access_keys.rs:17-29
         created = {SB} /\ stor[SB] = 182 /\ near[SB] = 1 /\ near[C] = 4
    [] s = "acct_bytes_del" ->    \* deleted: no bytes, no keys, the balance back to c
         \* core/store/src/utils/mod.rs:504-575
         deleted = {SB} /\ stor[SB] = 0 /\ near[C] = 5 /\ DOMAIN keys[SB] = {}

Check == Done => Expect(scn)
\* zero_gas_left0, zero_gas_heavy: whether the creator (tx 1's spawn0) committed.  Under "up"
\* each is violated (both outcomes are reachable); runs.toml expects that.
CreatorNeverCommits  == Done => <<1, C, "spawn0">> \notin ran
CreatorAlwaysCommits == Done => <<1, C, "spawn0">> \in ran
\* instant_payout: whether d.seebal ran before the payout to d (selftest_payout_*: both are
\* reachable, the payout being an ordinary receipt).
PayoutBeforeSeen == Done => S1("bal", 5) \in seen
PayoutAfterSeen  == Done => S1("bal", 0) \in seen
NoNegDeposit == \A x \in rq \cup post : x.dep >= 0
Sane  == /\ NearConserved(Total0(scn)) /\ NoOrphans /\ NoNegDeposit /\ StorageCovered
         /\ TokSupplyOK /\ TokTypeOK
         /\ GasBounded(LAMBDA t : IF t <= Len(Script(scn)) THEN Script(scn)[t].gas ELSE 0)
=============================================================================
