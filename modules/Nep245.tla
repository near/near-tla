------------------------------- MODULE Nep245 -------------------------------
(***************************************************************************)
(* NEP-245 multi-token core as in-spec handlers on mtk[r.to].              *)
(*                                                                         *)
(* mt_transfer(receiver_id, token_id, amount)   1 yocto; returns EMPTY     *)
(* mt_batch_transfer(receiver_id, token_ids, amounts)  1 yocto; moves each *)
(*   id in order, atomically (one panic: nothing moves); token_ids and     *)
(*   amounts of different lengths panic; returns EMPTY                     *)
(* mt_transfer_call(receiver_id, token_id, amount, msg)  1 yocto; moves,   *)
(*   then receiver.mt_on_transfer(sender_id, [sender_id], [token_id],      *)
(*   [amount], msg).then(self.mt_resolve_transfer(...)); returns that.     *)
(* mt_batch_transfer_call(receiver_id, token_ids, amounts, msg)  the same  *)
(*   with the vectors (mt_on_transfer gets token_ids and amounts as given).*)
(* mt_resolve_transfer (private), NEP-245 :304-361: the receiver's result  *)
(*   is a Vec<U128> with one entry per amount.  Failed, unparsable, or of  *)
(*   a length other than Len(amounts) -> every id unused (unused_i =       *)
(*   amount_i); else unused_i = min(v_i, amount_i).  Per entry, in order,  *)
(*   for the first min(Len(token_ids), Len(amounts)) entries (the SDK     *)
(*   zips them; the transfer methods never pass unequal lengths):          *)
(*   refund_i = min(unused_i, the receiver's balance of id_i as it stands, *)
(*   after the refunds of earlier entries) back to the sender; returns    *)
(*   [amount_i - refund_i] for those entries.                              *)
(* Source: near-sdk-contract-tools 4.0.0, the only NEP-245 implementation  *)
(* read ("core" = src/standard/nep245/mod.rs, "macros" = the -macros       *)
(* crate's src/standard/nep245/mod.rs): the methods macros :71-209, the    *)
(* resolver macros :272-299, which reads the result unbounded              *)
(* (env::promise_result(0), :283; no byte limit, unlike NEP-141's 42       *)
(* bytes) and parses Vec<U128> (:285); core resolve_transfer :544-602     *)
(* (the length check :552-564, the per-id cap :566-596, one balance per    *)
(* id shared by repeated entries :573-593).                                *)
(* Panics the model adds for every transfer, as NEP-141 does (T1):         *)
(* sender = receiver, amount 0.  contract-tools checks neither (core       *)
(* :745-822): it skips a zero amount, and a transfer to oneself adds the   *)
(* amount to one's balance.  MtDev "zeroAmountSkipped" and                 *)
(* "selfTransferCredits" select those (TokenCommon; docs/SEMANTICS.md T5). *)
(*                                                                         *)
(* Result encoding.  mt_on_transfer and mt_resolve_transfer return a       *)
(* Vec<U128>; the platform's values are integers, so a vector travels as   *)
(* one (MtVecCode): a one-element ["v"] is the number v (what the single-  *)
(* id resolver reads), any other length a code <= -1000 that MtVecOf       *)
(* decodes; EMPTY, MAL, NONEMPTY are not vectors.  A code packs the        *)
(* entries at k bits each, k the fewest bits that hold the largest entry,  *)
(* so it fits TLC's integers when Len * k <= 21 and Len < 16: two entries  *)
(* up to 1023, three up to 127, seven up to 7 (a larger vector is an       *)
(* Assert, not a wrong value).  MtRet(vec) is a receiver's return value.   *)
(*                                                                         *)
(* Gas (gas mode), per token t, MtGasShape[t] (overridable definition):    *)
(*  "reserve" (default; recalled, not read): mt_on_transfer gets static    *)
(*      prepaid - MtCallReserve[t] and weight 0; prepaid <= reserve        *)
(*      panics; the resolver gets GasCall's entry for it, else nothing.    *)
(*  "tools" (near-sdk-contract-tools 4.0.0): prepaid < MtMinCallGas[t]     *)
(*      (30 Tgas: GAS_FOR_MT_TRANSFER_CALL, core :48-49) panics            *)
(*      "Insufficient gas attached." before the deposit check (macros      *)
(*      :146-151, :183-188); mt_on_transfer gets static 0 and weight       *)
(*      MtOnTransferWeight[t] (10, core :273), the resolver static         *)
(*      MtResolveStatic[t] (5 Tgas, GAS_FOR_MT_RESOLVE_TRANSFER, core :45, *)
(*      :283) and weight MtResolveWeight[t] (1, core :284); a GasCall      *)
(*      entry for the resolver wins.                                       *)
(* Neither depends on the number of ids: there is no per-id gas shape.     *)
(* Burn keys: "<t>.<method>"; the batch methods and the resolver burn      *)
(* with size = the number of ids (O.sz), so a calibrated per-id slope      *)
(* applies; the resolver uses "<t>.mt_resolve_transfer/refund" or          *)
(* "/norefund" when GasBurn has it.                                        *)
(*                                                                         *)
(* Deviations (MtDev): "resolveIgnoresResult", "resolveNoCap", per id.     *)
(* NEP-245 has no storage standard of its own; receivers need no           *)
(* registration here.                                                      *)
(*                                                                         *)
(* A contract that is itself a multi-token can use just the shared         *)
(* arithmetic ResolveRefund (TokenCommon) on its own ledger.               *)
(***************************************************************************)
EXTENDS TokenCommon

CONSTANTS
    MtAccts,        \* accounts running an external NEP-245 contract
    MtHolders,      \* [MtAccts -> SUBSET accounts]
    MtIds,          \* token ids
    MtDev,          \* [MtAccts -> SUBSET Deviations]
    MtCallReserve   \* [MtAccts -> Nat]: as TokCallReserve, for mt_transfer_call ("reserve" shape)

VARIABLE mtk        \* [MtAccts -> [bal |-> [MtHolders[a] -> [MtIds -> Nat]]]]

----------------------------------------------------------------------------
(* Vec<U128> results as integers (see the header).                         *)
\* Code = -(1000 + Len + 16 * (k + 32 * num)), num the entries at k bits
\* each (entry i at bit k * (i - 1)), Len < 16, 1 <= k <= 21, Len * k <= 21:
\* each field within its range, so the code is injective and fits TLC's
\* integers.
RECURSIVE MtVecBits(_, _), MtVecNum(_, _)
MtVecBits(m, k) == IF 2 ^ k > m THEN k ELSE MtVecBits(m, k + 1)
MtVecNum(s, k) == IF s = <<>> THEN 0 ELSE Head(s) + (2 ^ k) * MtVecNum(Tail(s), k)
MtVecMax(s) == IF s = <<>> THEN 0 ELSE CHOOSE x \in {s[i] : i \in DOMAIN s} : \A i \in DOMAIN s : s[i] <= x
MtVecCode(s) ==
    IF \E i \in DOMAIN s : s[i] < 0 THEN Assert(FALSE, <<"MtVecCode: a negative entry", s>>)
    ELSE IF Len(s) = 1 THEN s[1]
    ELSE IF Len(s) >= 16 THEN Assert(FALSE, <<"MtVecCode: 16 entries or more", s>>)
    ELSE IF MtVecMax(s) >= 2 ^ 21 THEN Assert(FALSE, <<"MtVecCode: an entry of 2^21 or more", s>>)
    ELSE LET k == MtVecBits(MtVecMax(s), 1) IN
         IF Len(s) * k > 21 THEN Assert(FALSE, <<"MtVecCode: Len * bits per entry over 21", s>>)
         ELSE -(1000 + Len(s) + 16 * (k + 32 * MtVecNum(s, k)))
\* The result as a vector: [ok |-> FALSE] when it is Failed or not a vector.
MtVecOf(res) ==
    IF ~res.ok THEN [ok |-> FALSE, v |-> <<>>]
    ELSE IF res.v >= 0 THEN [ok |-> TRUE, v |-> <<res.v>>]
    ELSE IF res.v <= -1000
         THEN LET c == -res.v - 1000  n == c % 16  y == c \div 16  k == y % 32  x == y \div 32 IN
              [ok |-> TRUE, v |-> [i \in 1..n |-> (x \div (2 ^ (k * (i - 1)))) % (2 ^ k)]]
    ELSE [ok |-> FALSE, v |-> <<>>]
MtRet(s) == RVal(MtVecCode(s))
\* Vectors of length n - 1, n and n + 1 with entries in V: every
\* well-formed answer of a receiver to n ids, wrong lengths included.
MtAnswers(n, V) == UNION {[1..k -> V] : k \in {k2 \in {n - 1, n, n + 1} : k2 >= 0}}

\* An arbitrary NEP-245 receiver (mt_on_transfer) answering to amounts amts:
\*   "keep" ["0",..]  "return" amts  "over" each + 1  "short" all but the
\*   last  "long" amts and "0"  "mal" MAL  "nonempty" NONEMPTY
\*   "empty" EMPTY  "panic" fails.
MtRecvResps == {"keep", "return", "over", "short", "long", "mal", "nonempty", "empty", "panic"}
MtRecvValue(amts, resp) ==
    CASE resp = "keep"     -> MtVecCode([i \in DOMAIN amts |-> 0])
      [] resp = "return"   -> MtVecCode(amts)
      [] resp = "over"     -> MtVecCode([i \in DOMAIN amts |-> amts[i] + 1])
      [] resp = "short"    -> MtVecCode(IF amts = <<>> THEN <<>> ELSE SubSeq(amts, 1, Len(amts) - 1))
      [] resp = "long"     -> MtVecCode(amts \o <<0>>)
      [] resp = "mal"      -> MAL
      [] resp = "nonempty" -> NONEMPTY
      [] resp = "empty"    -> EMPTY
      [] OTHER             -> 0
MtRecvOutcome(amts, resp) ==
    LET O == Outcome({}, {}, RVal(MtRecvValue(amts, resp)), 0, 0) IN
    IF resp = "panic" THEN OErr(O, "receiver panicked") ELSE O
\* A receiver answering exactly the vector s.
MtRecvVecOutcome(s) == Outcome({}, {}, MtRet(s), 0, 0)

----------------------------------------------------------------------------
\* Gas parameters (see the header).  Overridable definitions, e.g. in the
\* cfg `MtGasShape <- MyShapes` with MyShapes == [t \in {"mt"} |-> "tools"].
MtGasShape         == [t \in MtAccts |-> "reserve"]
MtMinCallGas       == [t \in MtAccts |-> 30000]
MtOnTransferWeight == [t \in MtAccts |-> 10]
MtResolveStatic    == [t \in MtAccts |-> 5000]
MtResolveWeight    == [t \in MtAccts |-> 1]
MtShape(t) == IF t \in DOMAIN MtGasShape THEN MtGasShape[t] ELSE "reserve"
MtTools(r) == MtShape(r.to) = "tools"

MEv0 == [m |-> "", s |-> "", rc |-> "", tid |-> "", moved |-> 0, call |-> FALSE, refund |-> 0,
         tids |-> <<>>, moves |-> <<>>, refunds |-> <<>>]
MAcc0(r) == [L |-> mtk[r.to], n |-> nid, rd |-> {}, ps |-> {}, out |-> 0,
             ret |-> RVal(EMPTY), err |-> "", ev |-> MEv0, key |-> r.m, sz |-> 0]
MLive(acc) == acc.err = ""
MAE(acc, e) == IF acc.err = "" THEN [acc EXCEPT !.err = e] ELSE acc
MYocto(acc, dep) ==
    IF TokYocto > 0 /\ dep # TokYocto THEN MAE(acc, "Requires attached deposit of exactly 1 yoctoNEAR") ELSE acc
\* "tools": the _call methods' gas floor, checked first (macros :146-149).
MGasFloor(acc, r) ==
    IF GasMode = "gas" /\ MtTools(r) /\ LastGas(r) < MtMinCallGas[r.to]
    THEN MAE(acc, "Insufficient gas attached.") ELSE acc
\* The burn key "<t>.<m>/<p>" when GasBurn has it, else "<t>.<m>".
MtPathKey(r, m, p) == IF CallKey(r.to, m \o "/" \o p) \in DOMAIN GasBurn THEN m \o "/" \o p ELSE m

\* x of id moved from s to rc on ledger L.  s = rc: nothing, or with
\* "selfTransferCredits" what contract-tools writes, the balance read
\* before the debit plus x (core :763-786).
MtMove(L, s, rc, id, x, dev) ==
    IF s # rc THEN [L EXCEPT !.bal[s][id] = @ - x, !.bal[rc][id] = @ + x]
    ELSE IF "selfTransferCredits" \in dev THEN [L EXCEPT !.bal[s][id] = @ + x]
    ELSE L

MtXferAct(acc, r, s, rc, tid, amt) ==
    LET L == acc.L  dev == MtDev[r.to] IN
    IF ~MLive(acc) THEN acc
    \* contract-tools drops zero entries before any other check (core :796)
    ELSE IF amt = 0 /\ "zeroAmountSkipped" \in dev THEN acc
    ELSE IF s = rc /\ "selfTransferCredits" \notin dev THEN MAE(acc, "Sender and receiver should be different")
    ELSE IF amt = 0 THEN MAE(acc, "zero amount")
    ELSE IF s \notin DOMAIN L.bal \/ rc \notin DOMAIN L.bal
         THEN Assert(FALSE, <<"MT transfer outside MtHolders", r.to, s, rc>>)
    ELSE IF L.bal[s][tid] < amt THEN MAE(acc, "insufficient balance")
    ELSE [acc EXCEPT !.L = MtMove(L, s, rc, tid, amt, dev),
                     !.ev.s = s, !.ev.rc = rc, !.ev.tid = tid, !.ev.moved = @ + amt,
                     !.ev.tids = @ \o <<tid>>, !.ev.moves = @ \o <<amt>>]

\* The batch: each id in order (core :791-822); unequal lengths panic
\* (core :110-142, macros :116-126).
MtBatchXferAct(acc, r, s, rc, tids, amts) ==
    IF ~MLive(acc) THEN acc
    ELSE IF Len(tids) # Len(amts) THEN MAE(acc, "Input arrays have inconsistent lengths.")
    ELSE LET F[i \in 0..Len(tids)] ==
                 IF i = 0 THEN acc ELSE MtXferAct(F[i - 1], r, s, rc, tids[i], amts[i])
         IN F[Len(tids)]

MtOnStatic(r) == IF GasMode = "gas" /\ ~MtTools(r) THEN LastGas(r) - MtCallReserve[r.to] ELSE 0
MtOnWeight(r) == IF MtTools(r) THEN MtOnTransferWeight[r.to] ELSE 0
MtReserveShort(r) == GasMode = "gas" /\ ~MtTools(r) /\ MtCallReserve[r.to] > 0 /\ LastGas(r) <= MtCallReserve[r.to]
\* "tools": the resolver gets MtResolveStatic and MtResolveWeight unless
\* GasCall has an entry for it; "reserve": GasCall's entry, if any.
MtResolveGas(r, res) ==
    IF GasMode # "gas" \/ ~MtTools(r) \/ HasCallDef(r.to, "mt_resolve_transfer") THEN res
    ELSE WithCall(res, <<MtResolveStatic[r.to]>>, <<MtResolveWeight[r.to]>>)

\* The resolver is owed (NearAsync WithOwed, docs/SEMANTICS.md F2), as
\* Nep141's: OwedOK checks that none fails.  MtOwedResolve <- FALSE leaves it
\* unmarked.
MtOwedResolve == TRUE

\* mt_[batch_]transfer_call after its transfer a1: mt_on_transfer with
\* onA, then the resolver with resA (core :264-287).
MtCallAct(a1, r, onA, resA) ==
    LET onT == WithCall(Rcpt(a1.n, r.tx, onA.rc, r.to, "mt_on_transfer", onA, 0, r.to, a1.n + 1),
                        <<MtOnStatic(r)>>, <<MtOnWeight(r)>>)
        res0 == Rcpt(a1.n + 1, r.tx, r.to, r.to, "mt_resolve_transfer", resA, 0, r.to, r.cb)
        res == MtResolveGas(r, IF MtOwedResolve THEN WithOwed(res0) ELSE res0)
    IN IF ~MLive(a1) THEN a1
       ELSE [a1 EXCEPT !.rd = @ \cup {onT}, !.ps = @ \cup {res}, !.n = @ + 2,
                       !.ret = RProm, !.ev.call = TRUE]

MtTransferCallAct(acc, r) ==
    LET a == r.a
        a1 == IF MtReserveShort(r) /\ MLive(acc) THEN MAE(acc, "prepaid gas overflow")
              ELSE MtXferAct(acc, r, r.fr, a.rc, a.tid, a.amt)
    IN MtCallAct(a1, r, MtOnArgs(r.fr, a.rc, a.tid, a.amt, a.msg), MtResArgs(r.fr, a.rc, a.tid, a.amt))

MtBatchTransferCallAct(acc, r) ==
    LET a == r.a
        a1 == IF MtReserveShort(r) /\ MLive(acc) THEN MAE(acc, "prepaid gas overflow")
              ELSE MtBatchXferAct(acc, r, r.fr, a.rc, a.tids, a.amts)
    IN MtCallAct(a1, r, MtBatchOnArgs(r.fr, a.rc, a.tids, a.amts, a.msg),
                 MtBatchResArgs(r.fr, a.rc, a.tids, a.amts))

MtResolveAct(acc, r) ==
    LET a == r.a  L == acc.L
        refund == ResolveRefund(r.res, a.amt, L.bal[a.rc][a.tid], MtDev[r.to])
        L1 == MtMove(L, a.rc, a.s, a.tid, refund, MtDev[r.to])
    IN IF ~MLive(acc) THEN acc
       ELSE IF r.fr # r.to THEN MAE(acc, "Method mt_resolve_transfer is private")
       ELSE [acc EXCEPT !.L = L1, !.ret = RVal(TMax(a.amt - refund, 0)),
                        !.ev.s = a.s, !.ev.rc = a.rc, !.ev.tid = a.tid, !.ev.refund = refund,
                        !.ev.tids = <<a.tid>>, !.ev.refunds = <<refund>>, !.sz = 1,
                        !.key = MtPathKey(r, "mt_resolve_transfer", IF refund > 0 THEN "refund" ELSE "norefund")]

\* The resolver of a batch: per entry, the shared arithmetic on that
\* entry of the result (ResolveRefund on the number v_i, or on Failed when
\* the result is not a vector of Len(amts) entries, core :552-564),
\* against a cap per id: the receiver's balance read before any refund,
\* less the refunds of earlier entries of that id (balance_map, :566-596),
\* for the first min(Len(tids), Len(amts)) entries (the zip, :585-589).
\* The ledger moves never feed back into the caps (contract-tools applies
\* them after every cap is taken, :597-599): for a receiver that is the
\* sender ("selfTransferCredits") a refund does not raise a later entry's
\* cap.
MtBatchResolveAct(acc, r) ==
    LET a == r.a  m == Len(a.amts)  n == TMin(Len(a.tids), m)  vec == MtVecOf(r.res)
        Res(i) == IF vec.ok /\ Len(vec.v) = m THEN [r.res EXCEPT !.v = vec.v[i]] ELSE [r.res EXCEPT !.ok = FALSE]
        Ids == {a.tids[i] : i \in 1..n}
        \* F[i]: [L, caps, refunds] after entries 1..i
        F[i \in 0..n] ==
            IF i = 0 THEN [L |-> acc.L, cap |-> [id \in Ids |-> acc.L.bal[a.rc][id]], rf |-> <<>>]
            ELSE LET L == F[i - 1].L  c == F[i - 1].cap  id == a.tids[i]
                     refund == ResolveRefund(Res(i), a.amts[i], c[id], MtDev[r.to])
                 IN [L |-> MtMove(L, a.rc, a.s, id, refund, MtDev[r.to]),
                     cap |-> [c EXCEPT ![id] = @ - refund],
                     rf |-> F[i - 1].rf \o <<refund>>]
        used == [i \in 1..n |-> TMax(a.amts[i] - F[n].rf[i], 0)]
    IN IF ~MLive(acc) THEN acc
       ELSE IF r.fr # r.to THEN MAE(acc, "Method mt_resolve_transfer is private")
       ELSE [acc EXCEPT !.L = F[n].L, !.ret = RVal(MtVecCode(used)),
                        !.ev.s = a.s, !.ev.rc = a.rc, !.ev.tids = SubSeq(a.tids, 1, n), !.ev.refunds = F[n].rf,
                        !.sz = Len(a.tids),
                        !.key = MtPathKey(r, "mt_resolve_transfer",
                                          IF \E i \in 1..n : F[n].rf[i] > 0 THEN "refund" ELSE "norefund")]

\* A resolver of a single-id call has a.tids = <<a.tid>> and a.tid # "";
\* a batch's has a.tid = "".
IsMtBatchRes(r) == r.a.tid = ""

MtHandle(r) ==
    LET acc == MAcc0(r)  a == r.a
        f == CASE r.m = "mt_transfer"         -> LET b == MtXferAct(MYocto(acc, r.dep), r, r.fr, a.rc, a.tid, a.amt)
                                                 IN IF MLive(b) THEN [b EXCEPT !.ret = RVal(EMPTY)] ELSE b
               [] r.m = "mt_batch_transfer"   -> LET b == MtBatchXferAct(MYocto(acc, r.dep), r, r.fr, a.rc, a.tids, a.amts)
                                                 IN IF MLive(b) THEN [b EXCEPT !.ret = RVal(EMPTY), !.sz = Len(a.tids)]
                                                    ELSE [b EXCEPT !.sz = Len(a.tids)]
               [] r.m = "mt_transfer_call"    -> MtTransferCallAct(MYocto(MGasFloor(acc, r), r.dep), r)
               [] r.m = "mt_batch_transfer_call" ->
                    [MtBatchTransferCallAct(MYocto(MGasFloor(acc, r), r.dep), r) EXCEPT !.sz = Len(a.tids)]
               [] r.m = "mt_resolve_transfer" /\ ~IsMtBatchRes(r) -> MtResolveAct(acc, r)
               [] r.m = "mt_resolve_transfer" /\ IsMtBatchRes(r)  -> MtBatchResolveAct(acc, r)
               [] OTHER                       -> MAE(acc, "method not found")
    IN [ready |-> f.rd, post |-> f.ps, ret |-> f.ret, out |-> f.out,
        ids |-> f.n - nid, err |-> f.err, gk |-> CallKey(r.to, f.key), sz |-> f.sz,
        mtk |-> [mtk EXCEPT ![r.to] = f.L], ev |-> [f.ev EXCEPT !.m = r.m]]

IsMtRcpt(r) == r.to \in MtAccts /\ IsCall(r)

MtStep(r, O) ==
    /\ Exec(r, O)
    /\ mtk' = IF Ok(r, O) THEN O.mtk ELSE mtk

RECURSIVE MSum(_, _)
MSum(S, f) == IF S = {} THEN 0 ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + MSum(S \ {x}, f)
MtTotal(t, id) == MSum(DOMAIN mtk[t].bal, [h \in DOMAIN mtk[t].bal |-> mtk[t].bal[h][id]])
=============================================================================
