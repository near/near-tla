//! calibrate: sweep a flow spec's transactions over prepaid-gas grids in
//! near-contract-sim, check nearcore's leftover split against the declared
//! statics and weights, and emit the per-(method, path) burns as a TLA+
//! table with its provenance. See README.md.
//!
//!   calibrate --flows FILE [--wasm PATH] [--flow NAME]... [--grid G]
//!             [--data DIR] [--from-data [--force-data]]
//!             [--merge-accts a,..] [--accts a,..]
//!             [--tla OUT.tla [--module NAME] [--prefix P] [--params a,..]
//!              [--group acct:Prefix[:param]]... [--note TEXT]... [--notes FILE]
//!              [--allow-partial]] [--batch-actions]
//!
//! A table is written only if every check passed: every function-call
//! child's attached gas reproduced (single-call parents directly,
//! multi-call parents per action), no child lacked a declared static,
//! every action-only child's fees were computed, every size read, and
//! every merged key's largest burn was seen at the top of a grid.
//! `--allow-partial` writes it anyway, with the failures in its header.
//! Each sweep's JSONL has a `<flow>.meta.json` beside it (provenance, and
//! the JSONL's sha256 and point count). Once its grid has run, a sweep
//! publishes the pair under an exclusive lock on `<flow>.lock`: it removes
//! the old meta, writes the JSONL whole (unique temp file, rename), then
//! the new meta, whose sha256 is that of the bytes it wrote. So an
//! interrupted sweep leaves no meta that vouches for other data, and two
//! concurrent sweeps of a flow leave one sweep's pair, not a mix.
//! `--from-data` refuses data whose provenance differs from the current
//! wasm, flows file, sim or grid, or whose JSONL does not match its meta's
//! sha256, point count and grid, unless `--force-data` (also recorded).
use near_tla_conformance::calib::{self, Burns, SplitReport, Table};
use near_tla_conformance::spec::{self, Resolved};
use near_tla_conformance::{Provenance, edges, jsonl, lock_beside, provenance, sha256_hex, sweep, write_atomic};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::BufRead;
use std::path::{Path, PathBuf};

fn usage() -> ! {
    eprintln!(
        "usage: calibrate --flows FILE [--wasm PATH] [--flow NAME]... [--grid standard|smoke|lo:hi:step]\n\
         \x20                [--data DIR] [--from-data [--force-data]] [--merge-accts a,b] [--accts a,b]\n\
         \x20                [--tla OUT.tla [--module NAME] [--prefix P] [--params a,b] [--group acct:Prefix[:param]]...\n\
         \x20                 [--note TEXT]... [--notes FILE] [--allow-partial]] [--batch-actions]"
    );
    std::process::exit(2)
}

fn list(v: String) -> Vec<String> {
    v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()
}

/// The command line as run, for the header: home directory as `~`.
fn command_line() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut out = vec!["calibrate".to_owned()];
    for a in std::env::args().skip(1) {
        let a = if !home.is_empty() { a.replace(&home, "~") } else { a };
        out.push(if a.is_empty() || a.contains([' ', '\'', '"', '$', '(', ')', ';']) { format!("'{}'", a.replace('\'', "'\\''")) } else { a });
    }
    out.join(" ")
}

/// The provenance a sweep's JSONL carries (its `.meta.json`). The data's
/// own `jsonl_sha256` is added after the sweep (`bind`).
fn meta(prov: &Provenance, wasms: &[(String, String, String, String)], flows_name: &str, flows_sha: &str, grid: &str, points: usize) -> Value {
    json!({
        "sim_rev": prov.sim_rev,
        "nearcore_tag": prov.nearcore_tag,
        "nearcore_rev": prov.nearcore_rev,
        "protocol_version": prov.protocol_version,
        "wasms": wasms.iter().map(|(id, file, sha, _)| json!({"id": id, "file": file, "sha256": sha})).collect::<Vec<_>>(),
        "flows_file": flows_name,
        "flows_sha256": flows_sha,
        "grid": grid,
        "points": points,
    })
}

fn meta_path(jsonl: &Path) -> PathBuf {
    jsonl.with_extension("meta.json")
}

