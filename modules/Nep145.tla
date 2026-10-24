------------------------------- MODULE Nep145 -------------------------------
(***************************************************************************)
(* NEP-145 storage management for fungible-token contracts, and the token  *)
(* ledger state the FT modules share.                                      *)
(*                                                                         *)
(* One ledger per token account a \in TokenAccts:                          *)
(*   tk[a] = [bal |-> [TokHolders[a] -> Nat], reg |-> SUBSET, sup |-> Nat] *)
(* The ledger is the token contract's state: it is committed only when     *)
(* the token's receipt succeeds (Exec / Verdict), like any contract.       *)
(*                                                                         *)
(* storage_deposit(account_id, registration_only)  (NEP-145; the           *)
(* near-contract-standards FT implementation ignores registration_only):   *)
(*   account already registered -> whole deposit refunded to predecessor   *)
(*   otherwise deposit < min     -> panic                                  *)
(*   otherwise register; deposit - min refunded to predecessor             *)
(*   returns StorageBalance JSON (NONEMPTY)                                *)
(*   burn key "<t>.storage_deposit/registered" or "/new" when GasBurn has  *)
(*   it, else "<t>.storage_deposit" (PathKey)                              *)
(* Deviation "sdRefundToAccount": refunds go to account_id instead.        *)
(* storage_balance_of(account_id): Some(StorageBalance) is encoded as the  *)
(*   number `total` (= min), None (JSON null) as NONEMPTY.                 *)
(* storage_unregister(force)  1 yocto (near-contract-standards 5.29.1,     *)
(*   fungible_token/storage_impl.rs:8-36, :103-105):                       *)
(*   predecessor not registered     -> returns false                       *)
(*   balance > 0 and not force      -> panic                               *)
(*   otherwise unregister, burn its balance (total supply decreases) and   *)
(*   transfer min + 1 yocto to it (min + TokYocto: with TokYocto = 0 the   *)
(*   yocto is not modelled); returns true.                                 *)
(*   Both booleans are NONEMPTY bytes; ev.unreg / ev.unregBurnt say what   *)
(*   happened.  The NEP-141 resolver's burn path needs this method.        *)
(* Storage bytes (with StoragePerByte): a registration is the only change  *)
(* in a standard FT's storage (balances are fixed-width u128 values), so   *)
(* every token receipt declares TokRegBytes[t][h] bytes per holder h it    *)
(* registers and frees as many when h unregisters (TokOut's sb):           *)
(* storage_deposit, storage_unregister, near_deposit, and transfers under  *)
(* the "autoRegister" deviation, which adds bytes with no deposit.         *)
(***************************************************************************)
EXTENDS TokenCommon

CONSTANTS
    TokenAccts,      \* accounts running a standard FT contract (NEP-141 + NEP-145)
    TokHolders,      \* [TokenAccts -> SUBSET accounts]: who can ever hold a balance there
    TokStorageMin,   \* [TokenAccts -> Nat]: storage_balance_bounds.min (= max)
    TokDev,          \* [TokenAccts -> SUBSET Deviations]: selected non-standard behaviour
    TokCallReserve   \* [TokenAccts -> Nat]: gas mode, "reserve" shape only (Nep141
                     \* TokFtGasShape).  ft_transfer_call keeps this much
                     \* (GAS_FOR_FT_TRANSFER_CALL) and gives ft_on_transfer
                     \* static = prepaid - reserve; prepaid <= reserve panics.
                     \* Unused in the default "standard" shape.

VARIABLE tk

\* Storage bytes of holder h's registration at token t, TokRegBytes[t][h]
\* for h \in TokHolders[t] (used with StoragePerByte; overridable).
\* near-contract-standards stores a balance under prefix + borsh(AccountId)
\* as a u128: StdRegBytes(len(id)) = 1 + 4 + len(id) + 16 + 40 bytes for a
\* one-byte prefix (fungible_token/core_impl.rs:41-57).  The bytes depend on
\* the holder's real id: a registration and its removal move the same count,
\* and a short id takes fewer bytes than the deposit pays for.
\* storage_balance_bounds min is priced at the longest id, StdRegBytes(64) =
\* 125 bytes x 1e19 = 1.25e21 yocto (storage_impl.rs:107-111, measured at
\* init); TokStorageMin is that price, not a per-holder one.  Default 0: no
\* bytes.  Measured in the sim at ids of 8 and 64 bytes (conformance/tests/
\* semantics.rs, storage_std_registration_bytes); StorStd holds the same
\* line (storage_deposit/new, near_deposit/new: base 61, per 1).
StdRegBytes(idLen) == 1 + 4 + idLen + 16 + 40
TokRegBytes == [t \in TokenAccts |-> [h \in TokHolders[t] |-> 0]]
RegBytes(t, h) ==
    IF h \in DOMAIN TokRegBytes[t] THEN TokRegBytes[t][h]
    ELSE Assert(FALSE, <<"TokRegBytes has no entry for holder", t, h>>)
RegBytesSum(t, S) == FunSum([h \in S |-> RegBytes(t, h)], S)

\* Initial ledger helper: balances b (a function on TokHolders[a]), registered set.
Ledger(b, reg) ==
    [bal |-> b, reg |-> reg,
     sup |-> FunSum(b, DOMAIN b)]

----------------------------------------------------------------------------
(* Execution accumulator.  A token receipt is a sequence of actions (one,  *)
(* or several for a batch) folded over this record; the first error wins   *)
(* and the whole receipt fails (and reverts) as one.                       *)
TEv0 == [m |-> "", s |-> "", rc |-> "", moved |-> 0, call |-> FALSE,
         refund |-> 0, credited |-> FALSE,
         stoKept |-> 0, stoRefund |-> 0, stoTo |-> "", stoAcct |-> "",
         nd |-> 0, nw |-> 0, unreg |-> "", unregBurnt |-> 0]
\* ev is what the receipt did, for the calling model's per-tx ghosts:
\*   s, rc, moved   tokens moved s -> rc by ft_transfer[_call]
\*   call           a receiver call + resolver were created
\*   refund         resolver moved this much back rc -> s (credited = s registered,
\*                  else burnt)
\*   stoKept, stoRefund, stoTo, stoAcct   storage_deposit: kept for a new
\*                  registration of stoAcct / refunded natively to stoTo
\*   nd, nw         near_deposit / near_withdraw amounts (WNear)
\*   unreg, unregBurnt   storage_unregister: the account removed and the
\*                  tokens burnt with it
TAcc0(r) == [L |-> tk[r.to], n |-> nid, rd |-> {}, ps |-> {}, out |-> 0,
             ret |-> RVal(EMPTY), err |-> "", ev |-> TEv0, key |-> r.m, pa |-> <<>>]

\* Overridable: account a "batch" receipt per action (Tokens header).
\* TRUE (nearcore's behaviour): each call has its own gas and burn key
\* "<acct>.batch/<shape>#<method>".  FALSE: one pool, key "<acct>.batch/<shape>".
TokBatchPerAction == TRUE

\* Path-specific burn keys (gas mode): "<method>/<path>" when GasBurn has
\* "<acct>.<method>/<path>", else "<method>".  Paths: storage_deposit and
\* near_deposit "registered" (already registered) / "new" (registers);
\* ft_resolve_transfer "refund" (refund > 0) / "norefund".
PathKey(r, m, path) ==
    IF GasMode = "gas" /\ CallKey(r.to, m \o "/" \o path) \in DOMAIN GasBurn
    THEN m \o "/" \o path ELSE m
Live(acc) == acc.err = ""
AE(acc, e) == IF acc.err = "" THEN [acc EXCEPT !.err = e] ELSE acc

\* A native refund (Transfer action) from the token account.
TokRefund(acc, r, to, x) ==
    IF x = 0 THEN acc
    ELSE [acc EXCEPT !.rd = @ \cup {Rcpt(acc.n, r.tx, to, r.to, XFER, TA0, x, r.to, 0)},
                     !.n = @ + 1, !.out = @ + x]

YoctoAct(acc, dep) ==
    IF TokYocto > 0 /\ dep # TokYocto
    THEN AE(acc, "Requires attached deposit of exactly 1 yoctoNEAR") ELSE acc

\* Storage bytes a token receipt adds: the registered holders' bytes, less
\* the unregistered holders' bytes.
TokBytes(r, acc) ==
    IF StoragePerByte
    THEN RegBytesSum(r.to, acc.L.reg \ tk[r.to].reg) - RegBytesSum(r.to, tk[r.to].reg \ acc.L.reg)
    ELSE 0

\* Outcome record of a token receipt (gas burn key "acct.method[/path]", size 0).
TokOut(r, acc) ==
    [ready |-> acc.rd, post |-> acc.ps, ret |-> acc.ret, out |-> acc.out,
     ids |-> acc.n - nid, err |-> acc.err, gk |-> CallKey(r.to, acc.key), sz |-> 0,
     pa |-> IF TokBatchPerAction THEN acc.pa ELSE <<>>, sb |-> TokBytes(r, acc),
     tk |-> [tk EXCEPT ![r.to] = acc.L], ev |-> [acc.ev EXCEPT !.m = r.m]]

----------------------------------------------------------------------------
(* storage_deposit(acct0 = "" means predecessor) with attached x.          *)
SdAct(acc, r, acct0, x) ==
    LET a   == IF acct0 = "" THEN r.fr ELSE acct0
        to  == IF "sdRefundToAccount" \in TokDev[r.to] THEN a ELSE r.fr
        min == TokStorageMin[r.to]
    IN IF ~Live(acc) THEN acc
       ELSE IF a \notin DOMAIN acc.L.bal
            THEN Assert(FALSE, <<"storage_deposit for an account outside TokHolders", r.to, a>>)
       ELSE IF a \in acc.L.reg
            THEN [TokRefund(acc, r, to, x) EXCEPT !.ret = RVal(NONEMPTY),
                    !.ev.stoRefund = @ + x, !.ev.stoTo = to, !.ev.stoAcct = a,
                    !.key = PathKey(r, "storage_deposit", "registered")]
       ELSE IF x < min
            THEN AE(acc, "The attached deposit is less than the minimum storage balance")
       ELSE [TokRefund([acc EXCEPT !.L.reg = @ \cup {a}], r, to, x - min)
               EXCEPT !.ret = RVal(NONEMPTY), !.ev.stoKept = @ + min,
                      !.ev.stoRefund = @ + (x - min), !.ev.stoTo = to, !.ev.stoAcct = a,
                      !.key = PathKey(r, "storage_deposit", "new")]

\* storage_balance_of(acct): Some(total) is encoded as the number, null as NONEMPTY.
SbAct(acc, r, acct0) ==
    LET a == IF acct0 = "" THEN r.fr ELSE acct0 IN
    [acc EXCEPT !.ret = IF a \in acc.L.reg THEN RVal(TokStorageMin[r.to]) ELSE RVal(NONEMPTY)]

\* storage_unregister(force) by the predecessor (storage_impl.rs:8-36).
\* The 1-yocto check is the caller's (YoctoAct).
SuAct(acc, r, force) ==
    LET p == r.fr  L == acc.L  min == TokStorageMin[r.to] IN
    IF ~Live(acc) THEN acc
    ELSE IF p \notin L.reg THEN [acc EXCEPT !.ret = RVal(NONEMPTY)]       \* false
    ELSE IF L.bal[p] > 0 /\ ~force
         THEN AE(acc, "Can't unregister the account with the positive balance without force")
    ELSE [TokRefund([acc EXCEPT !.L = [L EXCEPT !.reg = @ \ {p}, !.bal[p] = 0,
                                               !.sup = @ - L.bal[p]]],
                    r, p, min + TokYocto)
            EXCEPT !.ret = RVal(NONEMPTY), !.ev.unreg = p, !.ev.unregBurnt = L.bal[p]]
=============================================================================
