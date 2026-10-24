------------------------------ MODULE NearKeys ------------------------------
(***************************************************************************)
(* Access keys on top of NearAsync (the signer itself is in NearAsync).    *)
(*                                                                         *)
(*  1. Access keys.  keys[a] : key id -> permission                        *)
(*     Perm(rcv, ms, all): a function-call key for receiver rcv, methods   *)
(*     ms (any method if all, or if ms = {}); FullPerm: full access.       *)
(*     A function-call key may only sign a transaction with exactly one    *)
(*     action, a zero-deposit function call to its receiver with a         *)
(*     permitted method; an empty method list allows every method          *)
(*     (runtime/runtime/src/verifier.rs:209-250, :213, :223, :238).        *)
(*  2. SubmitSigned(r, a, k): a transaction signed by a with key k.  A     *)
(*     function-call key may carry an allowance (WithAllowance), charged   *)
(*     the transaction's cost at conversion and refused when short         *)
(*     (verifier.rs:282-303, NotEnoughAllowance); the gas refund adds back *)
(*     (actions.rs:133-157), here at conversion (WithTxCost).              *)
(*     SignedTx / SubmitTx: a transaction with a nonce, which must exceed  *)
(*     the key's (verifier.rs:254-280, InvalidNonce) and becomes the key's *)
(*     nonce, shared with its delegates; TxErr gives nearcore's first      *)
(*     failing check (NonceTooLarge past NonceCeiling, a model input).     *)
(*     SubmitSigned checks no nonce.                                       *)
(*  3. AddKey / DeleteKey receipts (ADDK / DELK, ExecKeyAct).  Key actions *)
(*     are only allowed on the predecessor's own account                   *)
(*     (runtime/runtime/src/actions.rs:755-801, ActorNoPermission);        *)
(*     deleting an absent key (access_keys.rs:84) or adding a present key  *)
(*     (access_keys.rs:158) fails the receipt.  With StoragePerByte a key  *)
(*     adds KeyBytes to the account's storage (access_keys.rs:17-29,       *)
(*     :240-252) and DeleteKey frees them (:136-147); an AddKey the        *)
(*     balance cannot cover fails with LackBalanceForState.                *)
(*  4. Multi-action receipts such as [DeleteKey(k), FunctionCall]: the     *)
(*     actions of one receipt run in order and are atomic                  *)
(*     (runtime/runtime/src/lib.rs:946-1005: the first failing action      *)
(*     stops the receipt, and the whole receipt rolls back,                *)
(*     lib.rs:1078-1088).  WithKeyActs / ExecWithKeys.                     *)
(*  5. A function call to an account without code, or to a missing         *)
(*     account, fails.  NearAsync does this itself (CallTargetOK; the code *)
(*     a call sees, CodeSeen, includes a DeployContract or                 *)
(*     UseGlobalContract earlier in its receipt, A9, A10); FailNoCode is   *)
(*     kept as an explicit step.  ExecBuiltinK also runs the global        *)
(*     contract distribution receipt (GDIST).                              *)
(*  6. Ghost sigpaid[a]: transactions signed by a's keys (a pays the gas). *)
(*  7. Delegate actions (NEP-366, meta transactions): a user signs a       *)
(*     delegate (SignedDelegate), a relayer submits it (SubmitDelegate),   *)
(*     ExecDelegate checks it on the user's account and emits the inner    *)
(*     receipt (runtime/runtime/src/actions.rs:453-535).  Delegate nonces  *)
(*     live in the key record (KeyNonce).                                  *)
(*  8. Accounts: key actions in an ACCOUNT receipt (WithAcctKeys,          *)
(*     ExecAcctK; a deleted account loses its keys) and the key of a       *)
(*     NEAR-implicit account a Transfer creates (ExecTransferK,            *)
(*     ExecBuiltinK); key actions in a call receipt (WithAcctKeys, ExecK,  *)
(*     OkK).  docs/SEMANTICS.md A3, A6, A7, A8.                            *)
(*                                                                         *)
(* A model that uses keys conjoins UNCHANGED keyVars to every step that    *)
(* does not touch keys, like any contract variable.                        *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS KeyAccts     \* accounts whose access keys are modelled
\* Contracts (accounts with code) is a NearAsync definition; a cfg
\* `Contracts = {...}` or `Contracts <- Def` sets it as before.

VARIABLES keys, sigpaid
keyVars == <<keys, sigpaid>>

Perm(rcv, ms, all) == [rcv |-> rcv, ms |-> ms, all |-> all]
FullPerm == [rcv |-> "", ms |-> {}, all |-> TRUE, full |-> TRUE]
IsFull(p) == "full" \in DOMAIN p /\ p.full
\* A function-call key with an allowance of n (model units, the units of
\* TxCost); Perm alone has none, nearcore's `None`: unlimited.
WithAllowance(p, n) ==
    IF IsFull(p) THEN Assert(FALSE, <<"WithAllowance: a full-access key has no allowance", p>>)
    ELSE ("al" :> n) @@ p
HasAllowance(p) == "al" \in DOMAIN p

KeyPresent(a, k) == k \in DOMAIN keys[a]
\* The cases are written with IF so that they are mutually exclusive: an
\* overlapping disjunction in an action makes TLC generate the same
\* successor once per true disjunct.
KeyAllows(a, k, to, m) ==
    /\ KeyPresent(a, k)
    /\ IF IsFull(keys[a][k]) THEN TRUE
       ELSE /\ keys[a][k].rcv = to
            /\ IF keys[a][k].all \/ keys[a][k].ms = {} THEN TRUE ELSE m \in keys[a][k].ms
KeysWithout(a, k) == [keys EXCEPT ![a] = [x \in DOMAIN keys[a] \ {k} |-> keys[a][x]]]
KeysWith(a, k, p)  == [keys EXCEPT ![a] = (k :> p) @@ keys[a]]
\* Nonces, per key, in the key record (field "nonce"; absent = 0): one per
\* key in nearcore, checked and set by SubmitTx and by delegates (K4).
\* A key re-added after a DeleteKey starts again at 0 (KeysWith); nearcore
\* starts a new key at (height - 1) * 1e6 (access_keys.rs:46-49, :240): an
\* over-approximation, see docs/SEMANTICS.md (K4).
KeyNonce(a, k) == IF "nonce" \in DOMAIN keys[a][k] THEN keys[a][k].nonce ELSE 0
KeysWithNonce(a, k, n) == [keys EXCEPT ![a][k] = ("nonce" :> n) @@ @]

\* The bytes a function-call AddKey is charged per byte for: the sum over its
\* method names of (length + 1) (runtime/near-vm-runner/src/logic/utils.rs:4-6,
\* paid at host.rs:4078-4091); the receiver id and allowance are not charged
\* per byte.  An empty list (any method) is 0 bytes.  nearcore counts UTF-8
\* bytes; TLC's Len counts characters, which is the same for ASCII only.  So
\* the model counts a name as written when it is printable ASCII (but the
\* backquote, which SANY does not take in a string) and asserts on any
\* other character (AsciiName).  WithMethodBytes(p, n) states the real
\* byte count n instead, for a model whose names are not ASCII, or are
\* placeholders or abbreviations of longer real ones (which the model
\* cannot detect).  The same count feeds the AddKey fee (KeyFee), the key's
\* storage (KeyBytes) and the 2000-byte limit (MethodBytesOK).
AsciiChars ==
    {" ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
     "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
     "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
     "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_",
     "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
     "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~"}
AsciiName(m) ==
    IF \A i \in 1..Len(m) : SubSeq(m, i, i) \in AsciiChars THEN TRUE
    ELSE Assert(FALSE, <<"a method name with a character outside printable ASCII: TLC counts characters,"
                         \o " nearcore UTF-8 bytes; state the names' byte count with WithMethodBytes(p, n)", m>>)
RECURSIVE NameBytes(_)
NameBytes(M) == IF M = {} THEN 0
                ELSE LET m == CHOOSE x \in M : TRUE IN
                     IF AsciiName(m) THEN Len(m) + 1 + NameBytes(M \ {m}) ELSE 0
WithMethodBytes(p, n) == ("mb" :> n) @@ p
MethodBytes(p) == IF "mb" \in DOMAIN p THEN p.mb ELSE NameBytes(p.ms)
\* max_number_bytes_method_names (2000 at 88): a function-call AddKey whose
\* MethodBytes exceed it makes the transaction invalid, or fails the
\* receipt that creates it (runtime/runtime/src/action_validation.rs
\* :456-474; runtime/runtime/src/lib.rs:968-979).  The model sees the
\* permission only where the AddKey is built or run, not on the creator,
\* so it asserts instead (AddKeyAct, AddKeyRcpt, ExecKeyAct).
MaxMethodNameBytes == 2000
MethodBytesOK(p) ==
    IF IsFull(p) \/ MethodBytes(p) <= MaxMethodNameBytes THEN TRUE
    ELSE Assert(FALSE, <<"AddKey with more than 2000 bytes of method names (max_number_bytes_method_names):"
                         \o " nearcore refuses it where it is created, which the model does not represent",
                         MethodBytes(p)>>)

\* Storage bytes of a key with permission p (with StoragePerByte):
\* trie id + borsh(AccessKey) + 40 (access_key_storage_usage,
\* runtime/runtime/src/access_keys.rs:17-29).  An ed25519 trie id is 33
\* bytes (core/crypto/src/signature.rs:332-338); AccessKey is nonce (8) and
\* the permission: tag (1), and for a function-call key the borsh of
\* FunctionCallPermission (core/primitives-core/src/account.rs:959-978):
\* allowance Option<u128> (1 for None, 17 for Some), receiver_id (4 + its
\* length) and method_names (4 + the sum of 4 + each length; empty for "any
\* method").  The receiver id is a model id standing for a real one, so its
\* length comes from IdBytes (overridable; default 10).  Method names count
\* as the AddKey fee counts them (MethodBytes: each name's length + 1, or the
\* WithMethodBytes figure), plus 3 more per name for the borsh length prefix.
\* A key with an allowance (WithAllowance) is 16 bytes larger (sim:
\* conformance/tests/accounts.rs, allowance_charge_refund_and_boundary).
\* Overridable: KeyBytes <- MyKeyBytes for another key type.
IdBytes(s) == 10
KeyBytes(p) ==
    IF IsFull(p) THEN FullKeyBytes
    ELSE LET mb == IF p.all THEN 0 ELSE MethodBytes(p) + 3 * Cardinality(p.ms)
         IN 33 + 8 + 1 + (IF HasAllowance(p) THEN 17 ELSE 1) + 4 + IdBytes(p.rcv) + 4 + mb + RecordExtraBytes
\* The bytes of a key map (key id -> permission).
KeyMapBytes(ks) ==
    LET F[S \in SUBSET DOMAIN ks] == IF S = {} THEN 0
                                    ELSE LET k == CHOOSE x \in S : TRUE IN KeyBytes(ks[k]) + F[S \ {k}]
    IN F[DOMAIN ks]

\* Init helper: keys0 : [KeyAccts -> (key id -> permission)].
KeysInit(keys0) == keys = keys0 /\ sigpaid = [a \in Accounts |-> 0]

\* A receipt with more than one function-call action (a batch).  Receipt
\* records carry no action list, so this reads the per-call gas lists: in
\* fault mode give a multi-call transaction one static per call
\* (WithStatic(r, <<0, 0>>)), or a function-call key will be allowed to
\* sign it.
IsMultiCall(r) == Len(r.gs) > 1 \/ Len(r.g) > 1

\* Can key k of a sign the transaction whose first receipt is r?  A
\* function-call key: one action only, a function call (not Transfer, Stake
\* or a key action), no deposit (verifier.rs:209-250).  A model that bundles
\* key actions into a call receipt (WithKeyActs) must also require IsFull.
KeyCanSign(a, k, r) ==
    /\ KeyAllows(a, k, r.to, r.m)
    /\ IF IsFull(keys[a][k]) THEN TRUE
       ELSE /\ IsCall(r)
            /\ ~IsMultiCall(r)
            /\ ~HasAc(r)          \* one FunctionCall only (verifier.rs:213-217)
            /\ r.dep = 0

\* The allowance (docs/SEMANTICS.md, K2 and N-allowance).  Conversion
\* charges a function-call key with an allowance the transaction's whole
\* cost; an allowance below it makes the transaction invalid
\* (NotEnoughAllowance; equal is enough, runtime/runtime/src/verifier.rs
\* :282-303, :365-373).  Each gas refund of the transaction adds back to the
\* key when it runs (runtime/runtime/src/lib.rs:3041-3047,
\* runtime/runtime/src/actions.rs:133-157).  The model credits the whole
\* refund at conversion.  While the key stays, its modelled allowance is
\* then never below nearcore's, so it can sign every transaction it can
\* sign in nearcore, and more while refunds are in flight (an
\* over-approximation).  nearcore credits a refund to whatever key holds
\* the public key when the refund runs, so a key deleted and added again
\* gets the old key's late refunds; the model cannot, and asserts instead
\* (AllowanceAddOK).
\* WithTxCost(r, c, f) on a transaction's first receipt r states its cost c
\* and refund f (0 < c, 0 <= f <= c), in the allowance's units.  nearcore's
\* cost is never 0: the conversion alone burns gas at a positive price, and
\* the prepaid gas is bought at max(gas price, min_gas_purchase_price)
\* (runtime/runtime/src/config.rs:515-536).  So a transaction signed with a
\* key that has an allowance must state both: without WithTxCost, TxCost is
\* an Assert.  A refund stated above nearcore's over-approximates; one
\* below it hides transactions nearcore lets through.  The fields are
\* dropped when the transaction is submitted.
WithTxCost(r, c, f) ==
    IF c <= 0 THEN Assert(FALSE, <<"WithTxCost: the cost must be positive (nearcore's always is)", c>>)
    ELSE IF f < 0 \/ f > c THEN Assert(FALSE, <<"WithTxCost: the refund must be within 0..cost", c, f>>)
    ELSE [tc |-> c, trf |-> f] @@ r
TxCost(r)   ==
    IF "tc" \in DOMAIN r THEN r.tc
    ELSE Assert(FALSE, <<"a transaction signed with a key that has an allowance needs WithTxCost(r, cost, refund):"
                         \o " nearcore's cost is never 0", r.to, r.m>>)
TxRefund(r) == IF "trf" \in DOMAIN r THEN r.trf ELSE TxCost(r)
Bare(r) == IF "tc" \in DOMAIN r THEN [f \in DOMAIN r \ {"tc", "trf"} |-> r[f]] ELSE r
KeyAllowance(a, k) == keys[a][k].al
AllowanceOK(a, k, r) == IF HasAllowance(keys[a][k]) THEN keys[a][k].al >= TxCost(r) ELSE TRUE
Charged(p, r) == IF HasAllowance(p) THEN [p EXCEPT !.al = @ - TxCost(r) + TxRefund(r)] ELSE p
\* A key with an allowance added as k of a (an AddKey in any receipt) while a
\* gas refund of a transaction signed with (a, k) may still be in flight.
\* nearcore reads the key by its public key when the refund runs and adds
\* the refund to the new key's allowance (actions.rs:133-157); the model
\* credited it to the old key at conversion, so the new key's modelled
\* allowance would be below nearcore's (an under-approximation).  Refunds
\* are not receipts in the model, so any transaction ever signed with
\* (a, k) may still have one in flight: AllowanceAddOK asserts when txsig
\* holds one (with TrackSigner = FALSE there is no txsig to read, so it
\* asserts on every such AddKey).  Give the new key a fresh id.  ExecKeyAct,
\* ExecWithKeys and ExecAcctK check it for an AddKey whose key is still in
\* the account's key map ks after the receipt (AllowanceAddsOK): a later
\* DeleteKey of it, or a DeleteAccount, in the same receipt leaves no key
\* for a late refund to reach.
SignedWith(a, k) == ~TrackSigner \/ \E t \in DOMAIN txsig : txsig[t].a = a /\ txsig[t].k = k
AllowanceAddOK(a, k, p) ==
    IF IsFull(p) \/ ~HasAllowance(p) \/ ~SignedWith(a, k) THEN TRUE
    ELSE Assert(FALSE, <<"AddKey of a key with an allowance under a key id that has signed transactions:"
                         \o " nearcore adds their late gas refunds to the new key, the model does not;"
                         \o " give the new key a fresh id (docs/SEMANTICS.md, N-allowance)", a, k>>)
AllowanceAddsOK(a, acts, ks) ==
    \A i \in DOMAIN acts : acts[i].op = "add" /\ acts[i].k \in DOMAIN ks => AllowanceAddOK(a, acts[i].k, ks[acts[i].k])

\* Submit a signed transaction.  A key of a \in KeyAccts must be able to sign
\* it, and its allowance, if it has one, pay for it.  No nonce: see SubmitTx.
SubmitSigned(r, a, k) ==
    /\ (a \in KeyAccts) => (KeyCanSign(a, k, r) /\ AllowanceOK(a, k, r))
    /\ SubmitAs(Bare(r), a, k)
    /\ sigpaid' = [sigpaid EXCEPT ![a] = @ + 1]
    /\ keys' = IF a \in KeyAccts /\ KeyPresent(a, k) /\ HasAllowance(keys[a][k])
               THEN [keys EXCEPT ![a][k] = Charged(@, r)] ELSE keys

\* Transactions with nonces (docs/SEMANTICS.md, K5).  A signed
\* transaction is a value: the signer a, its key k, the nonce n (any
\* integer) and the first receipt r.  Anyone holding it may submit it, any
\* number of times: a replay.  For a in KeyAccts, nearcore accepts it only
\* if n exceeds the key's nonce (runtime/runtime/src/verifier.rs:254-280,
\* :343-348; any gap is fine), and acceptance sets the key's nonce to n
\* (:402; lib.rs:350-352), the nonce its delegates are checked against
\* (K4).  So a replay, or a transaction below one already accepted, is
\* refused.  A key re-added after a DeleteKey starts at nonce 0, as for
\* delegates (N-delegate-rekey).  For a signer outside KeyAccts there is no
\* key, so no nonce check.
SignedTx(a, k, n, r) == [sgn |-> a, k |-> k, n |-> n, r |-> r]

\* The nonce's upper bound.  Right after the InvalidNonce check, nearcore
\* refuses a transaction whose nonce is at or above block_height x 1e6
\* (NonceTooLarge, verifier.rs:271-278), and fails a delegate likewise when
\* its outer receipt runs (DelegateActionNonceTooLarge, actions.rs:657-665).
\* The model's heights (blk, from 0) and nonces (small integers) are not on
\* nearcore's scale, so the bound is a model input: NonceHeight0 is the
\* nearcore height at blk = 0, and the first nonce refused at model height h
\* is NonceCeiling(h) = (NonceHeight0 + h) x NoncePerHeight (1e6 in
\* nearcore, ACCESS_KEY_NONCE_RANGE_MULTIPLIER; a model may scale its
\* nonces down with it).  The default NonceHeight0 = -1 refuses none
\* (docs/SEMANTICS.md, K5, N-tx-validity).  A model whose nonces can run
\* ahead of the chain (a nonce taken from a clock, a transaction signed for
\* later) sets both, e.g. "NearKeys!NonceHeight0" = "1" and
\* "NearKeys!NoncePerHeight" = "3" in runs.toml.
NonceHeight0   == -1
NoncePerHeight == 1000000
NonceCeiling(h) == (NonceHeight0 + h) * NoncePerHeight
NonceTooLarge(n) == NonceHeight0 >= 0 /\ n >= NonceCeiling(blk)

\* The first check that refuses st, in nearcore's order, or "": the
\* transaction's actions (verifier.rs:92-104), the signer (:164-195), then
\* the nonce (InvalidNonce, then NonceTooLarge, :254-280), balance,
\* allowance, storage and the function-call key's scope (:343-393).  A
\* model branches on it to see a refusal.
TxErr(st) ==
    LET a == st.sgn  k == st.k  r == st.r  ka == a \in KeyAccts IN
    CASE NActs(r) > MaxActionsPerReceipt
         \/ (IsDeleg(r) /\ NActs(r.a.inner) > MaxActionsPerReceipt) -> "TotalNumberOfActionsExceeded"
      [] a \in deleted                                             -> "SignerDoesNotExist"
      [] ka /\ ~KeyPresent(a, k)                                    -> "AccessKeyNotFound"
      [] ka /\ st.n <= KeyNonce(a, k)                               -> "InvalidNonce"
      [] ka /\ NonceTooLarge(st.n)                                  -> "NonceTooLarge"
      [] near[a] < DepTotal(r)                                      -> "NotEnoughBalance"
      [] ka /\ ~AllowanceOK(a, k, r)                                -> "NotEnoughAllowance"
      [] StoragePerByte
         /\ ~StorageCovers(near[a] - DepTotal(r) + LockedOf(a), stor[a]) -> "LackBalanceForState"
      [] ka /\ ~KeyCanSign(a, k, r)                                 -> "AccessKeyError"
      [] OTHER                                                      -> ""

\* Submit the signed transaction st: refused unless TxErr(st) = "".  The
\* key's nonce becomes st.n and its allowance is charged.
SubmitTx(st) ==
    LET a == st.sgn  k == st.k IN
    /\ TxErr(st) = ""
    /\ SubmitAs(Bare(st.r), a, k)
    /\ sigpaid' = [sigpaid EXCEPT ![a] = @ + 1]
    /\ keys' = IF a \in KeyAccts THEN [keys EXCEPT ![a][k] = ("nonce" :> st.n) @@ Charged(@, st.r)]
               ELSE keys

----------------------------------------------------------------------------
(* AddKey / DeleteKey receipts                                             *)


\* Constructors for key-action receipts on the creator's own account acct,
\* with the receipt's send + exec fee as the creator-side fee (gas mode),
\* per-byte part included (sir: the receipt is on the creator's account).
KeyFee(m, p) ==
    IF GasMode # "gas" THEN 0
    ELSE IF m = DELK THEN NearFeeTable!OneActionReceiptFee("delete_key", TRUE, "named")
    ELSE IF IsFull(p) THEN NearFeeTable!OneActionReceiptFee("add_key_full", TRUE, "named")
    ELSE NearFeeTable!OneActionReceiptFee("add_key_fc", TRUE, "named")
         + NearFeeTable!AddKeyFcBytesFee(TRUE, MethodBytes(p))
AddKeyRcpt(id, tx, acct, a, p, cb) ==
    IF MethodBytesOK(p) THEN WithFee(Rcpt(id, tx, acct, acct, ADDK, a, 0, acct, cb), KeyFee(ADDK, p)) ELSE FALSE
DelKeyRcpt(id, tx, acct, a, cb)    == WithFee(Rcpt(id, tx, acct, acct, DELK, a, 0, acct, cb), KeyFee(DELK, FullPerm))

\* Execute an AddKey / DeleteKey receipt.  k: key id, p: permission (AddKey only);
\* the model decodes them from its own r.a.  With StoragePerByte, AddKey adds
\* KeyBytes(p) and fails if liquid + locked does not cover the result
\* (the receipt's storage check, runtime/runtime/src/lib.rs:1008-1031);
\* DeleteKey frees the deleted key's bytes.
KeyActBytes(r, k, p) == IF r.m = DELK THEN -KeyBytes(keys[r.to][k]) ELSE KeyBytes(p)
ExecKeyAct(r, k, p) ==
    /\ r.m \in {ADDK, DELK}
    /\ r.m = ADDK => MethodBytesOK(p)
    /\ LET ok == /\ AcctExists(r.to)       \* AccountDoesNotExist (actions.rs:862-879)
                 /\ r.to = r.fr
                 /\ r.to \in KeyAccts
                 /\ IF r.m = DELK THEN KeyPresent(r.to, k) ELSE ~KeyPresent(r.to, k)
                 /\ IF ~StoragePerByte THEN TRUE
                    ELSE StorageCovers(near[r.to] + r.dep + LockedOf(r.to), stor[r.to] + KeyActBytes(r, k, p))
       IN IF ok
          THEN /\ r.m = ADDK => AllowanceAddOK(r.to, k, p)
               /\ rq'   = RemR(r)
               /\ post' = RemP(r)
               /\ data' = RemD(r) \cup DataOf(r, TRUE, EMPTY)
               /\ near' = [near EXCEPT ![r.to] = @ + r.dep]
               /\ keys' = IF r.m = DELK THEN KeysWithout(r.to, k) ELSE KeysWith(r.to, k, p)
               /\ rlog' = LogR(r, "ok")
               /\ stor' = IF StoragePerByte THEN [stor EXCEPT ![r.to] = @ + KeyActBytes(r, k, p)] ELSE stor
               /\ UNCHANGED <<locked, proposal, epoch, nid, fails, paid, minted, oog, txsig, created,
                              burnt, blk, deleted, code, gcode, guse, gnonce, ofail, sigpaid>>
          ELSE FailP(r, FALSE) /\ UNCHANGED keyVars

----------------------------------------------------------------------------
(* Key actions inside a function-call receipt, e.g. [DeleteKey(k),         *)
(* FunctionCall(m)].  acts: the key actions that precede the call, in      *)
(* order (AddKeyAct / DelKeyAct).                                          *)
KAct(op, k, p) == [op |-> op, k |-> k, p |-> p]
AddKeyAct(k, p) == IF MethodBytesOK(p) THEN KAct("add", k, p) ELSE FALSE
DelKeyAct(k)    == KAct("del", k, FullPerm)

\* Fold acts over one account's key map: [ok, ks].
RECURSIVE KeysFold(_, _)
KeysFold(ks, acts) ==
    IF acts = <<>> THEN [ok |-> TRUE, ks |-> ks]
    ELSE LET x == Head(acts) IN
         IF x.op = "del"
         THEN IF x.k \in DOMAIN ks
              THEN KeysFold([y \in DOMAIN ks \ {x.k} |-> ks[y]], Tail(acts))
              ELSE [ok |-> FALSE, ks |-> ks]
         ELSE IF x.k \in DOMAIN ks
              THEN [ok |-> FALSE, ks |-> ks]
              ELSE KeysFold((x.k :> x.p) @@ ks, Tail(acts))

\* In a receipt with account actions (HasAc) the actor and the key map
\* follow its CreateAccount: the new account, with no keys (A6, A8).
KeyActor(r) == IF HasAc(r) THEN AcctActor(r) ELSE r.fr
KeyBase(r)  == IF HasAc(r) /\ r.ac.mk THEN <<>> ELSE keys[r.to]
KeyActsOK(r, acts) ==
    acts = <<>> \/ (KeyActor(r) = r.to /\ r.to \in KeyAccts /\ KeysFold(KeyBase(r), acts).ok)
\* On commit; with account actions a create starts from no keys and a
\* delete clears them (core/store/src/utils/mod.rs:504-575).
KeysAfter(r, acts) ==
    IF HasAc(r) /\ r.to \in KeyAccts /\ (r.ac.mk \/ r.ac.bnf # "" \/ acts # <<>>)
    THEN [keys EXCEPT ![r.to] = IF r.ac.bnf # "" THEN <<>> ELSE KeysFold(KeyBase(r), acts).ks]
    ELSE IF acts = <<>> THEN keys ELSE [keys EXCEPT ![r.to] = KeysFold(keys[r.to], acts).ks]

\* The bytes the key actions add to r.to (StoragePerByte).
KeyActsBytes(r, acts) ==
    IF acts = <<>> THEN 0
    ELSE KeyMapBytes(KeysFold(KeyBase(r), acts).ks) - KeyMapBytes(KeyBase(r))

\* The handler's outcome O for the function call, failed as a whole if a key
\* action fails (the call then does not run).  With StoragePerByte the key
\* actions' bytes join the call's (OStor): nearcore checks storage once, at
\* the end of the receipt (lib.rs:1008-1031).
\* For a receipt with account actions the outcome is marked (kf): NearAsync's
\* CommitAc asserts it when the receipt has key actions, so running one with
\* plain Exec, which would drop them, is an error.
WithKeyActs(r, acts, O0) ==
    LET O == IF HasAc(r) THEN [kf |-> TRUE] @@ O0 ELSE O0 IN
    IF ~KeyActsOK(r, acts) THEN OErr(O, "key action failed")
    ELSE IF StoragePerByte /\ acts # <<>> THEN OStor(O, StorDelta(O) + KeyActsBytes(r, acts))
    ELSE O
OkWithKeys(r, acts, O)  == Ok(r, WithKeyActs(r, acts, O))

\* Platform + keys part of running such a receipt.  The contract conjoins
\*   IF OkWithKeys(r, acts, O) THEN <its state := O's> ELSE UNCHANGED <its state>.
ExecWithKeys(r, acts, O) ==
    LET O2 == WithKeyActs(r, acts, O) IN
    /\ Exec(r, O2)
    /\ acts # <<>> /\ Ok(r, O2) => AllowanceAddsOK(r.to, acts, KeysAfter(r, acts)[r.to])
    /\ keys' = IF Ok(r, O2) THEN KeysAfter(r, acts) ELSE keys
    /\ UNCHANGED sigpaid

\* A call receipt with account actions (NearAsync HasAc, A8) and the key
\* actions WithAcctKeys put in it: run it with ExecK, which also resets the
\* new or deleted account's keys, and read the outcome with OkK.  The same
\* as ExecWithKeys(r, <<>>, O) / Ok(r, O) for any other receipt.
AcKeyActs(r) == IF HasAc(r) THEN r.ac.ka ELSE <<>>
ExecK(r, O) == ExecWithKeys(r, AcKeyActs(r), O)
OkK(r, O)   == OkWithKeys(r, AcKeyActs(r), O)

\* A function call to an account that has no contract (or does not exist).
\* Exec already fails such calls (NearAsync CallTargetOK); this is the same
\* rule as an explicit step for dispatchers.  The code is the one the call
\* sees (CodeSeen): after the receipt's CreateAccount and DeployContract.
FailNoCode(r) == IsCall(r) /\ ~CodeSeen(r) /\ FailWhyL(r, "fail", "CodeDoesNotExist", 0)

----------------------------------------------------------------------------
(* Accounts: key actions in an ACCOUNT receipt, deletion, implicit keys    *)
(* (NearAsync, "Account lifecycle"; docs/SEMANTICS.md A6, A7).             *)

\* Key actions in an ACCOUNT receipt, after its CreateAccount and Transfer
\* and before its DeleteAccount: acts as for WithKeyActs (AddKeyAct /
\* DelKeyAct).  On a new account they apply to an empty key map (e.g. its
\* first full-access key).  The actor must be the account (the new account
\* after a CreateAccount, else the predecessor).  Adds their fees to gf.
AcctKeyFee(r, x) ==
    IF GasMode # "gas" THEN 0
    ELSE LET sir == (r.fr = r.to) IN
         IF x.op = "del" THEN NearFeeTable!ActionFee("delete_key", sir, "named")
         ELSE IF IsFull(x.p) THEN NearFeeTable!ActionFee("add_key_full", sir, "named")
         ELSE NearFeeTable!ActionFee("add_key_fc", sir, "named") + NearFeeTable!AddKeyFcBytesFee(sir, MethodBytes(x.p))
RECURSIVE AcctKeysFee(_, _)
AcctKeysFee(r, acts) == IF acts = <<>> THEN 0 ELSE AcctKeyFee(r, Head(acts)) + AcctKeysFee(r, Tail(acts))
WithAcctKeys(r, acts) ==
    IF ~(IsAcctRcpt(r) \/ AcCall(r)) THEN Assert(FALSE, <<"WithAcctKeys needs an ACCOUNT receipt or a call receipt with account actions", r.id>>)
    ELSE [r EXCEPT !.ac.ka = @ \o acts, !.gf = @ + AcctKeysFee(r, acts)]

\* The key map the key actions start from, and their result.
AcctKeysBase(r) == IF r.ac.mk \/ r.to \notin KeyAccts THEN <<>> ELSE keys[r.to]
AcctKeysFold(r) == KeysFold(AcctKeysBase(r), r.ac.ka)
AcctKeysBytes(r) ==
    IF r.ac.ka = <<>> \/ ~AcctKeysFold(r).ok THEN 0
    ELSE KeyMapBytes(AcctKeysFold(r).ks) - KeyMapBytes(AcctKeysBase(r))

\* Run an ACCOUNT receipt, with its key actions (NearAsync ExecAcctWith).  On
\* success the account's keys become the fold's result; a delete clears them
\* (core/store/src/utils/mod.rs:504-575), as does a create (a new account
\* has none).  On failure keys are unchanged.  Key actions need the
\* account in KeyAccts.  The contract conjoins UNCHANGED of its own vars.
ExecAcctK(r) ==
    /\ IsAcctRcpt(r)
    /\ Assert(r.ac.ka = <<>> \/ r.to \in KeyAccts,
              <<"ACCOUNT receipt with key actions on an account outside KeyAccts", r.to>>)
    /\ LET kb == AcctKeysBytes(r)  kok == AcctKeysFold(r).ok IN
       /\ ExecAcctWith(r, kb, kok)
       /\ AcctOK(r, kb, kok) /\ r.to \in KeyAccts
          => AllowanceAddsOK(r.to, r.ac.ka, IF r.ac.bnf # "" THEN <<>> ELSE AcctKeysFold(r).ks)
       /\ keys' = IF AcctOK(r, kb, kok) /\ r.to \in KeyAccts
                  THEN [keys EXCEPT ![r.to] = IF r.ac.bnf # "" THEN <<>>
                                              ELSE IF r.ac.ka = <<>> /\ ~r.ac.mk THEN @
                                              ELSE AcctKeysFold(r).ks]
                  ELSE keys
       /\ UNCHANGED sigpaid

\* A Transfer that creates a NEAR-implicit account also gives it a
\* full-access key, the one its id is derived from (actions.rs:221-240; sim
\* lifecycle.rs receipts_to_deleted: also when it is created again).  Its id
\* in keys is ImplicitKeyId.  ExecTransferK adds it for an account in
\* KeyAccts; ExecBuiltinK is ExecBuiltin with it.
ImplicitKeyId == "implicit"
ExecTransferK(r) ==
    /\ ExecTransfer(r)
    /\ keys' = IF ~AcctExists(r.to) /\ KindOf(r.to) = "near_implicit" /\ r.to \in KeyAccts
               THEN [keys EXCEPT ![r.to] = (ImplicitKeyId :> FullPerm)]
               ELSE keys
    /\ UNCHANGED sigpaid
ExecBuiltinK(r) ==
    \/ ExecTransferK(r)
    \/ (ExecTransferFail(r) \/ ExecStake(r) \/ ExecGDist(r)) /\ UNCHANGED keyVars

----------------------------------------------------------------------------
(* Delegate actions (NEP-366, meta transactions).                          *)
(* The user s signs a delegate with its key k: nonce n, expiry height mbh  *)
(* and the inner receipt c (SignedDelegate).  A relayer rl sends a         *)
(* transaction to s carrying it (SubmitDelegate): rl is the signer, pays   *)
(* the gas and the inner deposit (runtime/runtime/src/config.rs:652-668).  *)
(* Its first receipt (DELEG, predecessor rl) runs on s: ExecDelegate       *)
(* checks the delegate and emits the inner receipt, with predecessor s,    *)
(* receiver c.to, and the outer receipt's signer, rl                       *)
(* (runtime/runtime/src/actions.rs:453-535, the receipt at :500-512).  The *)
(* inner receipt stays in rl's transaction, so Signer / SignerKey of it    *)
(* and of everything it spawns are rl and rl's key.  It is a new outgoing  *)
(* receipt, never local (runtime/runtime/src/lib.rs:1222-1234).            *)
(* Deposit refunds go to the failing receipt's predecessor                 *)
(* (core/primitives/src/receipt.rs:428-430; runtime/runtime/src/lib.rs:    *)
(* 1295-1303, :1402-1406): to rl if the outer receipt fails, to s if the   *)
(* inner one does.                                                         *)
(* A model builds a SignedDelegate only in a step of the user s itself     *)
(* (that is its signature); a relayer step that builds one for another     *)
(* account is a forgery, which nearcore rejects                            *)
(* (DelegateActionInvalidSignature, actions.rs:474-477).  A dispatcher     *)
(* routes IsDeleg(r) to ExecDelegate(r), before any contract handler (Exec *)
(* asserts on a DELEG receipt).                                            *)

\* mbh of a delegate without an expiry height.
NoExpiry == -1


\* The user s's signed delegate: its key k, nonce n (any integer; it must
\* exceed the key's last delegate nonce when it runs), expiry height mbh
\* (NoExpiry: none), and the inner receipt c, built with Rcpt: receiver,
\* method, args, deposit, and in gas mode its gas (WithGas).  c's id, tx,
\* fr, rto, cb and loc are set when the delegate runs.  A delegate cannot
\* carry a delegate (core/primitives/src/action/delegate.rs:371-433).
SignedDelegate(s, k, n, mbh, c) ==
    IF IsDeleg(c) THEN Assert(FALSE, <<"a delegate cannot carry a delegate", s, n>>)
    ELSE [snd |-> s, k |-> k, n |-> n, mbh |-> mbh, inner |-> c]

\* The relayer rl's first receipt: to the user, predecessor rl, the inner
\* deposit attached (paid by rl at submission; refunded to rl if this
\* receipt fails).  Action-only: it never runs out of gas.
DelegRcpt(id, tx, rl, sd) == Rcpt(id, tx, sd.snd, rl, DELEG, sd, DepTotal(sd.inner), rl, 0)
\* The relayer's transaction, signed with its key k.  A function-call key
\* cannot sign it: it is not a function call (IsCall is FALSE;
\* runtime/runtime/src/verifier.rs:213-222).
SubmitDelegate(id, tx, rl, k, sd) == SubmitSigned(DelegRcpt(id, tx, rl, sd), rl, k)

\* Expiry: the delegate fails when block_height > max_block_height
\* (actions.rs:479-482), checked when the outer receipt runs.  With the
\* block clock (MaxBlk > 0) that is blk > mbh; without one (MaxBlk = 0) a
\* delegate with an expiry may fail at any time (an over-approximation).
DelegMayExpire(sd)  == sd.mbh # NoExpiry /\ (MaxBlk = 0 \/ blk > sd.mbh)
DelegMustExpire(sd) == sd.mbh # NoExpiry /\ MaxBlk > 0 /\ blk > sd.mbh

\* The inner receipt as the key check sees it (predecessor = the user).
DelegInner(r) == [r.a.inner EXCEPT !.fr = r.to]

\* The first failing check of the outer receipt r other than expiry, or "".
\* The account must exist and be initialised (actions.rs:861-886); the
\* delegate's sender must be r's receiver (:483-490); for a user in KeyAccts,
\* the key must exist (:587-602), the nonce must be above the key's
\* (:648-657) and below the ceiling (:657-665, NonceTooLarge above), and a
\* function-call key allows one zero-deposit function call
\* to its receiver and methods (:670-727; KeyCanSign, as for a transaction).
\* A user outside KeyAccts gets no key, nonce or permission check.
DelegErr(r) ==
    LET sd == r.a  s == r.to IN
    CASE ~AcctExists(s)                                       -> "AccountDoesNotExist"
      [] UninitUniversal(s)                                   -> "AccountNotInitialized"
      [] sd.snd # s                                           -> "SenderDoesNotMatchTxReceiver"
      [] s \in KeyAccts /\ ~KeyPresent(s, sd.k)               -> "AccessKeyNotFound"
      [] s \in KeyAccts /\ sd.n <= KeyNonce(s, sd.k)          -> "InvalidNonce"
      [] s \in KeyAccts /\ NonceTooLarge(sd.n)                -> "NonceTooLarge"
      [] s \in KeyAccts /\ ~KeyCanSign(s, sd.k, DelegInner(r)) -> "AccessKeyError"
      [] OTHER                                                -> ""

\* Run the outer receipt r (IsDeleg(r)).  On success the key's nonce becomes
\* the delegate's (actions.rs:729-733) and the inner receipt is created with
\* a fresh id; the deposit travels with it.  On failure r fails like any
\* receipt: its deposit is refunded to rl (r.rto), no inner receipt.  The
\* contract conjoins UNCHANGED of its own variables.
ExecDelegate(r) ==
    /\ IsDeleg(r)
    /\ LET sd == r.a
           c  == [sd.inner EXCEPT !.id = nid, !.tx = r.tx, !.fr = r.to, !.rto = r.to,
                                  !.cb = 0, !.res = NoRes, !.loc = FALSE]
       IN \/ /\ ~DelegMustExpire(sd) /\ DelegErr(r) = ""
             /\ rq'   = RemR(r) \cup {InstantTag(c)}   \* an inner [DeleteAccount] is instant (S5)
             /\ post' = RemP(r)
             /\ data' = RemD(r)
             /\ nid'  = nid + 1
             /\ keys' = IF r.to \in KeyAccts THEN KeysWithNonce(r.to, sd.k, sd.n) ELSE keys
             /\ rlog' = LogR(r, "ok")
             /\ UNCHANGED <<near, locked, proposal, epoch, fails, paid, minted, oog, txsig, created,
                            burnt, blk, stor, deleted, code, gcode, guse, gnonce, ofail, sigpaid>>
          \/ /\ DelegMayExpire(sd) \/ DelegErr(r) # ""
             /\ FailP(r, FALSE)
             /\ UNCHANGED keyVars
=============================================================================
