-------------------------- MODULE MtResolverCases --------------------------
(***************************************************************************)
(* Fixed cases of Nep245's batch resolver and vector code, checked in the  *)
(* initial state of MtBatch (run mt_resolver_cases: RX holds 10 of t1, U   *)
(* holds U0 = 2 of each id).  The resolver is called directly, as the      *)
(* token's own callback, with token_ids and amounts of unequal lengths,    *)
(* which the transfer methods never pass: near-sdk-contract-tools 4.0.0    *)
(* compares the answer's length with amounts' and zips token_ids with      *)
(* amounts (core :552-564, :585-589; docs/SEMANTICS.md T5).  Also: the     *)
(* caps of a repeated id refunded to oneself, a zero transfer to oneself,  *)
(* and the vector code's length limit (one run each).                      *)
(***************************************************************************)
EXTENDS MtBatch

\* A Successful promise result carrying x, and the vector it decodes to.
R(x) == [ok |-> TRUE, v |-> x, sz |-> 0, len |-> 0]
Dec(x) == MtVecOf(R(x)).v
\* The resolver on (tids, amts) with result res: what it returns and U's
\* balances after it.
Res(tids, amts, res) ==
    LET r == [Rcpt(nid, 1, MT, MT, "mt_resolve_transfer",
                   [TA0 EXCEPT !.s = U, !.rc = RX, !.tids = tids, !.amts = amts], 0, MT, 0)
              EXCEPT !.res = res]
        O == MtHandle(r)
    IN [ret |-> Dec(O.ret.v), u1 |-> O.mtk[MT].bal[U]["t1"], u2 |-> O.mtk[MT].bal[U]["t2"]]

ResolverCases ==
    \* two ids, one amount: the answer of one entry counts; one entry refunded
    /\ Res(<<"t1", "t2">>, <<5>>, R(2)) = [ret |-> <<3>>, u1 |-> 4, u2 |-> 2]
    \* one id, two amounts: an answer of two entries counts; one entry refunded
    /\ Res(<<"t1">>, <<5, 3>>, R(MtVecCode(<<2, 0>>))) = [ret |-> <<3>>, u1 |-> 4, u2 |-> 2]
    \* one id, two amounts, an answer of one entry: all unused
    /\ Res(<<"t1">>, <<5, 3>>, R(2)) = [ret |-> <<0>>, u1 |-> 7, u2 |-> 2]
    \* one id twice, everything back: 5 then 3 out of RX's 10
    /\ Res(<<"t1", "t1">>, <<5, 3>>, R(MtVecCode(<<5, 3>>))) = [ret |-> <<0, 0>>, u1 |-> 10, u2 |-> 2]

VecCodes ==
    /\ Dec(MtVecCode(<<100, 20>>)) = <<100, 20>>
    /\ Dec(MtVecCode(<<1023, 0>>)) = <<1023, 0>>
    /\ Dec(MtVecCode(<<127, 5, 64>>)) = <<127, 5, 64>>
    /\ Dec(MtVecCode(<<>>)) = <<>>
    /\ Dec(MtVecCode(<<0, 0, 0, 0, 0, 0, 0, 1>>)) = <<0, 0, 0, 0, 0, 0, 0, 1>>
    /\ Dec(MtVecCode(<<7>>)) = <<7>>

\* Run mt_resolver_cases_self (MDev {"selfTransferCredits"}): the resolver
\* with U as both sender and receiver, U holding U0 = 2 of t1.  The caps
\* come from U's balance before any refund (2, then 0), and both refunds
\* credit U afterwards: <<2, 0>> refunded, U ends with 4 (core :573-599).
ResSelf(tids, amts, res) ==
    LET r == [Rcpt(nid, 1, MT, MT, "mt_resolve_transfer",
                   [TA0 EXCEPT !.s = U, !.rc = U, !.tids = tids, !.amts = amts], 0, MT, 0)
              EXCEPT !.res = res]
        O == MtHandle(r)
    IN [ret |-> Dec(O.ret.v), u1 |-> O.mtk[MT].bal[U]["t1"]]
SelfCases ==
    /\ ResSelf(<<"t1", "t1">>, <<2, 2>>, [R(0) EXCEPT !.ok = FALSE]) = [ret |-> <<0, 2>>, u1 |-> 4]
    /\ ResSelf(<<"t1">>, <<2>>, [R(0) EXCEPT !.ok = FALSE]) = [ret |-> <<0>>, u1 |-> 4]

\* Run mt_zero_self (MDev {"zeroAmountSkipped"}): a zero mt_transfer to
\* oneself is skipped before the sender = receiver check (core :796).
Xfer(fr, rc, amt) ==
    LET O == MtHandle(Rcpt(nid, 1, MT, fr, "mt_transfer", MtArgs(rc, "t1", amt, ""), TokYocto, fr, 0))
    IN [err |-> O.err, u1 |-> O.mtk[MT].bal[U]["t1"]]
ZeroSelf ==
    /\ Xfer(U, U, 0) = [err |-> "", u1 |-> 2]
    /\ Xfer(U, U, 1).err = "Sender and receiver should be different"

\* Run mt_vec_code_long: a vector of 16 entries stops TLC (Assert).
VecCodeLong == Dec(MtVecCode([i \in 1..16 |-> 0])) = [i \in 1..16 |-> 0]

Stay == UNCHANGED vars
=============================================================================
