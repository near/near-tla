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
\* SNAP85, SNAP87 and SNAP88. Between 84 and 88 the only fee IN THIS TABLE that
\* changes is create_account (85.yaml:16-27). Fees outside the table also change:
\* action_deterministic_state_init at 85 (85.yaml:28-39) and the universal
\* state-init per-entry and per-byte fees at 88 (88.yaml:14-45). State-init
\* actions are not modelled.
\*
\* ---------------------------------------------------------------------------
\* Units and rounding
\* ---------------------------------------------------------------------------
\* - FeeRounding (below) selects the rounding: "up" (the default) or
\*   "nearest" (the earlier rounding). Every table entry is rounded on its own
\*   to a whole Ggas, and every exported operator is a SUM of table entries,
\*   so the parts add up exactly in both modes: SendFee + ExecFee = ActionFee,
\*   and ReceiptFee + ActionFee = the single-action receipt total.
\* - Per-byte fees are stored in micro-Ggas per byte (1 uGgas = 1e-6 Ggas =
\*   1000 gas), rounded to a whole uGgas the same way. Bytes(n, u) multiplies
\*   and rounds the product once to a whole Ggas. It never forms a product
\*   above about 1.1e9, so it stays inside TLC's 32-bit integers for n up to
\*   16 MiB. Every protocol limit on a byte count is below that: arguments,
\*   return data and contract size are all at most 4 MiB at 88
\*   (SNAP88:248-252).
\* - Error bounds, "up": every base entry is over by less than 1 Ggas and
\*   never under; Bytes(n, u) is over by less than 1.001 + 1e-6 * n Ggas and
\*   never under (u rounded up, then the product). A single-action receipt
\*   total (receipt base + one action, send + exec = 4 base entries) is over
\*   by less than 4 Ggas (a named Transfer: 450 against 446.37), plus the
\*   per-byte terms. As far as these fees go, a prepaid amount the model
\*   finds enough is enough in nearcore; the price is a false out-of-gas
\*   within that margin.
\* - Error bounds, "nearest": a base entry is off by at most 0.5 Ggas.
\*   Bytes(n, u) is off by at most 0.5 Ggas (final rounding) + 0.001 Ggas
\*   (truncation) + 0.5e-6 * n Ggas (u rounded to the uGgas), i.e. <= 0.51
\*   Ggas for n <= 20 KB and <= 2.6 Ggas at n = 4 MiB. The errors can go
\*   either way: a single-action receipt total is off by at most ~3 Ggas for
\*   byte counts up to a few KB, and may be UNDERSTATED, so a prepaid amount
\*   up to that much short can pass in the model and run out of gas in
\*   nearcore (examples/fee-edge).
\* A gas edge predicted from these fees is only accurate to these bounds
\* (docs/SEMANTICS.md, N-precision).
\*
\* ---------------------------------------------------------------------------
\* sir ("sender is receiver")
\* ---------------------------------------------------------------------------
\* sir = TRUE when the receipt's predecessor is also its receiver. For a promise
\* created by a contract, that means the receipt targets the creating contract
\* itself (runtime/near-vm-runner/src/logic/host.rs:2577, :2636, and
\* promise_idx_to_receipt_idx_with_sir at :2699-2715). For a transaction's first
\* receipt, it means signer = receiver (runtime/runtime/src/config.rs:489,
\* calculate_tx_cost; total_send_fees takes it at :86-90).
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
\*   "universal"      "0u" + 52 Crockford base32 whose last char is "0" or
\*                    "g" (validation.rs:117-124; 87+)
\*   "named"          anything else
\* Transfer fee by kind (cost.rs:775-848):
\*   named          transfer
\*   near_implicit  transfer + create_account + add_full_access_key
\*   eth_implicit   transfer + create_account   (eth_implicit_accounts is TRUE
\*                  at 84-88: SNAP84:231 .. SNAP88:231)
\*   deterministic  transfer + create_account   (no flag on the fee side: the
\*                  fee functions charge it unconditionally, cost.rs:805-807,
\*                  :844-846; the runtime's account-type check reuses
\*                  eth_implicit_accounts, actions.rs:899-927)
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
ASSUME FeeProtocol \in FeeVersions   \* also in FeeSelfChecks (runs through INSTANCE)

\* universal_accounts is on from 87 (SNAP87:232; version.rs:639).
UniversalAccountsOn(pv) == pv >= 87

RcvKinds == {"named", "near_implicit", "eth_implicit", "deterministic", "universal"}

FeeActions == {"transfer", "create_account", "add_key_full", "add_key_fc",
               "delete_key", "delete_account", "stake", "deploy_base",
               "function_call_base", "delegate"}