/// `meta` bound to the JSONL bytes it describes.
fn bind(meta: &Value, jsonl: &[u8]) -> Value {
    let mut m = meta.clone();
    m["jsonl_sha256"] = json!(sha256_hex(jsonl));
    m
}

/// Publishes a sweep of the grid `g` as the pair `path` (JSONL) and its
/// meta (`want` bound to the JSONL bytes): under the flow's exclusive lock,
/// removes the old meta, writes the JSONL, then the meta. The sha256 is of
/// the bytes written, never of the file reread, and the lock keeps another
/// publisher of the flow out until the pair is whole. Returns the meta.
fn publish(path: &Path, want: &Value, lines: &[Value], g: &[u64]) -> Value {
    publish_with(path, want, lines, g, &|| {})
}

/// `publish`, calling `between` after the JSONL is written and before the
/// meta is (a test's hook into that window).
fn publish_with(path: &Path, want: &Value, lines: &[Value], g: &[u64], between: &dyn Fn()) -> Value {
    let bytes = jsonl(lines).into_bytes();
    let m = bind(want, &bytes);
    let bad = data_mismatch(&m, &bytes, lines, g);
    assert!(bad.is_empty(), "{}: sweep does not match its grid: {}", path.display(), bad.join("; "));
    let mp = meta_path(path);
    let _lock = lock_beside(path, true).unwrap_or_else(|e| panic!("{}: lock: {e}", path.display()));
    // The old meta goes first: until the new one is written, the JSONL has
    // no provenance and no reader accepts it.
    match std::fs::remove_file(&mp) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => panic!("{}: {e}", mp.display()),
        _ => {}
    }
    write_atomic(path, &bytes).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    between();
    let text = serde_json::to_string_pretty(&m).unwrap() + "\n";
    write_atomic(&mp, text.as_bytes()).unwrap_or_else(|e| panic!("{}: {e}", mp.display()));
    m
}

/// A stored sweep: its meta (`Null` if absent or unreadable) and its JSONL
/// bytes, read together under the flow's shared lock, so no publisher can
/// replace one between the two reads.
fn read_stored(path: &Path) -> (Value, Vec<u8>) {
    let _lock = lock_beside(path, false).unwrap_or_else(|e| panic!("{}: lock: {e}", path.display()));
    let got: Value = std::fs::read_to_string(meta_path(path))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    (got, bytes)
}

/// What is wrong with a stored sweep against its meta: the JSONL's sha256
/// and point count, and its points against the grid `g` (gas, in order).
fn data_mismatch(meta: &Value, bytes: &[u8], lines: &[Value], g: &[u64]) -> Vec<String> {
    let mut out = vec![];
    let sha = sha256_hex(bytes);
    match meta.get("jsonl_sha256").and_then(Value::as_str) {
        None => out.push("meta has no jsonl_sha256 (an older sweep)".to_owned()),
        Some(s) if s != sha => out.push(format!("JSONL sha256 {sha}, meta says {s}")),
        _ => {}
    }
    if meta.get("points").and_then(Value::as_u64) != Some(lines.len() as u64) {
        out.push(format!("JSONL has {} points, meta says {}", lines.len(), meta.get("points").unwrap_or(&Value::Null)));
    }
    let got: Vec<Option<u64>> = lines.iter().map(|v| v["gas"].as_u64()).collect();
    let want: Vec<Option<u64>> = g.iter().copied().map(Some).collect();
    if got != want {
        out.push(format!("JSONL points are not the grid's {} (in order, each once)", g.len()));
    }
    out
}

