#!/usr/bin/env python3
"""state.py — Margie's single source of truth about work in flight (Tom, 2026-09-22).

Reads the dispatch folders (~/.margie/dispatch), GitLab's last successful production
deploy, and git ancestry, and emits ONE structured picture: every ticket with its real
state, its MR and what it is waiting on, every epic with its merged and remaining
tickets BY NAME, what is waiting on Tom, and which merged tickets are live in
production. Answers and evals read this instead of parsing prose status lines — prose
is how "7/11 merged" hid PT-1461 and how "is it live?" got read off the wrong pipeline.

    state.sh json                 the whole picture (JSON)
    state.sh waiting              what is waiting on Tom, one line each
    state.sh ticket <PT-n|!n>     one ticket (JSON)
    state.sh summary              a short plain-text digest (for prompts)

Read-only. Deterministic: every field is read from a file, GitLab, or git — nothing is
inferred from wording. Merged tickets older than 14 days are left out.
"""
import json, os, subprocess, sys, time, glob, re

HOME = os.path.expanduser("~")
MDIR = os.path.join(HOME, ".margie", "dispatch")
CFG = os.path.join(HOME, ".margie", "config.json")
RECENT_DAYS = 14


def cfg(key, default=None):
    try:
        return json.load(open(CFG)).get(key, default)
    except Exception:
        return default


def rd(path, default=""):
    try:
        return open(path).read().strip()
    except Exception:
        return default