\* A fee row: send_sir, send_not_sir, execution.
Row(ss, sn, ex) == [ss |-> ss, sn |-> sn, ex |-> ex]

SendPart(row, sir) == IF sir THEN row.ss ELSE row.sn

\* ===== Rounding ============================================================
\* FeeRounding (below) selects how every table entry becomes a whole Ggas
\* (base fees) or a whole uGgas per byte (per-byte fees):
\*   "up"       rounded up (the default): no fee is ever understated, so a
\*              prepaid amount the model finds enough is enough in nearcore,
\*              as far as these fees go (docs/SEMANTICS.md, N-precision);
\*   "nearest"  rounded to the nearest (the earlier rounding): closest to
\*              nearcore's figures, but a fee can be understated by up to
\*              0.5 Ggas per entry.
\* Change it here, like FeeProtocol, or per run with
\*   "NearFees!FeeRounding" = '"nearest"'
\* in a runs.toml's [constants] (tools/run.py), which is TLC's
\*   FeeRounding <- [NearFees] <value>
\* and also reaches the NearFeeTable instance inside NearAsync.  NearAsync
\* reads it for the unused-gas split too: under "up" no child gets the
\* split's whole-Ggas remainder, so none gets more than in nearcore; under
\* "nearest" the last weighted child gets it (NearAsync, Share).
FeeRounding == "up"

FeeRoundingModes == {"nearest", "up"}

\* mGgas (1e6 gas) to Ggas, and gas to uGgas (1000 gas), by FeeRounding.
FeeRoundM(m) == IF FeeRounding = "up" THEN (m + 999) \div 1000 ELSE (m + 500) \div 1000
FeeRoundU(g) == IF FeeRounding = "up" THEN (g + 999) \div 1000 ELSE (g + 500) \div 1000

\* ===== Base fees ===========================================================
\* The source table is in mGgas (exact gas / 1e6, rounded up), with the exact
\* gas in the comment. BaseRow rounds each entry to a whole Ggas by
\* FeeRounding. Rounding up to the mGgas first moves no "nearest" value: no
\* entry's fraction of a Ggas lies in [0.4995, 0.5).
BaseRowM(pv, name) ==
  CASE name = "receipt"            -> <<108060, 108060, 108060>>
         \* action_receipt_creation 108,059,500,000 x3          SNAP:9-13
    [] name = "data_receipt"       -> <<36487, 36487, 36487>>
         \* data_receipt_creation_config.base_cost 36,486,732,312 x3   SNAP:14-19
    [] name = "create_account"     ->
         IF pv >= 85 THEN <<500000, 500000, 7200000>>
         \* 500,000,000,000 / 500,000,000,000 / 7,200,000,000,000  SNAP85:27-31, 85.yaml:16-27
                     ELSE <<3850000, 3850000, 3850000>>
         \* 3,850,000,000,000 x3                                 SNAP84:27-31
    [] name = "delete_account"     -> <<147489, 147489, 147489>>
         \* 147,489,000,000 x3                                   SNAP:84-88
    [] name = "deploy_base"        -> <<184766, 184766, 184766>>
         \* 184,765,750,000 x3                                   SNAP:32-36
    [] name = "function_call_base" -> <<200000, 200000, 780000>>
         \* 200,000,000,000 / 200,000,000,000 / 780,000,000,000  SNAP:42-46
    [] name = "transfer"           -> <<115124, 115124, 115124>>
         \* 115,123,062,500 x3                                   SNAP:52-56
    [] name = "stake"              -> <<141716, 141716, 102218>>
         \* 141,715,687,500 / 141,715,687,500 / 102,217,625,000  SNAP:57-61
    [] name = "add_key_full"       -> <<101766, 101766, 101766>>
         \* add_key_cost.full_access_cost 101,765,125,000 x3      SNAP:63-67
    [] name = "add_key_fc"         -> <<102218, 102218, 102218>>
         \* add_key_cost.function_call_cost 102,217,625,000 x3    SNAP:68-72
    [] name = "delete_key"         -> <<94947, 94947, 94947>>
         \* 94,946,625,000 x3                                    SNAP:79-83
    [] name = "delegate"           -> <<200000, 200000, 200000>>
         \* 200,000,000,000 x3                                   SNAP:89-93
    [] OTHER -> Assert(FALSE, "NearFees: unknown base fee name")

\* A base row in whole Ggas.
BaseRow(pv, name) ==
  LET t == BaseRowM(pv, name) IN Row(FeeRoundM(t[1]), FeeRoundM(t[2]), FeeRoundM(t[3]))

