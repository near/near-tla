//! calibrate: sweep a flow spec's transactions over prepaid-gas grids in
//! near-contract-sim, check nearcore's leftover split against the declared
//! statics and weights, and emit the per-(method, path) burns as a TLA+
//! table with its provenance. See README.md.
//!
//!   calibrate --flows FILE [--wasm PATH] [--flow NAME]... [--grid G]
//!             [--data DIR] [--from-data [--force-data]]
//!             [--merge-accts a,..] [--accts a,..]
//!             [--tla OUT.tla [--module NAME] [--prefix P] [--params a,..]
//!              [--group acct:Prefix]... [--note TEXT]... [--notes FILE]
//!              [--allow-partial]]
//!
//! A table is written only if every check passed: every function-call
//! child's attached gas reproduced (single-call parents directly,
//! multi-call parents per action), no child lacked a declared static,
//! every action-only child's fees were computed, every size read, and
//! every merged key's largest burn was seen at the top of a grid.
//! `--allow-partial` writes it anyway, with the failures in its header.
//! Each sweep's JSONL has a `<flow>.meta.json` beside it (provenance);
//! `--from-data` refuses data whose provenance differs from the current
//! wasm, flows file, sim or grid unless `--force-data` (also recorded).
use near_tla_conformance::calib::{self, Burns, SplitReport, Table};
use near_tla_conformance::spec::{self, Resolved};
use near_tla_conformance::{Provenance, edges, provenance, sha256_hex, sweep};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::BufRead;
use std::path::{Path, PathBuf};

fn usage() -> ! {
    eprintln!(
        "usage: calibrate --flows FILE [--wasm PATH] [--flow NAME]... [--grid standard|smoke|lo:hi:step]\n\
         \x20                [--data DIR] [--from-data [--force-data]] [--merge-accts a,b] [--accts a,b]\n\
         \x20                [--tla OUT.tla [--module NAME] [--prefix P] [--params a,b] [--group acct:Prefix]...\n\
         \x20                 [--note TEXT]... [--notes FILE] [--allow-partial]]"
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

/// The provenance a sweep's JSONL carries (its `.meta.json`).
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

fn main() {
    let mut a = std::env::args().skip(1);
    let (mut flows_path, mut wasm, mut only, mut grid, mut data, mut tla, mut module, mut prefix, mut params) =
        (None, None, vec![], None, None, None, None, String::new(), vec![]);
    let (mut from_data, mut force_data, mut allow_partial) = (false, false, false);
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
            let got: Value = std::fs::read_to_string(&mp)
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or(Value::Null);
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
            std::io::BufReader::new(std::fs::File::open(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display())))
                .lines()
                .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
                .collect()
        } else {
            let w = res.flow_world(&base, flow);
            let tx = flow.tx.clone();
            let t0 = std::time::Instant::now();
            let lines = sweep(&flow.name, &w, &g, &|sim, gas| spec::run(sim, &tx, Some(gas)), Some(&path));
            std::fs::write(meta_path(&path), serde_json::to_string_pretty(&want).unwrap() + "\n").unwrap();
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
    let (rows, merge_warn) = calib::burn_rows(&burns, &merge);
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
        calls.push((acct.to_owned(), m.to_owned(), acts, (fee as f64 / 1e9).round() as u64, cmt));
    }
    let rows: Vec<_> = rows.iter().filter(|r| accts.is_empty() || accts.contains(&r.acct)).cloned().collect();
    calls.sort();
    calls.dedup();
    let mut tables = vec![];
    if groups.is_empty() {
        tables.push(Table { prefix: prefix.clone(), params: params.clone(), rows: rows.clone(), calls: calls.clone() });
    }
    for g in &groups {
        let (acct, pre) = g.split_once(':').unwrap_or_else(|| usage());
        tables.push(Table {
            prefix: pre.to_owned(),
            params: vec![acct.to_owned()],
            rows: rows.iter().filter(|r| r.acct == acct).cloned().collect(),
            calls: calls.iter().filter(|c| c.0 == acct).cloned().collect(),
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