def rj(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def sh(cmd, cwd=None, timeout=20):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


_prod_cache = {}


def production(repo):
    """The commit production last deployed successfully, and when."""
    if repo in _prod_cache:
        return _prod_cache[repo]
    env = cfg("deploy_environment", "production")
    out = sh(["glab", "api", f"projects/:id/deployments?environment={env}&status=success&order_by=id&sort=desc&per_page=1"], cwd=repo)
    d = {}
    try:
        j = json.loads(out)[0]
        d = {"sha": j.get("sha", ""), "at": (j.get("finished_at") or j.get("updated_at") or "")[:16].replace("T", " ") + " UTC"}
    except Exception:
        pass
    _prod_cache[repo] = d
    return d


_fetched = set()


def is_live(repo, pt, iid):
    """True/False/None: is this ticket's merge an ancestor of what production runs?"""
    prod = production(repo)
    if not prod.get("sha"):
        return None
    target = cfg("mr_target_branch", "main")
    if repo not in _fetched:
        sh(["git", "fetch", "-q", "origin", target], cwd=repo, timeout=30)
        _fetched.add(repo)
    commit = ""
    if pt:
        commit = sh(["git", "log", f"origin/{target}", "--format=%H", "--grep", pt, "-1"], cwd=repo)
    if not commit:
        return None
    r = subprocess.run(["git", "merge-base", "--is-ancestor", commit, prod["sha"]], cwd=repo, capture_output=True)
    return r.returncode == 0


def ticket_record(d, with_live=True):
    name = os.path.basename(d)
    meta = rj(os.path.join(d, "d.json")) or {}
    tk = rj(os.path.join(d, "ticket.json")) or {}
    spec = rj(os.path.join(d, "spec.json")) or {}
    st = rd(os.path.join(d, "state"), "unknown")
    mr = rj(os.path.join(d, "mr.json")) or {}
    chk = rj(os.path.join(d, "mr-check.json")) or {}
    sha = chk.get("sha", "")
    rec = {
        "id": name,
        "pt": tk.get("pt"),
        "title": spec.get("title") or rd(os.path.join(d, "request.txt"))[:90],
        "state": st,
        "epic": rd(os.path.join(d, "parent")) or None,
        "key": rd(os.path.join(d, "key")) or None,
        "repo": meta.get("repo"),
        "ticket_url": tk.get("url"),
        "mr": None,
        "held": rd(os.path.join(d, "hold-merge")) or None,
        "waiting_on": None,
        "live": None,
    }
    if mr.get("iid"):
        ui = os.path.exists(os.path.join(d, "ui-verify-kicked"))
        rec["mr"] = {
            "iid": mr.get("iid"),
            "url": mr.get("url"),
            "state": chk.get("state"),
            "pipeline": chk.get("pipeline"),
            "open_threads": chk.get("unresolved"),
            "conflicts": chk.get("conflicts"),
            "review_approved": bool(sha) and rd(os.path.join(d, "review-approved")) == sha,
            "ui_change": ui,
            "screenshot_shown": bool(sha) and rd(os.path.join(d, "ui-verified-sha")) == sha,
        }
    rec["waiting_on"] = waiting_on(rec)
    if with_live and st == "closed" and rec["repo"]:
        rec["live"] = is_live(rec["repo"], rec["pt"], (rec["mr"] or {}).get("iid"))
    return rec


def waiting_on(r):
    st, m = r["state"], r["mr"] or {}
    if st == "closed":
        return None
    if r["held"]:
        return "tom: held — " + r["held"][:160]
    if st == "spec-ready":
        return "tom: say go to file and start it"
    if st in ("spec-running",):
        return "margie: planning"
    if st in ("implementing",):
        return "margie: coding"
    if st in ("qa-running",):
        return "margie: QA"
    if st == "qa-fail":
        return "margie: fixing QA findings"
    if st == "filed":
        return "margie: queued — starts when its turn in the epic comes"
    if m:
        if m.get("conflicts"):
            return "margie: resolving merge conflicts"
        if m.get("pipeline") in ("running", "pending", "created"):
            return "ci: pipeline running"
        if m.get("pipeline") == "failed":
            return "margie: pipeline failed"
        if m.get("open_threads"):
            return "margie: answering review threads"
        if not m.get("review_approved"):
            return "margie: review"
        if m.get("ui_change") and not m.get("screenshot_shown"):
            return "margie: taking the UI screenshot"
        if m.get("ui_change"):
            return f"tom: look at the screenshot and merge !{m.get('iid')}"
        return "margie: merging (backend auto-merges when green)"
    return f"margie: {st}"


def epic_record(d, children):
    bd = rj(os.path.join(d, "breakdown.json")) or {}
    tks = {t.get("key"): t for t in (rj(os.path.join(d, "tickets.json")) or [])}
    name = os.path.basename(d)
    spec = rj(os.path.join(d, "spec.json")) or {}
    done_spikes = {os.path.basename(p)[len("spike-resolved-"):] for p in glob.glob(os.path.join(d, "spike-resolved-*"))}
    merged, remaining, on_tom = [], [], []
    for t in bd.get("tickets", []):
        key, pt = t.get("key"), (tks.get(t.get("key")) or {}).get("pt")
        if t.get("spike"):
            if t.get("needs_from_owner") and key not in done_spikes:
                on_tom.append({"pt": pt, "title": t.get("title"), "needs": t.get("needs_from_owner")})
            continue
        c = children.get(f"{name}--{key}")
        row = {"pt": pt, "key": key, "title": t.get("title"), "state": c["state"] if c else "not started",
               "mr": (c or {}).get("mr", {}) and c["mr"].get("iid"), "live": (c or {}).get("live")}
        (merged if row["state"] == "closed" else remaining).append(row)
    return {"id": name, "pt": (rj(os.path.join(d, "ticket.json")) or {}).get("pt"), "title": spec.get("title"),
            "state": rd(os.path.join(d, "state")), "merged": merged, "remaining": remaining, "spikes_on_tom": on_tom}


def build():
    now = time.time()
    dirs = sorted(glob.glob(os.path.join(MDIR, "d-*")))
    tickets, children, epics = [], {}, []
    for d in dirs:
        st = rd(os.path.join(d, "state"))
        age_days = (now - os.path.getmtime(d)) / 86400
        if st == "closed" and age_days > RECENT_DAYS:
            continue
        if os.path.exists(os.path.join(d, "breakdown.json")) and "--" not in os.path.basename(d):
            continue  # epics are assembled below
        r = ticket_record(d)
        tickets.append(r)
        children[r["id"]] = r
    for d in dirs:
        if os.path.exists(os.path.join(d, "breakdown.json")) and "--" not in os.path.basename(d):
            if rd(os.path.join(d, "state")) == "closed" and (now - os.path.getmtime(d)) / 86400 > RECENT_DAYS:
                continue
            epics.append(epic_record(d, children))
    waiting = [{"pt": t["pt"], "title": t["title"], "mr": (t["mr"] or {}).get("iid"), "what": t["waiting_on"][5:]}
               for t in tickets if (t["waiting_on"] or "").startswith("tom")]
    for e in epics:
        for s in e["spikes_on_tom"]:
            waiting.append({"pt": s["pt"], "title": s["title"], "mr": None, "what": "spike needs: " + "; ".join(s["needs"])[:200]})
    repo = next((t["repo"] for t in tickets if t.get("repo")), None)
    return {"generated_at": time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime()),
            "production": production(repo) if repo else {},
            "waiting_on_tom": waiting, "epics": epics,
            "tickets": [t for t in tickets if t["state"] != "closed"],
            "recently_merged": [t for t in tickets if t["state"] == "closed"]}


