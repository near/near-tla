------------------------------ MODULE NearFees ------------------------------
\* NEAR action fees, in Ggas (1 Tgas = 1000 Ggas), per protocol version.
\*
\* A pure-definitions module: no VARIABLES, no CONSTANTS. Use it with EXTENDS or
\* INSTANCE.
\*
\* ---------------------------------------------------------------------------
\* Selecting the protocol version
\* ---------------------------------------------------------------------------
\* FeeProtocol (below) is the ONE place that selects the default version. To
\* change it, edit the number. It must be in FeeVersions. The unsuffixed
\* operators (SendFee, ExecFee, ActionFee, TransferFeeTotal, ...) read
\* FeeProtocol. Every operator also has an ...At(pv, ...) form that takes the
\* version explicitly, so one spec can compare versions.
\*
\* Versions covered (nearcore 2.14.0-rc.5, rev b7b4737, the sim's pin):
\*   84  MIN_SUPPORTED_PROTOCOL_VERSION    core/primitives-core/src/version.rs:666
\*   85  first version with the create_account repricing
\*   86  mainnet. There is no 86.yaml, so 86 runs 85's parameters:
\*       ConfigStore::get_config picks the highest yaml <= the requested version
\*       (core/parameters/src/config_store.rs:238-246; the list of yamls is at
\*       :29-63 and has 84, 85, 87, 88 but no 86).
\*   87  adds universal (0u) accounts (core/primitives-core/src/version.rs:639)
\*   88  STABLE_PROTOCOL_VERSION (core/primitives-core/src/version.rs:694). A
\*       non-nightly 2.14.0-rc.5 binary runs 88: PROTOCOL_VERSION = STABLE
\*       unless built with "nightly" (:706-712). The sim runs 88.
\* The nightly versions (129, 155, 157) change no action fee.
\*
\* ---------------------------------------------------------------------------
\* Sources (all paths relative to a nearcore checkout at b7b4737)
\* ---------------------------------------------------------------------------
\* The values are the resolved per-version configs that nearcore snapshots in
\*   core/parameters/src/snapshots/near_parameters__config_store__tests__<v>.json.snap
\* ("SNAP<v>" below), built from core/parameters/res/runtime_configs/parameters.yaml
\* plus the per-version diffs <v>.yaml. Line numbers are the same in SNAP84,
\* SNAP85, SNAP87 and SNAP88. Between 84 and 88 the only action fee that changes
\* is create_account (85.yaml:16-27).
\*
\* ---------------------------------------------------------------------------
\* Units and rounding
\* ---------------------------------------------------------------------------
\* - Base fees: every table entry is rounded to the nearest Ggas. Every
\*   exported operator is a SUM of table entries, so the parts add up exactly:
\*   SendFee + ExecFee = ActionFee, and ReceiptFee + ActionFee = the
\*   single-action receipt total. The error is at most 0.5 Ggas per entry.
\* - Per-byte fees are stored in micro-Ggas per byte (1 uGgas = 1e-6 Ggas =
\*   1000 gas), rounded to the nearest uGgas. Bytes(n, u) multiplies and rounds
\*   the product once to the nearest Ggas. It never forms a product above
\*   about 1.1e9, so it stays inside TLC's 32-bit integers for n up to 16 MiB.
\*   Every protocol limit on a byte count is below that: arguments, return
\*   data and contract size are all at most 4 MiB at 88 (SNAP88:248-252).
\*
\* ---------------------------------------------------------------------------
\* sir ("sender is receiver")
\* ---------------------------------------------------------------------------
\* sir = TRUE when the receipt's predecessor is also its receiver. For a promise
\* created by a contract, that means the receipt targets the creating contract
\* itself (runtime/near-vm-runner/src/logic/host.rs:2577, :2636, and
\* promise_idx_to_receipt_idx_with_sir at :2699-2715). For a transaction's first
\* receipt, it means signer = receiver (runtime/runtime/src/config.rs:86-90, total_send_fees(sender_is_receiver)).
\* At versions 84-88 every BASE fee has send_sir = send_not_sir, so sir only
\* changes the per-byte send fees (send_not_sir = 47,683,715 gas/byte for all of
\* them: the cross-shard bandwidth charge).
\*
\* ---------------------------------------------------------------------------
\* Account kinds (rcvKind) and the Transfer fee
\* ---------------------------------------------------------------------------
\* The kind is decided by the receiver id's PATTERN alone, whether or not the
\* account exists. The fee functions take only the account type
\* (core/parameters/src/cost.rs:775-810 exec, :812-848 send), and both callers
\* pass receiver_id.get_account_type() with no existence check:
\* promise_batch_action_transfer (runtime/near-vm-runner/src/logic/host.rs:3621-3661)
\* and the transaction path (runtime/runtime/src/config.rs:120-128 send,
\* :360-368 exec). The patterns come from near-account-id 3.0.0 (the version in
\* nearcore's Cargo.lock), src/account_id_ref.rs:246-260 and
\* src/validation.rs:96-132:
\*   "eth_implicit"   "0x" + 40 lowercase hex          (checked first)
\*   "near_implicit"  64 lowercase hex
\*   "deterministic"  "0s" + 40 lowercase hex
\*   "universal"      "0u" + 52 Crockford base32 (87+)
\*   "named"          anything else
\* Transfer fee by kind (cost.rs:775-848):
\*   named          transfer
\*   near_implicit  transfer + create_account + add_full_access_key
\*   eth_implicit   transfer + create_account   (eth_implicit_accounts is TRUE
\*                  at 84-88: SNAP84:231 .. SNAP88:231)
\*   deterministic  transfer + create_account   (same flag)
\*   universal      transfer + create_account at 87+ (universal_accounts:
\*                  SNAP87:232, SNAP88:232). At 84-86 the flag is off and it
\*                  is charged as a plain transfer.
\* The same kind-dependent amount is charged on both the send and the exec side.
\*
\* ---------------------------------------------------------------------------
\* Who pays what (see docs/SEMANTICS.md, "Gas")
\* ---------------------------------------------------------------------------
\* When a contract creates a receipt, it pays from its own gas, at creation:
\*   - the receipt's send fee (burnt) + exec fee (prepaid for the child), for
\*     the receipt base (host.rs:2345-2365) and for every action appended to it
\*     (pay_action_base / pay_action_per_byte, host.rs:5379-5410; Transfer:
\*     host.rs:3621-3661);
\*   - for promise_batch_then, also a data receipt's send + exec base fee for
\*     every dependency, all of it burnt (host.rs:2353-2360).
\* When a function call returns a value to N waiting callbacks, value_return
\* burns N * (data_receipt_byte send + exec) * len(value) (host.rs:4695-4746).
EXTENDS Integers, TLC

\* ===== The selected protocol version (the one place to change it) ==========
FeeProtocol == 88

FeeVersions == {84, 85, 86, 87, 88}
ASSUME FeeProtocol \in FeeVersions

\* universal_accounts is on from 87 (SNAP87:232; version.rs:639).
UniversalAccountsOn(pv) == pv >= 87

RcvKinds == {"named", "near_implicit", "eth_implicit", "deterministic", "universal"}

FeeActions == {"transfer", "create_account", "add_key_full", "add_key_fc",
               "delete_key", "delete_account", "stake", "deploy_base",
               "function_call_base", "delegate"}

\* A fee row: send_sir, send_not_sir, execution.
Row(ss, sn, ex) == [ss |-> ss, sn |-> sn, ex |-> ex]

SendPart(row, sir) == IF sir THEN row.ss ELSE row.sn

\* ===== Base fees, Ggas (exact gas in the comment) ==========================
BaseRow(pv, name) ==
  CASE name = "receipt"            -> Row(108, 108, 108)
         \* action_receipt_creation 108,059,500,000 x3          SNAP:9-13
    [] name = "data_receipt"       -> Row(36, 36, 36)
         \* data_receipt_creation_config.base_cost 36,486,732,312 x3   SNAP:14-19
    [] name = "create_account"     ->
         IF pv >= 85 THEN Row(500, 500, 7200)
         \* 500,000,000,000 / 500,000,000,000 / 7,200,000,000,000  SNAP85:27-31, 85.yaml:16-27
                     ELSE Row(3850, 3850, 3850)
         \* 3,850,000,000,000 x3                                 SNAP84:27-31
    [] name = "delete_account"     -> Row(147, 147, 147)
         \* 147,489,000,000 x3                                   SNAP:84-88
    [] name = "deploy_base"        -> Row(185, 185, 185)
         \* 184,765,750,000 x3                                   SNAP:32-36
    [] name = "function_call_base" -> Row(200, 200, 780)
         \* 200,000,000,000 / 200,000,000,000 / 780,000,000,000  SNAP:42-46
    [] name = "transfer"           -> Row(115, 115, 115)
         \* 115,123,062,500 x3                                   SNAP:52-56
    [] name = "stake"              -> Row(142, 142, 102)
         \* 141,715,687,500 / 141,715,687,500 / 102,217,625,000  SNAP:57-61
    [] name = "add_key_full"       -> Row(102, 102, 102)
         \* add_key_cost.full_access_cost 101,765,125,000 x3      SNAP:63-67
    [] name = "add_key_fc"         -> Row(102, 102, 102)
         \* add_key_cost.function_call_cost 102,217,625,000 x3    SNAP:68-72
    [] name = "delete_key"         -> Row(95, 95, 95)
         \* 94,946,625,000 x3                                    SNAP:79-83
    [] name = "delegate"           -> Row(200, 200, 200)
         \* 200,000,000,000 x3                                   SNAP:89-93
    [] OTHER -> Assert(FALSE, "NearFees: unknown base fee name")

\* ===== Per-byte fees, uGgas per byte (exact gas per byte in the comment) ===
ByteRow(pv, name) ==
  CASE name = "data_receipt_byte"  -> Row(17212, 47684, 17212)
         \* 17,212,011 / 47,683,715 / 17,212,011                SNAP:20-24
    [] name = "deploy_byte"        -> Row(6813, 47684, 64573)
         \* 6,812,999 / 47,683,715 / 64,572,944                  SNAP:37-41
    [] name = "function_call_byte" -> Row(2236, 47684, 2236)
         \* 2,235,934 / 47,683,715 / 2,235,934                   SNAP:47-51
    [] name = "add_key_fc_byte"    -> Row(1925, 47684, 1925)
         \* 1,925,331 / 47,683,715 / 1,925,331                   SNAP:73-77
    [] OTHER -> Assert(FALSE, "NearFees: unknown per-byte fee name")

\* n bytes at u uGgas/byte, in Ggas, rounded to the nearest Ggas.
\* m is the product in milli-Ggas (truncated below 1 mGgas). With n <= 16 MiB
\* and u <= 64573 every intermediate value is below 1.1e9.
Bytes(n, u) ==
  LET h == n \div 1000
      l == n % 1000
      m == h * u + (l * u) \div 1000
  IN  (m + 500) \div 1000

\* ===== Receipt base ========================================================
\* Charged once per created action receipt, whatever its actions
\* (host.rs:2351-2352 at creation; runtime/runtime/src/lib.rs:911-914 at
\* execution).
ReceiptSendFeeAt(pv, sir) == SendPart(BaseRow(pv, "receipt"), sir)
ReceiptExecFeeAt(pv)      == BaseRow(pv, "receipt").ex
ReceiptFeeAt(pv, sir)     == ReceiptSendFeeAt(pv, sir) + ReceiptExecFeeAt(pv)

\* ===== Actions (base part) =================================================
\* Transfer, by receiver kind (cost.rs:812-848 send, :775-810 exec).
TransferSendAt(pv, sir, kind) ==
  LET t == SendPart(BaseRow(pv, "transfer"), sir)
      c == SendPart(BaseRow(pv, "create_account"), sir)
      k == SendPart(BaseRow(pv, "add_key_full"), sir)
  IN  CASE kind = "named"                            -> t
        [] kind = "near_implicit"                    -> t + c + k
        [] kind \in {"eth_implicit", "deterministic"} -> t + c
        [] kind = "universal" -> IF UniversalAccountsOn(pv) THEN t + c ELSE t
        [] OTHER -> Assert(FALSE, "NearFees: unknown receiver kind")

TransferExecAt(pv, kind) ==
  LET t == BaseRow(pv, "transfer").ex
      c == BaseRow(pv, "create_account").ex
      k == BaseRow(pv, "add_key_full").ex
  IN  CASE kind = "named"                            -> t
        [] kind = "near_implicit"                    -> t + c + k
        [] kind \in {"eth_implicit", "deterministic"} -> t + c
        [] kind = "universal" -> IF UniversalAccountsOn(pv) THEN t + c ELSE t
        [] OTHER -> Assert(FALSE, "NearFees: unknown receiver kind")

CheckAction(a) == IF a \in FeeActions THEN TRUE
                  ELSE Assert(FALSE, "NearFees: unknown action")

\* Send part of one action (burnt by the creator at creation). For actions
\* other than "transfer", kind is ignored. "add_key_fc", "deploy_base" and
\* "function_call_base" are the base parts only; add the per-byte operators.
SendFeeAt(pv, action, sir, kind) ==
  IF CheckAction(action) /\ action = "transfer"
  THEN TransferSendAt(pv, sir, kind)
  ELSE SendPart(BaseRow(pv, action), sir)

\* Exec part of one action (prepaid by the creator, burnt when it executes).
ExecFeeAt(pv, action, kind) ==
  IF CheckAction(action) /\ action = "transfer"
  THEN TransferExecAt(pv, kind)
  ELSE BaseRow(pv, action).ex

ActionFeeAt(pv, action, sir, kind) ==
  SendFeeAt(pv, action, sir, kind) + ExecFeeAt(pv, action, kind)

\* ===== Actions (per-byte part) =============================================
\* FunctionCall: n = len(method_name) + len(args)
\*   (host.rs:3562 for promises; config.rs:109-118 for transactions).
FunctionCallBytesSendFeeAt(pv, sir, n) == Bytes(n, SendPart(ByteRow(pv, "function_call_byte"), sir))
FunctionCallBytesExecFeeAt(pv, n)      == Bytes(n, ByteRow(pv, "function_call_byte").ex)
FunctionCallBytesFeeAt(pv, sir, n) ==
  FunctionCallBytesSendFeeAt(pv, sir, n) + FunctionCallBytesExecFeeAt(pv, n)

\* AddKey with a function-call permission: n = sum over the allowed method
\* names of (len(name) + 1), the +1 being a terminator byte
\* (runtime/runtime/src/config.rs:264-269 and :432-437; host.rs:4078). The
\* receiver id and allowance are not charged per byte.
AddKeyFcBytesSendFeeAt(pv, sir, n) == Bytes(n, SendPart(ByteRow(pv, "add_key_fc_byte"), sir))
AddKeyFcBytesExecFeeAt(pv, n)      == Bytes(n, ByteRow(pv, "add_key_fc_byte").ex)
AddKeyFcBytesFeeAt(pv, sir, n) ==
  AddKeyFcBytesSendFeeAt(pv, sir, n) + AddKeyFcBytesExecFeeAt(pv, n)

\* DeployContract: n = code length (config.rs:99-108).
DeployBytesSendFeeAt(pv, sir, n) == Bytes(n, SendPart(ByteRow(pv, "deploy_byte"), sir))
DeployBytesExecFeeAt(pv, n)      == Bytes(n, ByteRow(pv, "deploy_byte").ex)
DeployBytesFeeAt(pv, sir, n) ==
  DeployBytesSendFeeAt(pv, sir, n) + DeployBytesExecFeeAt(pv, n)

\* ===== Data receipts (promise results) =====================================
\* A .then receipt with d dependencies: the creator burns, for each dependency,
\* the data receipt base send + exec (host.rs:2353-2360). sameAcct is TRUE
\* when the dependency's receiver equals the callback's receiver
\* (host.rs:2636-2640).
DataDepFeeAt(pv, sameAcct) ==
  SendPart(BaseRow(pv, "data_receipt"), sameAcct) + BaseRow(pv, "data_receipt").ex

\* value_return of n bytes: for EACH waiting receiver, the returning receipt
\* burns n * (data_receipt_byte send + exec) (host.rs:4695-4746). sir is TRUE
\* when that receiver is the returning account itself.
DataBytesFeeAt(pv, sir, n) ==
  Bytes(n, SendPart(ByteRow(pv, "data_receipt_byte"), sir))
  + Bytes(n, ByteRow(pv, "data_receipt_byte").ex)

\* ===== Whole receipts ======================================================
\* A receipt holding exactly one action: receipt base + that action.
OneActionReceiptFeeAt(pv, action, sir, kind) ==
  ReceiptFeeAt(pv, sir) + ActionFeeAt(pv, action, sir, kind)

\* A single-action Transfer receipt: everything its creator pays for it,
\* implicit-account creation included. This INCLUDES the receipt base fee
\* (108 + 108 Ggas). A receipt that batches Transfer with other actions pays
\* the receipt base once: use ReceiptFee + the ActionFee of each action.
TransferSendTotalAt(pv, sir, kind) == ReceiptSendFeeAt(pv, sir) + TransferSendAt(pv, sir, kind)
TransferExecTotalAt(pv, kind)      == ReceiptExecFeeAt(pv) + TransferExecAt(pv, kind)
TransferFeeTotalAt(pv, sir, kind) ==
  TransferSendTotalAt(pv, sir, kind) + TransferExecTotalAt(pv, kind)

\* The exec gas prepaid for a receipt with one FunctionCall of n bytes
\* (method name + args): receipt base exec + call base exec + per-byte exec.
\* This is nearcore's prepaid_exec_fees for that receipt
\* (runtime/runtime/src/lib.rs:1299-1302). The child's own static gas comes on
\* top of it.
OneCallReceiptExecFeeAt(pv, n) ==
  ReceiptExecFeeAt(pv) + BaseRow(pv, "function_call_base").ex
  + FunctionCallBytesExecFeeAt(pv, n)

\* ===== Defaults: the same operators at FeeProtocol ==========================
ReceiptSendFee(sir) == ReceiptSendFeeAt(FeeProtocol, sir)
ReceiptExecFee      == ReceiptExecFeeAt(FeeProtocol)
ReceiptFee(sir)     == ReceiptFeeAt(FeeProtocol, sir)

SendFee(action, sir, kind)   == SendFeeAt(FeeProtocol, action, sir, kind)
ExecFee(action, kind)        == ExecFeeAt(FeeProtocol, action, kind)
ActionFee(action, sir, kind) == ActionFeeAt(FeeProtocol, action, sir, kind)

FunctionCallBytesSendFee(sir, n) == FunctionCallBytesSendFeeAt(FeeProtocol, sir, n)
FunctionCallBytesExecFee(n)      == FunctionCallBytesExecFeeAt(FeeProtocol, n)
FunctionCallBytesFee(sir, n)     == FunctionCallBytesFeeAt(FeeProtocol, sir, n)
AddKeyFcBytesSendFee(sir, n)     == AddKeyFcBytesSendFeeAt(FeeProtocol, sir, n)
AddKeyFcBytesExecFee(n)          == AddKeyFcBytesExecFeeAt(FeeProtocol, n)
AddKeyFcBytesFee(sir, n)         == AddKeyFcBytesFeeAt(FeeProtocol, sir, n)
DeployBytesSendFee(sir, n)       == DeployBytesSendFeeAt(FeeProtocol, sir, n)
DeployBytesExecFee(n)            == DeployBytesExecFeeAt(FeeProtocol, n)
DeployBytesFee(sir, n)           == DeployBytesFeeAt(FeeProtocol, sir, n)

DataDepFee(sameAcct)    == DataDepFeeAt(FeeProtocol, sameAcct)
DataBytesFee(sir, n)    == DataBytesFeeAt(FeeProtocol, sir, n)

OneActionReceiptFee(action, sir, kind) == OneActionReceiptFeeAt(FeeProtocol, action, sir, kind)
TransferSendTotal(sir, kind) == TransferSendTotalAt(FeeProtocol, sir, kind)
TransferExecTotal(kind)      == TransferExecTotalAt(FeeProtocol, kind)
TransferFeeTotal(sir, kind)  == TransferFeeTotalAt(FeeProtocol, sir, kind)
OneCallReceiptExecFee(n)     == OneCallReceiptExecFeeAt(FeeProtocol, n)

\* ===== Self-checks (TLC evaluates these whenever the module is loaded) ======
\* Exact-gas totals they reproduce, from the nearcore values above:
\*   named Transfer, any version 84-88: 2 x (108.0595 + 115.1231) = 446.36 Ggas
\*   eth-implicit Transfer, 85-88: send 723.18 + exec 7423.18 = 8146.36 Ggas
\*   eth-implicit Transfer, 84:    send 4073.18 + exec 4073.18 = 8146.36 Ggas
ASSUME \A pv \in FeeVersions, s \in BOOLEAN :
         TransferFeeTotalAt(pv, s, "named") = 446
ASSUME \A pv \in {85, 86, 87, 88} :
         /\ TransferSendTotalAt(pv, FALSE, "eth_implicit") = 723
         /\ TransferExecTotalAt(pv, "eth_implicit") = 7423
ASSUME /\ TransferSendTotalAt(84, FALSE, "eth_implicit") = 4073
       /\ TransferExecTotalAt(84, "eth_implicit") = 4073
ASSUME \A pv \in FeeVersions :
         TransferFeeTotalAt(pv, FALSE, "eth_implicit") = 8146
ASSUME \A pv \in FeeVersions, a \in FeeActions, s \in BOOLEAN, k \in RcvKinds :
         ActionFeeAt(pv, a, s, k) = SendFeeAt(pv, a, s, k) + ExecFeeAt(pv, a, k)
ASSUME /\ Bytes(0, 47684) = 0
       /\ Bytes(1000, 47684) = 48
       /\ Bytes(4194304, 64573) = 270839
=============================================================================