fn main() {
    let mut a = std::env::args().skip(1);
    let (mut flows_path, mut wasm, mut only, mut grid, mut data, mut tla, mut module, mut prefix, mut params) =
        (None, None, vec![], None, None, None, None, String::new(), vec![]);
    let (mut from_data, mut force_data, mut allow_partial, mut batch_actions) = (false, false, false, false);
    let (mut merge, mut accts, mut groups, mut notes): (Vec<String>, Vec<String>, Vec<String>, Vec<String>) = (vec![], vec![], vec![], vec![]);
    while let Some(x) = a.next() {
        let mut val = || a.next().unwrap_or_else(|| usage());
        match x.as_str() {
            "--flows" => flows_path = Some(PathBuf::from(val())),
            "--wasm" => wasm = Some(PathBuf::from(val())),
            "--flow" => only.push(val()),
            "--grid" => grid = Some(val()),
            "--data" => data = Some(PathBuf::from(val())),
            "--tla" => tla = Some(PathBuf::from(val())),
            "--module" => module = Some(val()),
            "--prefix" => prefix = val(),
            "--params" => params = list(val()),
            "--from-data" => from_data = true,
            "--force-data" => force_data = true,
            "--allow-partial" => allow_partial = true,
            "--batch-actions" => batch_actions = true,
            "--merge-accts" => merge = list(val()),
            "--group" => groups.push(val()),
            "--note" => notes.push(val()),
            "--notes" => {
                let f = val();
                let t = std::fs::read_to_string(&f).unwrap_or_else(|e| panic!("{f}: {e}"));
                notes.extend(t.lines().map(|l| l.trim_end().to_owned()));
            }
            "--accts" => accts = list(val()),
            _ => usage(),
        }
    }
    let flows_path = flows_path.unwrap_or_else(|| usage());
    let flows_bytes = std::fs::read(&flows_path).unwrap_or_else(|e| panic!("{}: {e}", flows_path.display()));
    let flows_sha = sha256_hex(&flows_bytes);
    let flows_name = flows_path.file_name().unwrap().to_string_lossy().into_owned();
    let res = Resolved::new(&flows_path, wasm);
    let stem = flows_path.file_stem().unwrap().to_string_lossy().into_owned();
    let data = data.unwrap_or_else(|| near_tla_conformance::crate_dir().join("data").join(&stem));
    let base = res.world();
    let prov = provenance(&base);
    let wasms = res.wasms();
    println!("sim {} | nearcore {} ({}) | protocol {}", prov.sim_rev, prov.nearcore_tag, prov.nearcore_rev, prov.protocol_version);
    println!("flows {flows_name} sha256 {flows_sha}");
    for (id, file, sha, src) in &wasms {
        println!("  {id}: {file} sha256 {sha} {src}");
    }

    let mut split = SplitReport::default();
    let mut burns = Burns::default();
    let mut data_warn: Vec<String> = vec![];
    let mut grids: BTreeMap<String, usize> = BTreeMap::new();
    for flow in &res.spec.flows {
        if !only.is_empty() && !only.contains(&flow.name) {
            continue;
        }
        let path = data.join(format!("{}.jsonl", flow.name));
        let gname = grid.clone().unwrap_or_else(|| flow.grid.clone());
        let g = spec::parse_grid(&gname);
        let want = meta(&prov, &wasms, &flows_name, &flows_sha, &gname, g.len());
        let lines: Vec<Value> = if from_data {
            let mp = meta_path(&path);
            let (got, bytes) = read_stored(&path);
            let diff: Vec<String> = want
                .as_object()
                .unwrap()
                .iter()
                .filter(|(k, v)| got.get(k.as_str()) != Some(v))
                .map(|(k, v)| format!("{k}: data {} now {v}", got.get(k.as_str()).unwrap_or(&Value::Null)))
                .collect();
            if !diff.is_empty() {
                let msg = format!("{}: data provenance differs ({}): {}", flow.name, mp.file_name().unwrap().to_string_lossy(), diff.join("; "));
                if !force_data {
                    eprintln!("{msg}\nre-sweep (drop --from-data), or pass --force-data to use it anyway");
                    std::process::exit(1);
                }
                eprintln!("warning: {msg}");
                data_warn.push(msg);
            }
            let lines: Vec<Value> = bytes
                .as_slice()
                .lines()
                .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
                .collect();
            let bad = data_mismatch(&got, &bytes, &lines, &g);
            if !bad.is_empty() {
                let msg = format!("{}: data does not match its provenance: {}", flow.name, bad.join("; "));
                if !force_data {
                    eprintln!("{msg}\nre-sweep (drop --from-data), or pass --force-data to use it anyway");
                    std::process::exit(1);
                }
                eprintln!("warning: {msg}");
                data_warn.push(msg);
            }
            lines
        } else {
            let w = res.flow_world(&base, flow);
            let t0 = std::time::Instant::now();
            let lines = sweep(&flow.name, &w, &g, &|sim, gas| spec::run_flow(sim, flow, gas), None);
            publish(&path, &want, &lines, &g);
            eprintln!("{}: {} points in {:.1}s", flow.name, g.len(), t0.elapsed().as_secs_f64());
            lines
        };
        *grids.entry(format!("{gname} ({} points)", lines.len())).or_default() += 1;
        let e = edges(&lines);
        println!("\n== {} ({} points){}", flow.name, lines.len(), if flow.about.is_empty() { String::new() } else { format!(": {}", flow.about) });
        for (t, s) in &e {
            println!("   @{t:6.1} Tgas  {s}");
        }
        calib::check_split(&res, flow, &lines, &mut split);
        calib::collect_burns(&base, &res, flow, &lines, &mut burns);
    }

    println!(
        "\nsplit rule: {} function-call children checked ({} of them per action, under multi-call receipts), {} mismatches, worst |diff| = {} gas",
        split.children, split.multi_children, split.mismatches, split.worst
    );
    if split.skipped_parents + split.unchecked > 0 {
        println!("  NOT CHECKED: {} parents skipped, {} children unchecked", split.skipped_parents, split.unchecked);
    }
    for n in &split.notes {
        println!("  {n}");
    }
    if !split.per_action.is_empty() {
        println!("\nmulti-call receipts (top of grid): burn of the last action / of the earlier ones, Ggas");
        for (f, k, last, earlier) in &split.per_action {
            println!("  {f}: {k}: {last:.3} / {earlier:.3}");
        }
    }
    for n in &burns.notes {
        println!("  note: {n}");
    }
    let mut ao_bad = 0;
    let mut ao_seen: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    for (_f, rx, got, want) in &burns.ao_checks {
        if got != want {
            ao_bad += 1;
        }
        ao_seen.insert(rx.clone(), (*got, *want));
    }
    if !ao_seen.is_empty() {
        println!("\naction-only children: exec fee measured vs fee table ({ao_bad} differ)");
        for (rx, (got, want)) in &ao_seen {
            println!("  {rx}: measured {got} table {want}{}", if got == want { "" } else { "  DIFFERS" });
        }
    }
    let (mut rows, merge_warn) = calib::burn_rows(&burns, &merge);
    let mut pa_fail: Vec<String> = vec![];
    if batch_actions {
        let (extra, fail) = per_action_rows(&res, &rows, &split);
        rows.extend(extra);
        rows.sort_by(|x, y| (&x.acct, &x.key).cmp(&(&y.acct, &y.key)));
        pa_fail = fail;
    }
    println!("\n| key | children | burn base Ggas | per (Ggas/size) | points | spread Tgas | flows |");
    println!("|---|---|---:|---:|---:|---|---|");
    for r in &rows {
        println!(
            "| {}.{} | {} | {} | {:.4} | {} | {:.3}-{:.3} | {} |",
            r.acct,
            r.key,
            if r.shape.is_empty() { "-" } else { &r.shape },
            r.base,
            r.per_exact,
            r.n,
            r.spread.0 as f64 / 1e12,
            r.spread.1 as f64 / 1e12,
            r.flows.join(" ")
        );
    }
    println!("\nchild exec fees (prepaid by the creator), Ggas:");
    for (k, fs) in &burns.fees {
        println!("  {k}: {}", fs.iter().map(|f| format!("{:.3}", *f as f64 / 1e9)).collect::<Vec<_>>().join(" / "));
    }
    if !burns.never_ok.is_empty() {
        println!("\nnever succeeded (no burn measured): {}", burns.never_ok.iter().cloned().collect::<Vec<_>>().join(", "));
    }

    // Everything that blocks a table.
    let mut failed: Vec<String> = vec![];
    if split.children == 0 {
        failed.push("no function-call child was checked".into());
    }
    if split.mismatches > 0 {
        failed.push(format!("{} split mismatches (worst {} gas)", split.mismatches, split.worst));
    }
    if ao_bad > 0 {
        failed.push(format!("{ao_bad} action-only children's exec fees differ from the fee table"));
    }
    failed.extend(split.errors.iter().cloned());
    failed.extend(burns.errors.iter().cloned());
    failed.extend(merge_warn.iter().cloned());
    failed.extend(pa_fail.iter().cloned());
    failed.extend(data_warn.iter().cloned());
    if !failed.is_empty() {
        println!("\nchecks FAILED:");
        for f in &failed {
            println!("  - {f}");
        }
    } else {
        println!("\nall checks passed");
    }

    let Some(out) = tla else {
        std::process::exit(if failed.is_empty() { 0 } else { 1 });
    };
    if !failed.is_empty() && !allow_partial {
        eprintln!("not writing {}: {} check(s) failed (see above; --allow-partial writes it with them in the header)", out.display(), failed.len());
        std::process::exit(1);
    }
    let module = module.unwrap_or_else(|| out.file_stem().unwrap().to_string_lossy().into_owned());
    // Every child seen: its measured exec fee (largest), and its static
    // and weights: the spec-level [[static]] (the creating contract's
    // code) if there is one, else the flows' [[flow.static]] (a probe's
    // choice as the caller) if they all agree.
    let matches = |st: &spec::Static, acct: &str, m: &str| -> bool {
        // "<receiver account id>.<methods>": method names have no dots.
        let Some((rx, ms)) = st.child.rsplit_once('.') else { return false };
        let mk = res.spec.flows.iter().find_map(|f| f.keys.get(ms)).or_else(|| res.spec.world.keys.get(ms)).map(|s| s.as_str()).unwrap_or(ms);
        res.name(rx) == acct && (mk == m || ms == m)
    };
    let decls_of = |sts: &mut dyn Iterator<Item = &spec::Static>, acct: &str, m: &str| -> (BTreeSet<Vec<[u64; 2]>>, bool) {
        let (mut d, mut rel) = (BTreeSet::new(), false);
        for st in sts.filter(|st| matches(st, acct, m)) {
            if st.prepaid_minus_ggas.is_some() {
                rel = true;
            } else {
                d.insert(st.actions.clone());
            }
        }
        (d, rel)
    };
    let mut calls = vec![];
    for (k, fs) in &burns.fees {
        let (acct, m) = k.split_once('.').unwrap();
        if !accts.is_empty() && !accts.iter().any(|a| a == acct) {
            continue;
        }
        let (g, grel) = decls_of(&mut res.spec.statics.iter(), acct, m);
        let (f, frel) = decls_of(&mut res.spec.flows.iter().flat_map(|f| f.statics.iter()), acct, m);
        let (acts, cmt) = if g.len() == 1 && !grel {
            (g.into_iter().next().unwrap(), String::new())
        } else if g.is_empty() && !grel && f.len() == 1 && !frel {
            (f.into_iter().next().unwrap(), "static/weight as the probe flows' caller declared them".to_owned())
        } else if g.is_empty() && f.is_empty() && !grel && !frel {
            (vec![], "no static declared".to_owned())
        } else {
            (vec![], "static/weight vary by caller: set them with WithCall".to_owned())
        };
        let fee = *fs.iter().max().unwrap();
        calls.push((acct.to_owned(), m.to_owned(), acts, fee.div_ceil(1_000_000_000), cmt));
    }
    let rows: Vec<_> = rows.iter().filter(|r| accts.is_empty() || accts.contains(&r.acct)).cloned().collect();
    calls.sort();
    calls.dedup();
    let mut tables = vec![];
    if groups.is_empty() {
        tables.push(Table { prefix: prefix.clone(), params: params.clone(), rows: rows.clone(), calls: calls.clone() });
    }
    for g in &groups {
        // acct:Prefix[:param]: the table's parameter is `param` (default acct).
        let mut it = g.splitn(3, ':');
        let (Some(acct), Some(pre)) = (it.next(), it.next()) else { usage() };
        let param = it.next().unwrap_or(acct);
        tables.push(Table {
            prefix: pre.to_owned(),
            params: vec![param.to_owned()],
            rows: rows.iter().filter(|r| r.acct == acct).map(|r| calib::BurnRow { acct: param.to_owned(), ..r.clone() }).collect(),
            calls: calls.iter().filter(|c| c.0 == acct).map(|c| (param.to_owned(), c.1.clone(), c.2.clone(), c.3, c.4.clone())).collect(),
        });
    }
    let mut data_lines = vec![format!("flows: {flows_name} sha256 {flows_sha}")];
    for (g, n) in &grids {
        data_lines.push(format!("grid: {g}, {n} flow{}", if *n == 1 { "" } else { "s" }));
    }
    data_lines.push(format!(
        "split check: {} children, {} mismatches; {} per action",
        split.children, split.mismatches, split.multi_children
    ));
    let text = calib::emit_tla(&module, &prov, &wasms, &tables, &command_line(), &data_lines, &notes, if failed.is_empty() { &[] } else { &failed });
    std::fs::write(&out, text).unwrap();
    println!("\nwrote {}{}", out.display(), if failed.is_empty() { "" } else { " (PARTIAL)" });
}