def line(t):
    mr = f" !{t['mr']['iid']}" if t.get("mr") else ""
    live = "" if t.get("live") is None else (" — live in production" if t["live"] else " — merged, not in production yet")
    return f"{t.get('pt') or t['id']}{mr} {t['title'][:70]} — {t['state']}{live}" + (f" — waiting on {t['waiting_on']}" if t.get("waiting_on") else "")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "summary"
    if cmd == "json":
        print(json.dumps(build(), indent=1)); return
    if cmd == "waiting":
        w = build()["waiting_on_tom"]
        if not w:
            print("Nothing is waiting on Tom."); return
        for x in w:
            print(f"{x['pt'] or ''}{' !' + str(x['mr']) if x['mr'] else ''} — {x['what']} ({(x['title'] or '')[:60]})")
        return
    if cmd == "ticket":
        q = (sys.argv[2] if len(sys.argv) > 2 else "").upper()
        if not q:
            print("usage: state.sh ticket <PT-n|!n>", file=sys.stderr); sys.exit(1)
        s = build()
        for t in s["tickets"] + s["recently_merged"]:
            if (t.get("pt") or "").upper() == q or (t.get("mr") and q.lstrip("!") == str(t["mr"]["iid"])):
                print(json.dumps(t, indent=1)); print(line(t)); return
        # an epic child that never started has no folder of its own
        for e in s["epics"]:
            for r in e["merged"] + e["remaining"]:
                if (r.get("pt") or "").upper() == q:
                    print(json.dumps(r, indent=1)); return
        print(f"{q}: not among the tickets Margie is tracking (in flight, or merged in the last {RECENT_DAYS} days).")
        return
    if cmd == "summary":
        s = build()
        p = s.get("production") or {}
        print(f"Production: {p.get('sha', '?')[:8]} deployed {p.get('at', '?')}")
        print("Waiting on Tom:" if s["waiting_on_tom"] else "Waiting on Tom: nothing")
        for x in s["waiting_on_tom"]:
            print(f"  • {x['pt'] or ''}{' !' + str(x['mr']) if x['mr'] else ''} — {x['what'][:140]}")
        print("In flight:")
        for t in s["tickets"]:
            print("  • " + line(t))
        for e in s["epics"]:
            if e["state"] == "closed":
                continue
            print(f"Epic {e['pt']} {e['title'][:60]}: {len(e['merged'])} merged, {len(e['remaining'])} remaining")
            for r in e["merged"]:
                print(f"  ✓ {r['pt']} {r['title'][:60]}" + (f" (!{r['mr']})" if r.get("mr") else "") +
                      ("" if r.get("live") is None else (" — live" if r["live"] else " — not in production yet")))
        return
    print("usage: state.sh json | waiting | ticket <PT-n|!n> | summary", file=sys.stderr); sys.exit(64)


if __name__ == "__main__":
    main()
