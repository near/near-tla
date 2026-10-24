------------------------------ MODULE Factory ------------------------------
(***************************************************************************)
(* An account factory: one receipt creates, funds and initialises the     *)
(* account (docs/SEMANTICS.md, A6, A8).                                    *)
(*                                                                         *)
(* Users call F.create() with a deposit D.  F sends the factory batch      *)
(* [CreateAccount, Transfer(D), FunctionCall(init(user))] to the name      *)
(* (WithCreate) and chains its own on_create(user, D).  The batch is       *)
(* atomic: if any action fails (the name exists, F is not its parent) the  *)
(* account is not created, init does not run, and D returns to F, the      *)
(* batch's predecessor, not to the user (lib.rs:946-1005, :1303).  So F's  *)
(* callback must look at the result: on success it records the owner in   *)
(* its registry reg, on failure it returns D to the user.  It pays from    *)
(* its own balance: the callback may run before the batch's refund reaches *)
(* F (refunds are not ordered against other receipts, S4), so F keeps D in *)
(* reserve (Reserve; factory_no_reserve: without it the refund to the     *)
(* user fails when the callback runs first, UserFundsBack fails).          *)
(*                                                                         *)
(* The new account's code: the model has no DeployContract (N-deploy), so  *)
(* these runs set CallsNeedCode <- FALSE: init is assumed to find code.    *)
(*                                                                         *)
(* factory_cb_refunds: two users race for one name; the loser is repaid.   *)
(* factory_assumes_created: on_create keeps D on failure: the loser's     *)
(*   deposit stays in F (UserFundsBack fails).                             *)
(* factory_not_parent: F creates n.x, whose parent is x, and its on_create *)
(*   records the owner without looking at the result: every create fails  *)
(*   CreateAccountNotAllowed and reg names an owner of no account          *)
(*   (PaidImpliesAccount fails).                                           *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS
    Users,      \* who calls create
    Name,       \* the account F creates
    Refund,     \* on_create returns D to the user when the batch failed
    Checks,     \* on_create looks at the result (FALSE: records the owner, never refunds)
    Reserve     \* F's own balance at the start

VARIABLES reg, owner, sent
\* reg: F's registry (name -> user, or ""); owner: each created account's
\* own state, set by its init; sent: users who have called create
mine == <<reg, owner, sent>>
vars == <<platformVars, mine>>

F == "f"  U1 == "u1"  U2 == "u2"  N == "n.f"  X == "n.x"
Names   == {N, X}
Accts   == {F, U1, U2, N, X}
FParents == Parents({<<N, F>>, <<X, "x">>})   \* n.f is F's sub-account, n.x is x's
D       == 2
TxIds   == 1..2
Near0   == [a \in Accts |-> CASE a \in {U1, U2} -> 10 [] a = F -> Reserve [] OTHER -> 0]
Total0  == 20 + Reserve
Floor0  == [a \in Accts |-> 0]
FCode   == {F}
NoTable == [x \in {} |-> 0]
Out0    == Outcome({}, {}, RVal(0), 0, 0)
TxOf(u) == IF u = U1 THEN 1 ELSE 2

\* F's create: the factory batch to Name, then self.on_create(user, D).
Create(r) ==
    LET batch == WithCreate(Rcpt(nid, r.tx, Name, F, "init", [u |-> r.fr], r.dep, F, nid + 1))
        cb    == Rcpt(nid + 1, r.tx, F, F, "on_create", [u |-> r.fr, d |-> r.dep], 0, F, 0)
    IN Outcome({batch}, {cb}, RVal(0), r.dep, 2)
\* F's on_create: [O |-> outcome, reg |-> registry after it].
OnCreate(r) ==
    LET u == r.a.u  d == r.a.d IN
    IF ~Checks THEN [O |-> Out0, reg |-> [reg EXCEPT ![Name] = u]]
    ELSE IF ~IsFailed(r.res) THEN [O |-> Out0, reg |-> [reg EXCEPT ![Name] = u]]
    ELSE IF Refund
         THEN [O |-> Outcome({Rcpt(nid, r.tx, u, F, XFER, [u |-> u], d, F, 0)}, {}, RVal(0), d, 1), reg |-> reg]
    ELSE [O |-> Out0, reg |-> reg]

RunF(r) ==
    IF r.m = "create" THEN
        /\ Exec(r, Create(r))
        /\ UNCHANGED mine
    ELSE LET h == OnCreate(r) IN
        /\ Exec(r, h.O)
        /\ reg' = IF Ok(r, h.O) THEN h.reg ELSE reg
        /\ UNCHANGED <<owner, sent>>
\* The batch (HasAc): Exec runs its CreateAccount and Transfer, then init on
\* the new account, which records its owner.
RunBatch(r) ==
    /\ Exec(r, Out0)
    /\ owner' = IF Ok(r, Out0) THEN [owner EXCEPT ![r.to] = r.a.u] ELSE owner
    /\ UNCHANGED <<reg, sent>>

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE IF HasAc(r) THEN RunBatch(r)
         ELSE RunF(r)

Call(u) == /\ u \in Users \ sent
           /\ Submit(Rcpt(nid, TxOf(u), F, u, "create", [u |-> u], D, u, 0))
           /\ sent' = sent \cup {u}
           /\ UNCHANGED <<reg, owner>>

Init == /\ PlatformInit(Near0, TxIds)
        /\ reg = [n \in Names |-> ""] /\ owner = [n \in Names |-> ""] /\ sent = {}
Next == Call(U1) \/ Call(U2) \/ Run
Spec == Init /\ [][Next]_vars

\* Once all is settled, a user has its deposit back unless it owns an account.
UserFundsBack ==
    Idle => \A u \in Users :
              near[u] = 10 - (IF \E n \in Names : AcctExists(n) /\ owner[n] = u THEN D ELSE 0)
\* F's registry names only owners of accounts that exist.
PaidImpliesAccount == \A n \in Names : reg[n] # "" => AcctExists(n) /\ owner[n] = reg[n]
Sane == NearConserved(Total0) /\ NoOrphans
=============================================================================
