-------------------------------- MODULE Arm --------------------------------
(***************************************************************************)
(* The clock horizon's final observation (ClockHorizonOK, SEMANTICS       *)
(* N-clock-horizon).  An invariant is read in every state, also in the     *)
(* state after the last clock-relevant step, at a height the steps do not  *)
(* record, so the bound must leave room for one more gap.                  *)
(*                                                                         *)
(* Contract A: arm(), which fails below height ArmFrom and otherwise       *)
(* records its height (at) and sets armed.  Safe says an armed contract    *)
(* never sees Lag blocks pass, i.e. armed => ~(blk - at >= Lag): a         *)
(* comparison of blk with a recorded height, read by an invariant.         *)
(*                                                                         *)
(* One transaction: the only clock-relevant step is arm's handler (n = 1). *)
(* T = max(ArmFrom, Lag), no yields.  With ArmFrom = Lag = YieldTicks = 1  *)
(* the bound n * max(T, YieldTicks) = 1 lets Safe pass at MaxBlk = 1, yet  *)
(* at MaxBlk = 2 the run 0 -> 1 -> arm (at = 1) -> 2 violates it.  The     *)
(* bound (n + 1) * max(T, YieldTicks) = 2 flags MaxBlk = 1.                *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS ArmFrom, Lag

VARIABLES armed, at, sent
mine == <<armed, at, sent>>
vars == <<platformVars, mine>>

U == "u"  A == "a"
Accts == {U, A}
PFloor == [x \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Out0 == Outcome({}, {}, RVal(0), 0, 0)

Send == /\ ~sent
        /\ Submit(Rcpt(nid, 1, A, U, "arm", [x |-> 0], 0, U, 0))
        /\ sent' = TRUE
        /\ UNCHANGED <<armed, at>>

\* arm() reads the height (env::block_height() is blk).
RunA(r) ==
    LET O == IF blk < ArmFrom THEN OErr(Out0, "too early") ELSE Out0 IN
    /\ Exec(r, O)
    /\ IF Ok(r, O) THEN armed' = TRUE /\ at' = blk ELSE UNCHANGED <<armed, at>>
    /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine ELSE RunA(r)

Init == /\ PlatformInit([x \in Accts |-> 0], {1})
        /\ armed = FALSE /\ at = 0 /\ sent = FALSE

Next == Send \/ Run \/ (BlockTick /\ UNCHANGED mine)
Spec == Init /\ [][Next]_vars

Safe      == armed => ~(blk - at >= Lag)
HorizonOK == ClockHorizonOK(1, IF ArmFrom > Lag THEN ArmFrom ELSE Lag)
=============================================================================