/// With `--batch-actions`: the burn of each call in a multi-call receipt
/// key `K` (methods m1+..+mn), as `K#mi` = burn of the receipt holding
/// m1..mi minus that of m1..m(i-1). The prefixes must be calibrated keys
/// of the same account (by `world.keys` or a flow's `keys`). The last
/// call's burn is checked against the per-action split check's inference
/// where that ran (a receipt whose last call creates weighted children).
fn per_action_rows(res: &Resolved, rows: &[calib::BurnRow], split: &SplitReport) -> (Vec<calib::BurnRow>, Vec<String>) {
    let fwd = |raw: &str| -> Option<String> {
        res.spec.world.keys.get(raw).or_else(|| res.spec.flows.iter().find_map(|f| f.keys.get(raw))).cloned()
    };
    let mut rev: BTreeMap<String, String> = BTreeMap::new();
    for (raw, mk) in res.spec.world.keys.iter().chain(res.spec.flows.iter().flat_map(|f| f.keys.iter())) {
        rev.insert(mk.clone(), raw.clone());
    }
    let (mut out, mut fail) = (vec![], vec![]);
    for r in rows {
        let Some(raw) = rev.get(&r.key) else { continue };
        let ms: Vec<&str> = raw.split('+').collect();
        if ms.len() < 2 {
            continue;
        }
        let mut prev = 0i64;
        let mut acts = vec![];
        for i in 1..=ms.len() {
            let pre = ms[..i].join("+");
            let base = fwd(&pre).and_then(|mk| rows.iter().find(|x| x.acct == r.acct && x.key == mk)).map(|x| x.base_exact.round() as i64);
            let Some(b) = base else {
                fail.push(format!("{}.{}: no calibrated receipt for the prefix {pre}: per-call burns not derived", r.acct, r.key));
                acts.clear();
                break;
            };
            if b < prev {
                fail.push(format!("{}.{}: prefix {pre} burns less than the one before it", r.acct, r.key));
            }
            acts.push((ms[i - 1], (b - prev).max(0) as u64)); // gas
            prev = b;
        }
        if acts.is_empty() {
            continue;
        }
        let acts: Vec<(&str, u64)> = acts.into_iter().map(|(m, g)| (m, g.div_ceil(1_000_000_000))).collect();
        let last = acts.last().unwrap();
        let suffix = format!(".{raw} -> ");
        for (f, k, inferred, _) in &split.per_action {
            if res.name(k.split(&suffix).next().unwrap_or("")) == r.acct && k.contains(&suffix) {
                let d = (inferred - last.1 as f64).abs();
                println!("  per-call burn {}.{}#{}: {} by prefixes, {:.1} inferred in {f}", r.acct, r.key, last.0, last.1, inferred);
                if d > 1.5 {
                    fail.push(format!("{}.{}#{}: {} by prefixes but {inferred:.1} inferred from the split ({f})", r.acct, r.key, last.0, last.1));
                }
            }
        }
        for (m, b) in acts {
            out.push(calib::BurnRow {
                acct: r.acct.clone(),
                key: format!("{}#{m}", r.key),
                shape: String::new(),
                base: b,
                base_exact: (b * 1_000_000_000) as f64,
                failure: false,
                per: 0,
                per_exact: 0.0,
                max_resid_gas: 0.0,
                n: 1,
                flows: r.flows.clone(),
                spread: (b * 1_000_000_000, b * 1_000_000_000),
            });
        }
    }
    (out, fail)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(g: &[u64]) -> (Vec<Value>, Vec<u8>) {
        let lines: Vec<Value> = g.iter().map(|&x| json!({"flow": "f", "gas": x})).collect();
        let bytes = near_tla_conformance::jsonl(&lines).into_bytes();
        (lines, bytes)
    }

    /// Two sweeps of one flow published concurrently: B publishes while A
    /// is between its JSONL and its meta. The pair left must be one
    /// sweep's: the meta's provenance is that of the sweep whose bytes are
    /// on disk, and its sha256 and points bind them.
    #[test]
    fn concurrent_publish_leaves_one_sweeps_pair() {
        use std::sync::mpsc;
        let dir = std::env::temp_dir().join(format!("near-tla-calib-{}-pub", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("f.jsonl");
        let g = [1, 2, 3];
        let sweep_of = |who: &str| -> (Value, Vec<Value>) {
            let lines = g.iter().map(|&x| json!({"flow": "f", "gas": x, "by": who})).collect();
            (json!({"points": 3, "flows_sha256": who}), lines)
        };
        let (want_a, lines_a) = sweep_of("A");
        let (want_b, lines_b) = sweep_of("B");
        std::thread::scope(|s| {
            let b_thread = std::cell::RefCell::new(None);
            publish_with(&path, &want_a, &lines_a, &g, &|| {
                // B runs now; wait until it has published, or until it is
                // plainly held back (by the lock).
                let (tx, rx) = mpsc::channel();
                let (path, want_b, lines_b, g) = (&path, &want_b, &lines_b, &g);
                *b_thread.borrow_mut() = Some(s.spawn(move || {
                    publish(path, want_b, lines_b, g);
                    let _ = tx.send(());
                }));
                let _ = rx.recv_timeout(std::time::Duration::from_millis(500));
            });
            b_thread.into_inner().unwrap().join().unwrap();
        });
        let (meta, bytes) = read_stored(&path);
        let lines: Vec<Value> = bytes.as_slice().lines().map(|l| serde_json::from_str(&l.unwrap()).unwrap()).collect();
        assert!(data_mismatch(&meta, &bytes, &lines, &g).is_empty(), "meta not bound to the JSONL: {meta}");
        let data_by = lines[0]["by"].as_str().unwrap();
        assert_eq!(meta["flows_sha256"], json!(data_by), "provenance of one sweep, data of the other");
        let mut left: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        left.sort();
        assert_eq!(left, ["f.jsonl", "f.lock", "f.meta.json"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn data_mismatch_binds_meta_to_jsonl() {
        let g = [1, 2, 3];
        let (lines, bytes) = data(&g);
        let meta = bind(&json!({"points": 3}), &bytes);
        assert!(data_mismatch(&meta, &bytes, &lines, &g).is_empty());
        // truncated after the meta was written
        let (l2, b2) = data(&g[..2]);
        assert_eq!(data_mismatch(&meta, &b2, &l2, &g).len(), 3);
        // empty
        assert_eq!(data_mismatch(&meta, b"", &[], &g).len(), 3);
        // a meta from before jsonl_sha256
        assert_eq!(data_mismatch(&json!({"points": 3}), &bytes, &lines, &g).len(), 1);
        // duplicated point, meta bound to it
        let (l3, b3) = data(&[1, 2, 2]);
        assert_eq!(data_mismatch(&bind(&json!({"points": 3}), &b3), &b3, &l3, &g).len(), 1);
    }
}