\* ===== Per-byte fees =======================================================
\* The source table is in exact gas per byte (every entry is below 2^31).
ByteRowG(pv, name) ==
  CASE name = "data_receipt_byte"  -> <<17212011, 47683715, 17212011>>
         \*                                                    SNAP:20-24
    [] name = "deploy_byte"        -> <<6812999, 47683715, 64572944>>
         \*                                                    SNAP:37-41
    [] name = "function_call_byte" -> <<2235934, 47683715, 2235934>>
         \*                                                    SNAP:47-51
    [] name = "add_key_fc_byte"    -> <<1925331, 47683715, 1925331>>
         \*                                                    SNAP:73-77
    [] OTHER -> Assert(FALSE, "NearFees: unknown per-byte fee name")

\* A per-byte row in uGgas per byte.
ByteRow(pv, name) ==
  LET t == ByteRowG(pv, name) IN Row(FeeRoundU(t[1]), FeeRoundU(t[2]), FeeRoundU(t[3]))

\* n bytes at u uGgas/byte, in Ggas. m is the product in milli-Ggas: "up"
\* rounds its sub-mGgas part and then the Ggas up; "nearest" truncates the
\* sub-mGgas part and rounds the Ggas to the nearest (as before). With
\* n <= 16 MiB and u <= 64573 every intermediate value is below 1.1e9.
Bytes(n, u) ==
  LET h == n \div 1000
      l == n % 1000
      m == h * u + (IF FeeRounding = "up" THEN (l * u + 999) \div 1000 ELSE (l * u) \div 1000)
  IN  FeeRoundM(m)

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

\* ===== Self-checks =========================================================
\* FeeSelfChecks holds iff FeeRounding is a known mode and the table
\* reproduces these totals in that mode, from the exact gas above:
\*   named Transfer, any version 84-88: 2 x (108.0595 + 115.1231) = 446.36 Ggas
\*     "nearest": 2 x (108 + 115) = 446    "up": 2 x (109 + 116) = 450
\*   eth-implicit Transfer, 85-88: send 723.18 + exec 7423.18 = 8146.36 Ggas
\*     "nearest": 723 + 7423 = 8146        "up": 725 + 7425 = 8150
\*   eth-implicit Transfer, 84:    send 4073.18 + exec 4073.18 = 8146.36 Ggas
\*     "nearest": 4073 + 4073 = 8146       "up": 4075 + 4075 = 8150
\* and Send + Exec = Action for every entry, which holds in both modes because
\* each entry is rounded on its own.
\*
\* TLC evaluates an ASSUME only in the modules a spec EXTENDS, never in an
\* INSTANCEd one. So the ASSUME below runs for a model that EXTENDS NearFees,
\* and NearAsync, which reaches the table through INSTANCE (NearFeeTable),
\* repeats it as ASSUME NearFeeTable!FeeSelfChecks, so it runs for every model
\* on the library, with any per-run FeeRounding.
FeePin(nearest, up) == IF FeeRounding = "up" THEN up ELSE nearest

FeeSelfChecks ==
  /\ Assert(FeeRounding \in FeeRoundingModes,
            <<"NearFees: FeeRounding must be \"nearest\" or \"up\"", FeeRounding>>)
  /\ Assert(FeeProtocol \in FeeVersions, <<"NearFees: FeeProtocol not covered", FeeProtocol>>)
  /\ Assert(
       /\ \A pv \in FeeVersions, s \in BOOLEAN :
            TransferFeeTotalAt(pv, s, "named") = FeePin(446, 450)
       /\ \A pv \in {85, 86, 87, 88} :
            /\ TransferSendTotalAt(pv, FALSE, "eth_implicit") = FeePin(723, 725)
            /\ TransferExecTotalAt(pv, "eth_implicit") = FeePin(7423, 7425)
       /\ TransferSendTotalAt(84, FALSE, "eth_implicit") = FeePin(4073, 4075)
       /\ TransferExecTotalAt(84, "eth_implicit") = FeePin(4073, 4075)
       /\ \A pv \in FeeVersions :
            TransferFeeTotalAt(pv, FALSE, "eth_implicit") = FeePin(8146, 8150)
       /\ \A pv \in FeeVersions, a \in FeeActions, s \in BOOLEAN, k \in RcvKinds :
            ActionFeeAt(pv, a, s, k) = SendFeeAt(pv, a, s, k) + ExecFeeAt(pv, a, k)
       /\ Bytes(0, 47684) = 0
       /\ Bytes(1, 47684) = FeePin(0, 1)
       /\ Bytes(1000, 47684) = 48
       /\ Bytes(4194304, 64573) = 270839,
       <<"NearFees: the fee table does not reproduce its pinned totals", FeeRounding>>)

ASSUME FeeSelfChecks
=============================================================================
