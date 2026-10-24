//! calibrate: sweep a flow spec's transactions over prepaid-gas grids in
//! near-contract-sim, check nearcore's leftover split against the declared
//! statics and weights, and emit the per-(method, path) burns as a TLA+
//! table with its provenance. See README.md.
//!
//!   calibrate --flows FILE [--wasm PATH] [--flow NAME]... [--grid G]
//!             [--data DIR] [--from-data] [--merge-accts a,..] [--accts a,..]
//!             [--tla OUT.tla [--module NAME] [--prefix P] [--params a,..]
//!              [--group acct:Prefix]... [--note TEXT]...]
use near_tla_conformance::calib::{self, Burns, SplitReport};
use near_tla_conformance::spec::{self, Resolved};
use near_tla_conformance::{edges, provenance, sweep};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::BufRead;
use std::path::PathBuf;

fn usage() -> ! {
    eprintln!(
        "usage: calibrate --flows FILE [--wasm PATH] [--flow NAME]... [--grid standard|smoke|lo:hi:step]\n\
         \x20                [--data DIR] [--from-data] [--tla OUT.tla --module NAME [--prefix P] [--params a,b] [--merge-accts a,b] [--accts a,b]\n\
         \x20                 [--group acct:Prefix]... [--note TEXT]...]"
    );
    std::process::exit(2)
}

fn main() {
    let mut a = std::env::args().skip(1);
    let (mut flows_path, mut wasm, mut only, mut grid, mut data, mut tla, mut module, mut prefix, mut params, mut from_data, mut merge, mut accts, mut groups, mut notes) =
        (None, None, vec![], None, None, None, None, String::new(), vec![], false, vec![], vec![], vec![], vec![]);
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
            "--params" => params = val().split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect(),
            "--from-data" => from_data = true,
            "--merge-accts" => merge = val().split(',').map(|s| s.trim().to_owned()).collect(),
            "--group" => groups.push(val()),
            "--note" => notes.push(val()),
            "--accts" => accts = val().split(',').map(|s| s.trim().to_owned()).collect(),
            _ => usage(),
        }
    }
    let flows_path = flows_path.unwrap_or_else(|| usage());
    let res = Resolved::new(&flows_path, wasm);
    let stem = flows_path.file_stem().unwrap().to_string_lossy().into_owned();
    let data = data.unwrap_or_else(|| near_tla_conformance::crate_dir().join("data").join(&stem));
    let base = res.world();
    let prov = provenance(&base);
    println!("sim {} | nearcore {} ({}) | protocol {}", prov.sim_rev, prov.nearcore_tag, prov.nearcore_rev, prov.protocol_version);
    for (id, file, sha, src) in res.wasms() {
        println!("  {id}: {file} sha256 {sha} {src}");
    }

    let mut split = SplitReport::default();
    let mut burns = Burns::default();
    for flow in &res.spec.flows {
        if !only.is_empty() && !only.contains(&flow.name) {
            continue;
        }
        let path = data.join(format!("{}.jsonl", flow.name));
        let lines: Vec<Value> = if from_data {
            std::io::BufReader::new(std::fs::File::open(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display())))
                .lines()
                .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
                .collect()
        } else {
            let g = spec::parse_grid(grid.as_deref().unwrap_or(&flow.grid));
            let w = res.flow_world(&base, flow);
            let tx = flow.tx.clone();
            let t0 = std::time::Instant::now();
            let lines = sweep(&flow.name, &w, &g, &|sim, gas| spec::run(sim, &tx, Some(gas)), Some(&path));
            eprintln!("{}: {} points in {:.1}s", flow.name, g.len(), t0.elapsed().as_secs_f64());
            lines
        };
        let e = edges(&lines);
        println!("\n== {} ({} points){}", flow.name, lines.len(), if flow.about.is_empty() { String::new() } else { format!(": {}", flow.about) });
        for (t, s) in &e {
            println!("   @{t:6.1} Tgas  {s}");
        }
        calib::check_split(&res, flow, &lines, &mut split);
        calib::collect_burns(&base, &res, flow, &lines, &mut burns);
    }

    println!(
        "\nsplit rule: {} child receipts checked, {} mismatches, worst |diff| = {} gas",
        split.children, split.mismatches, split.worst
    );
    if split.batch_children > 0 {
        println!(
            "  (children of multi-call receipts, not exact by construction: {} seen, worst |diff| {} gas)",
            split.batch_children, split.batch_worst
        );
    }
    for n in &split.notes {
        println!("  {n}");
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
        println!("\naction-only children: exec fee measured vs fee table ({} differ)", ao_bad);
        for (rx, (got, want)) in &ao_seen {
            println!("  {rx}: measured {got} table {want}{}", if got == want { "" } else { "  DIFFERS" });
        }
    }
    let rows = calib::burn_rows(&burns, &merge);
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
    if let Some(out) = tla {
        if split.mismatches > 0 || split.children == 0 {
            eprintln!("split check failed ({} mismatches, {} children checked): not emitting {}", split.mismatches, split.children, out.display());
            std::process::exit(1);
        }
        let module = module.unwrap_or_else(|| out.file_stem().unwrap().to_string_lossy().into_owned());
        // Every child seen: its measured exec fee (largest), and the
        // declared static/weight when the spec declares one globally.
        let mut calls = vec![];
        for (k, fs) in &burns.fees {
            let (acct, m) = k.split_once('.').unwrap();
            if !accts.is_empty() && !accts.iter().any(|a| a == acct) {
                continue;
            }
            let decl = res.spec.statics.iter().find(|st| {
                st.prepaid_minus_ggas.is_none() && !st.actions.is_empty() && {
                    let (rx, mm) = st.child.rsplit_once(".near.").map(|(a, b)| (format!("{a}.near"), b.to_owned())).unwrap_or_default();
                    res.name(&rx) == acct && res.spec.world.keys.get(&mm).unwrap_or(&mm) == m
                }
            });
            let acts: Vec<[u64; 2]> = decl.map(|d| d.actions.clone()).unwrap_or_default();
            let fee = *fs.iter().max().unwrap();
            calls.push((acct.to_owned(), m.to_owned(), acts, (fee as f64 / 1e9).round() as u64));
        }
        let rows: Vec<_> = rows.iter().filter(|r| accts.is_empty() || accts.contains(&r.acct)).cloned().collect();
        calls.sort();
        calls.dedup();
        let mut cmd = format!("calibrate --flows {}", flows_path.file_name().unwrap().to_string_lossy());
        if let Some(g) = &grid {
            cmd += &format!(" --grid {g}");
        }
        if !merge.is_empty() {
            cmd += &format!(" --merge-accts {}", merge.join(","));
        }
        if !accts.is_empty() {
            cmd += &format!(" --accts {}", accts.join(","));
        }
        let mut tables = vec![];
        if groups.is_empty() {
            tables.push(calib::Table { prefix: prefix.clone(), params: params.clone(), rows: rows.clone(), calls: calls.clone() });
        }
        for g in &groups {
            let (acct, pre) = g.split_once(':').unwrap_or_else(|| usage());
            cmd += &format!(" --group {g}");
            tables.push(calib::Table {
                prefix: pre.to_owned(),
                params: vec![acct.to_owned()],
                rows: rows.iter().filter(|r| r.acct == acct).cloned().collect(),
                calls: calls.iter().filter(|c| c.0 == acct).cloned().collect(),
            });
        }
        let text = calib::emit_tla(&module, &prov, &res.wasms(), &tables, &cmd, &notes);
        std::fs::write(&out, text).unwrap();
        println!("\nwrote {}", out.display());
    }
}
