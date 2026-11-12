/* Schedule page: list, calendar, add/edit, spreadsheet import. Admin + Manager only. */
window.SCHED = (() => {
  const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  const pad = (n) => String(n).padStart(2, "0");
  const iso = (y, m, d) => `${y}-${pad(m)}-${pad(d)}`;
  const valid = (y, m, d) => { const t = new Date(y, m - 1, d); return t.getFullYear() === y && t.getMonth() === m - 1 && t.getDate() === d; };
  const toLocal = (s) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
  const todayIso = () => { const t = new Date(); return iso(t.getFullYear(), t.getMonth() + 1, t.getDate()); };

  /* ---------- services: the tracker's dropdown, built from three tick boxes ---------- */
  const SVC = [
    { key: "P", name: "Physical Security Personnel", short: "Guards", re: /personnel|guard|officer/i },
    { key: "S", name: "Security Screening Equipment", short: "Screening", re: /screen|equipment|opengate|mag|x-?ray/i },
    { key: "K", name: "Canine Teams", short: "K9", re: /canine|k-?9|dog/i }
  ];
  function svcKeys(text) {
    if (!text) return [];
    if (/\ball services\b/i.test(text)) return ["P", "S", "K"];
    return SVC.filter((s) => s.re.test(text)).map((s) => s.key);
  }
  function svcText(keys) {
    if (keys.length === 3) return "All Services";
    return SVC.filter((s) => keys.includes(s.key)).map((s) => s.name).join(" & ");
  }

  /* ---------- dates: "2026-10-08 to 2026-10-16", 11/9/2026, Nov 11-12 2026, Excel date numbers ---------- */
  function onePart(s, fallbackYear) {
    s = s.trim().replace(/(\d)(st|nd|rd|th)\b/gi, "$1").replace(/^[a-z]+day,?\s+/i, "");
    let m;
    if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) return [+m[1], +m[2], +m[3]];
    if ((m = s.match(/^(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?$/))) return [m[3] ? (m[3].length === 2 ? 2000 + +m[3] : +m[3]) : fallbackYear, +m[1], +m[2]];
    if ((m = s.match(/^([a-z]{3,})\.?\s+(\d{1,2}),?(?:\s+(\d{4}))?$/i)) && MONTHS.includes(m[1].slice(0, 3).toLowerCase()))
      return [m[3] ? +m[3] : fallbackYear, MONTHS.indexOf(m[1].slice(0, 3).toLowerCase()) + 1, +m[2]];
    if ((m = s.match(/^(\d{1,2})\s+([a-z]{3,})\.?,?(?:\s+(\d{4}))?$/i)) && MONTHS.includes(m[2].slice(0, 3).toLowerCase()))
      return [m[3] ? +m[3] : fallbackYear, MONTHS.indexOf(m[2].slice(0, 3).toLowerCase()) + 1, +m[1]];
    if ((m = s.match(/^(\d{1,2})$/))) return [null, null, +m[1]]; // "12" in "Nov 11-12"
    return null;
  }
  function parseDates(v, yearHint) {
    const year = yearHint || new Date().getFullYear();
    if (typeof v === "number" && v > 20000 && v < 80000) { // Excel stores dates as days since 1899-12-30
      const t = new Date(Date.UTC(1899, 11, 30) + Math.round(v) * 86400000);
      const s = iso(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()); return { start: s, end: s };
    }
    if (v instanceof Date) { const s = iso(v.getFullYear(), v.getMonth() + 1, v.getDate()); return { start: s, end: s }; }
    let s = String(v || "").trim(); if (!s) return null;
    s = s.replace(/T\d{2}:\d{2}.*$/, "");
    // "Nov 11-12, 2026" -> "Nov 11, 2026 to Nov 12, 2026"
    s = s.replace(/^([a-z]{3,}\.?)\s+(\d{1,2})\s*[-–—]\s*(\d{1,2}),?\s*(\d{4})?$/i, (_, mo, a, b, y) => `${mo} ${a}${y ? ", " + y : ""} to ${mo} ${b}${y ? ", " + y : ""}`);
    const parts = s.split(/\s+(?:to|through|thru|until|-|–|—)\s+|\s*[–—]\s*/i).filter(Boolean);
    const a = onePart(parts[0], year); if (!a || a[0] == null) return null;
    let b = parts[1] ? onePart(parts[1], a[0]) : a;
    if (!b) return null;
    if (b[0] == null) b = [a[0], a[1], b[2]];
    if (!valid(...a) || !valid(...b)) return null;
    const start = iso(...a), end = iso(...b);
    return end >= start ? { start, end } : { start, end: start };
  }

  /* ---------- import: find the header row and map columns by name ---------- */
  const COLS = [
    ["end_date", /\bend\b|\bto date\b|until/i],
    ["start_date", /date|start|day/i],
    ["client", /client|customer|company|account/i],
    ["contact", /contact|poc\b/i],
    ["times", /time|hours|shift/i],
    ["location", /location|venue|address|where|site/i],
    ["lead", /\blead\b|supervisor|manager/i],
    ["staffing", /staff/i],
    ["threat_level", /threat|risk/i],
    ["notes", /note|comment/i],
    ["services", /service/i] // last: "Times of Services" and "Location of Services" belong above
  ];
  function mapRows(rows) {
    const txt = (c) => (c == null ? "" : String(c)).trim();
    const hi = rows.findIndex((r) => r.some((c) => /client|customer/i.test(txt(c))) && r.some((c) => /date|day/i.test(txt(c))));
    if (hi < 0) return { error: "no_header" };
    const map = {};
    rows[hi].forEach((c, i) => {
      const h = txt(c); if (!h) return;
      const hit = COLS.find(([k, re]) => !(k in map) && re.test(h));
      if (hit) map[hit[0]] = i;
    });
    const year = new Date().getFullYear();
    const out = [];
    rows.slice(hi + 1).forEach((r, n) => {
      const get = (k) => (k in map ? r[map[k]] : "");
      if (!txt(get("client")) && !txt(get("start_date"))) return; // blank row
      const d = parseDates(get("start_date"), year);
      const e = "end_date" in map && txt(get("end_date")) ? parseDates(get("end_date"), d ? +d.start.slice(0, 4) : year) : null;
      const staffing = txt(get("staffing"));
      const threat = txt(get("threat_level"));
      const svc = txt(get("services")), keys = svcKeys(svc);
      out.push({
        line: hi + n + 2,
        problem: !d ? "Can't read the date: " + txt(get("start_date")) : !txt(get("client")) ? "No client" : null,
        start_date: d ? d.start : null,
        end_date: d ? (e && e.end >= d.start ? e.end : d.end) : null,
        client: txt(get("client")),
        contact: txt(get("contact")),
        services: keys.length ? svcText(keys) : svc,
        times: txt(get("times")),
        location: txt(get("location")),
        lead: txt(get("lead")),
        staffing: /^(un|not|no)/i.test(staffing) ? "Unstaffed" : /staff/i.test(staffing) ? "Staffed" : "",
        threat_level: /^(10|[1-9])(\.0+)?$/.test(threat) ? String(parseInt(threat, 10)) : "",
        notes: txt(get("notes"))
      });
    });
    return { rows: out };
  }

  /* ---------- counts for the tiles ---------- */
  const clientKey = (c) => String(c || "").replace(/\(.*?\)/g, "").replace(/[^a-z0-9]+/gi, " ").trim().toLowerCase();
  function counts(evs) {
    const has = (e, k) => svcKeys(e.services).includes(k);
    return {
      events: evs.length,
      clients: new Set(evs.map((e) => clientKey(e.client))).size,
      k9: evs.filter((e) => has(e, "K")).length,
      screening: evs.filter((e) => has(e, "S")).length,
      guards: evs.filter((e) => has(e, "P")).length,
      notStaffed: evs.filter((e) => !(e.staffing === "Staffed" && e.lead)).length
    };
  }

  function whenText(e) {
    const f = (s, opt) => toLocal(s).toLocaleDateString("en-US", opt);
    if (e.start_date === e.end_date) return f(e.start_date, { weekday: "short", month: "short", day: "numeric" });
    const sameMonth = e.start_date.slice(0, 7) === e.end_date.slice(0, 7);
    return f(e.start_date, { month: "short", day: "numeric" }) + " – " + (sameMonth ? +e.end_date.slice(8) : f(e.end_date, { month: "short", day: "numeric" }));
  }

  return { SVC, svcKeys, svcText, parseDates, mapRows, counts, whenText, toLocal, todayIso, iso, clientKey };
})();

if (typeof document !== "undefined" && window.IQ) (async () => {
  const S = window.SCHED;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const bar = IQ.topbar("schedule");
  try { await IQ.requireLogin({ staff: true, bar }); } catch { return; }

  let all = [];
  let view = "who";
  const now = new Date();
  let calY = now.getFullYear(), calM = now.getMonth(); // month shown in the calendar (0-11)
  let selDay = null;

  async function load() {
    try { all = await IQ.rpc("web_sched_list"); $("err").textContent = ""; }
    catch (e) { $("err").textContent = IQ.explain(e); all = []; }
    draw();
  }

  /* ---------- drawing ---------- */
  // Green once the event is Staffed AND has a lead; red until both are set.
  const cls = (e) => (e.staffing === "Staffed" && e.lead ? "staffed" : "unstaffed");
  const ready = (e) => e.staffing === "Staffed" && !!e.lead;
  // Everything the save function expects, from an event as listed.
  const asSave = (e) => ({ id: e.id, start_date: e.start_date, end_date: e.end_date, client: e.client || "", contact: e.contact || "",
    services: e.services || "", times: e.times || "", location: e.location || "", lead: e.lead || "", staffing: e.staffing || "",
    threat_level: e.threat_level ? String(e.threat_level) : "", notes: e.notes || "" });
  async function quickSet(e, change, btn) {
    btn.disabled = true;
    try { await IQ.rpc("web_sched_save", { p: { ...asSave(e), ...change } }); await load(); }
    catch (err) { btn.disabled = false; $("err").textContent = IQ.explain(err); }
  }
  function card(e) {
    const b = document.createElement("div");
    b.className = "ev " + cls(e); b.tabIndex = 0; b.setAttribute("role", "button");
    b.setAttribute("aria-label", S.whenText(e) + ", " + e.client + ". Open to edit.");
    const keys = S.svcKeys(e.services);
    const svcTags = keys.length ? S.SVC.filter((s) => keys.includes(s.key)).map((s) => `<span class="tag svc">${s.short}</span>`).join("")
      : e.services ? `<span class="tag svc">${esc(e.services)}</span>` : "";
    const staff = e.staffing === "Staffed" ? `<span class="tag in">Staffed</span>` : e.staffing === "Unstaffed" ? `<span class="tag dmg">Unstaffed</span>` : "";
    const tn = +e.threat_level;
    const th = tn ? `<span class="tag ${tn >= 7 ? "dmg" : tn >= 4 ? "med" : "in"}">Threat ${tn}/10</span>` : "";
    const needs = [!e.lead && "a lead", e.staffing !== "Staffed" && "staff"].filter(Boolean);
    b.innerHTML = `<div class="row1"><span class="when">${esc(S.whenText(e))}</span><span class="client">${esc(e.client)}</span></div>
      <div class="meta">${[e.location, e.times].filter(Boolean).map(esc).join("<br>")}</div>
      ${e.lead ? `<div class="meta">Lead: <b>${esc(e.lead)}</b></div>` : ""}
      ${needs.length ? `<div class="needs">Needs ${needs.join(" and ")}</div>` : ""}
      <div class="tags">${svcTags}${staff}${th}</div>`;
    if (needs.length && view !== "past") {
      const q = document.createElement("div"); q.className = "quick";
      if (!e.lead) {
        q.insertAdjacentHTML("beforeend", "<span>Lead:</span>");
        ["Joe", "Paul", "Kievon"].forEach((n) => {
          const x = document.createElement("button"); x.type = "button"; x.textContent = n;
          x.addEventListener("click", (ev) => { ev.stopPropagation(); quickSet(e, { lead: n }, x); });
          q.appendChild(x);
        });
      }
      if (e.staffing !== "Staffed") {
        const x = document.createElement("button"); x.type = "button"; x.className = "st"; x.textContent = "✓ Mark staffed";
        x.addEventListener("click", (ev) => { ev.stopPropagation(); quickSet(e, { staffing: "Staffed" }, x); });
        q.appendChild(x);
      }
      b.appendChild(q);
    }
    b.addEventListener("click", () => openEd(e));
    b.addEventListener("keydown", (ev) => { if ((ev.key === "Enter" || ev.key === " ") && ev.target === b) { ev.preventDefault(); openEd(e); } });
    return b;
  }

  // One line: how many events, what kind, and a button that shows only the ones still missing staff or a lead.
  let needOnly = false;
  const keep = (evs) => (needOnly ? evs.filter((e) => !ready(e)) : evs);
  function tiles(evs, label) {
    const c = S.counts(evs);
    const kinds = [[c.guards, c.guards === 1 ? "guard detail" : "guard details"], [c.screening, "screening"], [c.k9, "K9"]].filter(([n]) => n).map(([n, t]) => `${n} ${t}`).join(" · ");
    const box = $("tiles");
    box.innerHTML = `<span><b>${c.events}</b> event${c.events === 1 ? "" : "s"}${label}${kinds ? " · " + kinds : ""}</span>`;
    if (c.notStaffed || needOnly) {
      const nb = document.createElement("button"); nb.type = "button"; nb.className = "need"; nb.setAttribute("aria-pressed", String(needOnly));
      nb.textContent = needOnly ? "Showing only the " + c.notStaffed + " that need staff or a lead ✕" : c.notStaffed + " need staff or a lead";
      nb.addEventListener("click", () => { needOnly = !needOnly; if (view === "who" || view === "past") view = "up"; draw(); });
      box.appendChild(nb);
    } else if (c.events) box.insertAdjacentHTML("beforeend", `<span class="ok">✓ All staffed with a lead</span>`);
  }

  function drawList(evs, emptyText) {
    const box = $("listView"); box.replaceChildren();
    if (!evs.length) { box.innerHTML = `<p class="empty">${emptyText}</p>`; return; }
    let cur = null, sec;
    evs.forEach((e) => {
      const m = e.start_date.slice(0, 7);
      if (m !== cur) {
        cur = m; sec = document.createElement("section"); sec.className = "month";
        sec.innerHTML = `<h2>${S.toLocal(m + "-01").toLocaleDateString("en-US", { month: "long", year: "numeric" })}</h2>`;
        box.appendChild(sec);
      }
      sec.appendChild(card(e));
    });
  }

  function drawCal() {
    const first = new Date(calY, calM, 1);
    const mStart = S.iso(calY, calM + 1, 1), mEnd = S.iso(calY, calM + 1, new Date(calY, calM + 1, 0).getDate());
    $("mName").textContent = first.toLocaleDateString("en-US", { month: "long", year: "numeric" });
    const inMonth = all.filter((e) => e.end_date >= mStart && e.start_date <= mEnd);
    tiles(inMonth, " this month");
    const cal = $("cal"); cal.replaceChildren();
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].forEach((d) => cal.insertAdjacentHTML("beforeend", `<div class="dow">${d}</div>`));
    const start = new Date(calY, calM, 1 - first.getDay());
    const today = S.todayIso();
    for (let i = 0; i < 42; i++) {
      const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
      if (i >= 35 && d.getMonth() !== calM) break;
      const ds = S.iso(d.getFullYear(), d.getMonth() + 1, d.getDate());
      const evs = all.filter((e) => e.start_date <= ds && e.end_date >= ds);
      const cell = document.createElement("button"); cell.type = "button";
      cell.className = "day" + (d.getMonth() !== calM ? " out" : "") + (ds === today ? " today" : "") + (ds === selDay ? " sel" : "");
      cell.setAttribute("aria-label", d.toDateString() + ", " + evs.length + " events");
      cell.innerHTML = `<span class="n">${d.getDate()}</span>` + evs.slice(0, 3).map((e) => `<span class="chip2 ${cls(e)}">${esc(e.client)}</span>`).join("")
        + (evs.length > 3 ? `<span class="n">+${evs.length - 3}</span>` : "");
      cell.addEventListener("click", () => { selDay = ds; drawCal(); });
      cal.appendChild(cell);
    }
    const dl = $("dayList"); dl.replaceChildren();
    const shown = keep(selDay ? all.filter((e) => e.start_date <= selDay && e.end_date >= selDay) : inMonth);
    const h = document.createElement("h2"); h.style.marginTop = "18px";
    h.textContent = (selDay ? S.toLocal(selDay).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" }) : "All events this month") + (needOnly ? " · need staff or a lead" : "");
    dl.appendChild(h);
    if (!shown.length) dl.insertAdjacentHTML("beforeend", `<p class="empty" style="margin-top:4px">No events${selDay ? " on this day" : " this month"}.</p>`);
    shown.forEach((e) => dl.appendChild(card(e)));
  }

  function draw() {
    document.querySelectorAll("#views button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === view)));
    $("listView").hidden = view === "cal" || view === "who"; $("calView").hidden = view !== "cal"; $("whoView").hidden = view !== "who";
    const today = S.todayIso();
    if (view === "who") return drawWho();
    if (view === "cal") return drawCal();
    if (view === "up") {
      const evs = all.filter((e) => e.end_date >= today);
      tiles(evs, " coming up"); drawList(keep(evs), needOnly ? "Everything coming up is staffed with a lead." : "Nothing coming up. Tap + Add to put one in.");
    } else {
      const evs = all.filter((e) => e.end_date < today).reverse();
      tiles(evs, " done"); drawList(evs, "No past events yet.");
    }
  }

  document.querySelectorAll("#views button").forEach((b) => b.addEventListener("click", () => { view = b.dataset.v; draw(); }));
  $("prevM").addEventListener("click", () => { calM--; if (calM < 0) { calM = 11; calY--; } selDay = null; drawCal(); });
  $("nextM").addEventListener("click", () => { calM++; if (calM > 11) { calM = 0; calY++; } selDay = null; drawCal(); });

  /* ---------- who's where: one square per person per day ---------- */
  const PEOPLE = ["Joe", "Paul", "Kievon"];
  const KIND = { office: "Office", off: "Day off", vacation: "Vacation", sick: "Sick" };
  const monday = (d) => { const t = new Date(d.getFullYear(), d.getMonth(), d.getDate()); t.setDate(t.getDate() - ((t.getDay() + 6) % 7)); return t; };
  const dIso = (d) => S.iso(d.getFullYear(), d.getMonth() + 1, d.getDate());
  const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
  let wk = monday(new Date());
  let who = {}; // "Joe|2026-11-11" -> entry
  let whoReq = 0;
  const shortClient = (c) => String(c || "").replace(/\s*\(.*?\)\s*/g, " ").trim() || c;
  const evOn = (ds) => all.filter((e) => e.start_date <= ds && e.end_date >= ds);
  const leadOn = (p, ds) => evOn(ds).filter((e) => (e.lead || "").toLowerCase() === p.toLowerCase());

  async function loadWho() {
    const req = ++whoReq;
    const from = dIso(wk), to = dIso(addDays(wk, 6));
    try {
      const rows = await IQ.rpc("web_sched_who", { p_from: from, p_to: to });
      if (req !== whoReq) return;
      who = {}; rows.forEach((r) => (who[r.person + "|" + r.day] = r));
      $("err").textContent = "";
    } catch (e) { if (req === whoReq) $("err").textContent = IQ.explain(e); }
    if (req === whoReq && view === "who") paintWho();
  }

  // What a square shows: [css class, main text, small text]
  function square(p, ds) {
    const r = who[p + "|" + ds];
    if (r && r.kind === "event") {
      const e = all.find((x) => x.id === r.event_id);
      return ["k-event", e ? shortClient(e.client) : "Event", r.note || (e && e.location) || ""];
    }
    if (r && r.kind === "other") return ["k-other", r.note || "Something else", ""];
    if (r && KIND[r.kind]) return ["k-" + r.kind, KIND[r.kind], r.note || ""];
    const led = leadOn(p, ds);
    if (led.length) return ["k-lead", shortClient(led[0].client), "Lead" + (led.length > 1 ? ` · +${led.length - 1} more` : "")];
    return ["k-none", "Not set", ""];
  }

  function drawWho() {
    const end = addDays(wk, 6);
    const f = (d, o) => d.toLocaleDateString("en-US", o);
    $("wName").textContent = f(wk, { month: "short", day: "numeric" }) + " – " + (wk.getMonth() === end.getMonth() ? end.getDate() : f(end, { month: "short", day: "numeric" }));
    $("thisW").hidden = dIso(wk) === dIso(monday(new Date()));
    tiles(all.filter((e) => e.end_date >= dIso(wk) && e.start_date <= dIso(end)), " this week");
    paintWho(); loadWho();
  }

  function paintWho() {
    const g = $("who"); g.replaceChildren();
    g.insertAdjacentHTML("beforeend", `<div></div>` + PEOPLE.map((p) => `<div class="ph">${p}</div>`).join(""));
    const today = S.todayIso();
    for (let i = 0; i < 7; i++) {
      const d = addDays(wk, i), ds = dIso(d), isT = ds === today;
      g.insertAdjacentHTML("beforeend", `<div class="dl${isT ? " today" : ""}"><small>${isT ? "Today" : d.toLocaleDateString("en-US", { weekday: "short" })}</small><b>${d.toLocaleDateString("en-US", { month: "numeric", day: "numeric" })}</b></div>`);
      PEOPLE.forEach((p) => {
        const [k, a, b] = square(p, ds);
        const c = document.createElement("button"); c.type = "button";
        c.className = "wc " + k + (isT ? " today" : "");
        c.setAttribute("aria-label", `${p}, ${d.toDateString()}: ${a}${b ? ", " + b : ""}`);
        c.innerHTML = `<b>${esc(a)}</b>` + (b ? `<small>${esc(b)}</small>` : "");
        c.addEventListener("click", () => openWho(p, ds));
        g.appendChild(c);
      });
    }
  }

  $("prevW").addEventListener("click", () => { wk = addDays(wk, -7); drawWho(); });
  $("nextW").addEventListener("click", () => { wk = addDays(wk, 7); drawWho(); });
  $("thisW").addEventListener("click", () => { wk = monday(new Date()); drawWho(); });

  const wEd = $("whoEd");
  let wSel = null; // { person, day, kind, event_id }
  function markWho() {
    wEd.querySelectorAll(".wpick button").forEach((b) => b.setAttribute("aria-pressed", String(!!wSel.kind &&
      (b.dataset.ev ? wSel.kind === "event" && b.dataset.ev === wSel.event_id : b.dataset.kind === wSel.kind))));
    $("whoNoteL").firstChild.textContent = wSel.kind === "other" ? "Where? " : "Note (optional)";
  }
  function openWho(p, ds) {
    const r = who[p + "|" + ds];
    const led = leadOn(p, ds);
    wSel = { person: p, day: ds, kind: r ? r.kind : led.length ? "event" : null, event_id: r ? r.event_id : led.length ? led[0].id : null };
    $("whoTitle").textContent = p + " · " + S.toLocal(ds).toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric" });
    const evs = evOn(ds);
    $("whoEvBox").hidden = !evs.length;
    $("whoOr").textContent = evs.length ? "Or" : "Where";
    $("whoEvs").innerHTML = evs.map((e) => `<button type="button" data-ev="${e.id}">${esc(shortClient(e.client))}<small>${esc([e.location, e.lead ? "Lead: " + e.lead : ""].filter(Boolean).join(" · "))}</small></button>`).join("");
    $("whoNote").value = (r && r.note) || "";
    $("whoTo").value = ""; $("whoTo").min = ds;
    $("whoBy").textContent = r && r.updated_by ? "Last changed by " + r.updated_by + " · " + new Date(r.updated_at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : led.length && !r ? p + " is the lead on this event. Save to confirm it, or pick something else." : "";
    $("whoErr").textContent = ""; $("whoClear").hidden = !r;
    markWho(); wEd.showModal();
  }
  wEd.querySelectorAll(".wpick").forEach((g) => g.addEventListener("click", (ev) => {
    const b = ev.target.closest("button"); if (!b) return;
    if (b.dataset.ev) { wSel.kind = "event"; wSel.event_id = b.dataset.ev; } else { wSel.kind = b.dataset.kind; wSel.event_id = null; }
    markWho(); if (wSel.kind === "other") $("whoNote").focus();
  }));
  async function saveWho(kind) {
    const to = $("whoTo").value;
    if (to && to < wSel.day) { $("whoErr").textContent = "That date is before " + S.toLocal(wSel.day).toLocaleDateString("en-US", { month: "short", day: "numeric" }) + "."; return; }
    if (kind === "other" && !$("whoNote").value.trim()) { $("whoErr").textContent = "Type where they'll be."; return; }
    if (kind === undefined && !wSel.kind) { $("whoErr").textContent = "Pick an event or one of the choices."; return; }
    $("whoSave").disabled = true;
    try {
      await IQ.rpc("web_sched_who_set", { p_person: wSel.person, p_from: wSel.day, p_to: to || wSel.day,
        p_kind: kind === null ? "" : wSel.kind, p_event_id: kind === null ? null : wSel.event_id, p_note: $("whoNote").value });
      wEd.close(); await loadWho();
    } catch (e) {
      const m = String(e && e.message);
      $("whoErr").textContent = /bad_range/.test(m) ? "Pick an end date within two months." : /unknown_event/.test(m) ? "That event isn't on the schedule any more." : IQ.explain(e);
    } finally { $("whoSave").disabled = false; }
  }
  $("whoSave").addEventListener("click", () => saveWho(wSel.kind === "other" ? "other" : undefined));
  $("whoClear").addEventListener("click", () => saveWho(null));
  $("whoCancel").addEventListener("click", () => wEd.close());

  /* ---------- add / edit ---------- */
  const ed = $("ed"), form = ed.querySelector("form");
  $("svcs").innerHTML = S.SVC.map((s) => `<label class="chip"><input type="checkbox" value="${s.key}">${s.name}</label>`).join("");
  ed.querySelectorAll(".pick").forEach((g) => g.addEventListener("click", (ev) => {
    const b = ev.target.closest("button"); if (!b) return;
    g.dataset.val = b.dataset.val;
    g.querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
  }));
  const setPick = (f, v) => { const g = ed.querySelector(`.pick[data-f="${f}"]`); g.dataset.val = v || ""; g.querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x.dataset.val === (v || "")))); };
  let editing = null;
  let freeServices = ""; // services text that isn't one of the three boxes, kept as-is

  // e = an event being changed; draft = details read from an email (not saved yet).
  // Both together = an email that changes an event already on the schedule.
  function openEd(e, draft, changes) {
    editing = e || null;
    const v = e && draft ? { ...e, ...draft } : e || draft || null;
    $("edTitle").textContent = draft ? (e ? "Check the changes and save" : "Check and save") : e ? "Edit event" : "Add event";
    $("rmBtn").hidden = !e; $("edErr").textContent = "";
    $("edChg").hidden = !changes; $("edChg").textContent = changes ? "From the email: " + changes : "";
    form.start_date.value = v && v.start_date ? v.start_date : selDay || "";
    form.end_date.value = v && v.end_date && v.end_date !== v.start_date ? v.end_date : "";
    ["client", "contact", "times", "location", "notes"].forEach((k) => (form[k].value = (v && v[k]) || ""));
    // Lead is Joe, Kievon or Paul. An older value that isn't one of them stays as its own choice.
    form.lead.querySelectorAll("option[data-extra]").forEach((o) => o.remove());
    const lead = (e && e.lead) || "";
    if (lead && ![...form.lead.options].some((o) => o.value === lead)) { const o = new Option(lead, lead); o.dataset.extra = "1"; form.lead.add(o); }
    form.lead.value = lead;
    const keys = S.svcKeys(v && v.services);
    freeServices = v && v.services && !keys.length ? v.services : "";
    $("svcs").querySelectorAll("input").forEach((i) => (i.checked = keys.includes(i.value)));
    setPick("staffing", e && e.staffing); setPick("threat_level", e && e.threat_level ? String(e.threat_level) : "");
    $("byline").textContent = e && e.updated_by ? "Last changed by " + e.updated_by + " · " + new Date(e.updated_at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";
    ed.showModal();
  }
  const menu = $("addMenu");
  $("addMenuBtn").addEventListener("click", () => menu.showModal());
  $("addMenuClose").addEventListener("click", () => menu.close());
  menu.querySelectorAll(".opt").forEach((b) => b.addEventListener("click", () => menu.close(), true));
  $("addBtn").addEventListener("click", () => openEd(null));

  /* ---------- add from an email (AI reads it on the server; the key never reaches this page) ---------- */
  const mail = $("mail");
  // A saved .eml file: keep the readable text parts, decode them, drop attachments.
  function emlText(raw) {
    const qp = (t) => t.replace(/=\r?\n/g, "").replace(/(=[0-9A-F]{2})+/gi, (m) => {
      try { return new TextDecoder().decode(new Uint8Array(m.slice(1).split("=").map((h) => parseInt(h, 16)))); } catch { return m; }
    });
    const b64 = (t) => { try { return new TextDecoder().decode(Uint8Array.from(atob(t.replace(/\s+/g, "")), (c) => c.charCodeAt(0))); } catch { return ""; } };
    const html = (t) => { const d = new DOMParser().parseFromString(t, "text/html"); d.querySelectorAll("style,script").forEach((x) => x.remove()); return (d.body ? d.body.innerText || d.body.textContent : t) || ""; };
    const part = (p) => {
      const cut = p.search(/\r?\n\r?\n/); if (cut < 0) return { head: p, body: "" };
      return { head: p.slice(0, cut), body: p.slice(cut).trim() };
    };
    const decode = ({ head, body }) => {
      const enc = (head.match(/content-transfer-encoding:\s*([\w-]+)/i) || [])[1] || "";
      let t = /base64/i.test(enc) ? b64(body) : /quoted/i.test(enc) ? qp(body) : body;
      return /content-type:\s*text\/html/i.test(head) ? html(t) : t;
    };
    const top = part(raw);
    const keep = top.head.split(/\r?\n(?=\S)/).filter((l) => /^(from|to|cc|date|subject):/i.test(l)).join("\n");
    const bound = (raw.match(/boundary="?([^";\r\n]+)"?/i) || [])[1];
    if (!bound) return keep + "\n\n" + decode(top);
    const parts = raw.split("--" + bound).slice(1).map(part);
    const plain = parts.filter((p) => /content-type:\s*text\/plain/i.test(p.head) && !/attachment/i.test(p.head));
    const use = plain.length ? plain : parts.filter((p) => /content-type:\s*text\/html/i.test(p.head));
    // Nested multipart (common in Outlook/Gmail): read it again from inside.
    const nested = parts.filter((p) => /content-type:\s*multipart\//i.test(p.head)).map((p) => emlText(p.head + "\n\n" + p.body));
    return [keep, ...use.map(decode), ...nested].filter(Boolean).join("\n\n");
  }
  async function readEmail(text) {
    // Send the current and upcoming events too, so the reader can tell when an email changes one of them.
    const since = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
    const cut = (x, n) => String(x || "").slice(0, n);
    const existing = all.filter((x) => (x.end_date || x.start_date) >= since).slice(0, 250).map((x) => ({
      id: x.id, start_date: x.start_date, end_date: x.end_date, client: cut(x.client, 200), contact: cut(x.contact, 200),
      services: x.services || "", times: cut(x.times, 400), location: cut(x.location, 200), notes: cut(x.notes, 400)
    }));
    const { data, error } = await IQ.sb.functions.invoke("sched-read-email", { body: { text, existing } });
    if (!error) return data;
    let body = null; try { body = await error.context.json(); } catch {}
    throw new Error((body && body.error) || error.message || "ai_error");
  }
  const mailErr = (m) => ({
    not_allowed: "Your login doesn't have access to this yet. Ask Joe to turn it on.",
    no_key: "The email reader isn't switched on yet. Joe needs to add the Anthropic key first.",
    bad_key: "The Anthropic key isn't working. Joe needs to check it.",
    busy: "The email reader is busy right now. Try again in a minute.",
    too_long: "That email is too long to read in one go. Paste just the messages about the job.",
    empty: "Paste the email first.",
    refused: "The email reader couldn't read this one. Add the event by hand instead."
  })[m] || "Couldn't read the email right now. Try again, or add the event by hand.";

  $("mailBtn").addEventListener("click", () => {
    $("mailText").value = ""; $("mailFile").value = ""; $("mailName").textContent = ".eml or .txt";
    $("mailMsg").className = "msg"; $("mailMsg").textContent = ""; $("mailPrev").replaceChildren();
    mail.showModal();
  });
  $("mailCancel").addEventListener("click", () => mail.close());
  $("mailFile").addEventListener("change", async () => {
    const f = $("mailFile").files[0]; if (!f) return;
    $("mailName").textContent = f.name;
    const raw = await f.text();
    $("mailText").value = (/\.eml$/i.test(f.name) || /^(received|from|return-path|mime-version|delivered-to):/im.test(raw.slice(0, 2000)) ? emlText(raw) : raw).trim().slice(0, 60000);
  });
  $("mailGo").addEventListener("click", async () => {
    const text = $("mailText").value.trim();
    if (!text) { $("mailMsg").className = "msg bad"; $("mailMsg").textContent = mailErr("empty"); return; }
    $("mailGo").disabled = true; $("mailPrev").replaceChildren();
    $("mailMsg").className = "msg"; $("mailMsg").textContent = "Reading the email… this takes a few seconds.";
    try {
      const res = await readEmail(text);
      const evs = (res && res.events) || [];
      if (!evs.length) { $("mailMsg").className = "msg bad"; $("mailMsg").textContent = "Couldn't find an event in that email. Add it by hand with + Add."; return; }
      $("mailMsg").className = "msg good";
      const isOld = (x) => (x.match_id && all.some((y) => y.id === x.match_id)) ||
        all.some((y) => y.start_date === x.start_date && S.clientKey(y.client) === S.clientKey(x.client));
      const nUpd = evs.filter(isOld).length, nNew = evs.length - nUpd;
      $("mailMsg").textContent = "Found " + [nUpd && (nUpd === 1 ? "1 change to an event already on the schedule" : nUpd + " changes to events already on the schedule"),
        nNew && (nNew === 1 ? "1 new event" : nNew + " new events")].filter(Boolean).join(" and ") + ". Check each one, then save.";
      evs.forEach((ev) => {
        const { match_id, changes, ...rest } = ev;
        const d = { ...rest, services: S.svcText(S.svcKeys((ev.services || []).join(" & "))), end_date: ev.end_date || ev.start_date };
        const ok = /^\d{4}-\d{2}-\d{2}$/.test(d.start_date || "");
        if (!ok) d.start_date = ""; if (!/^\d{4}-\d{2}-\d{2}$/.test(d.end_date || "")) d.end_date = d.start_date;
        // The reader's match, or else an event already on the schedule for the same day and client.
        const old = (match_id && all.find((x) => x.id === match_id)) ||
          (d.start_date && all.find((x) => x.start_date === d.start_date && S.clientKey(x.client) === S.clientKey(d.client))) || null;
        if (old) { // keep what the email didn't mention
          Object.keys(d).forEach((k) => { if (!d[k]) delete d[k]; });
          if (!d.services) delete d.services;
        }
        const dup = !old && ok && all.some((x) => x.start_date === d.start_date && S.clientKey(x.client) === S.clientKey(d.client));
        const show = old ? { ...old, ...d } : d;
        const box = document.createElement("div"); box.className = "found";
        box.innerHTML = `<div>${old ? `<small style="color:var(--accent,#2563eb);font-weight:600">Change to an event already on the schedule</small><br>` : ""}
          <b>${esc(show.start_date ? S.whenText(show) : "Date not found")} · ${esc(show.client || "Client not found")}</b>
          <small>${esc([show.services, show.location, show.times].filter(Boolean).join(" · "))}</small>
          ${old && changes ? `<small><b>What changed:</b> ${esc(changes)}</small>` : ""}
          ${dup ? `<small style="color:var(--warn)">Looks like this is already on the schedule.</small>` : ""}</div>`;
        const b = document.createElement("button"); b.type = "button"; b.className = "primary"; b.textContent = old ? "Check and update" : "Check and add";
        b.addEventListener("click", () => { mail.close(); old ? openEd(old, d, changes) : openEd(null, d); });
        box.appendChild(b); $("mailPrev").appendChild(box);
      });
    } catch (e) { $("mailMsg").className = "msg bad"; $("mailMsg").textContent = mailErr(e.message); }
    finally { $("mailGo").disabled = false; }
  });
  $("cancelBtn").addEventListener("click", () => ed.close());
  $("saveBtn").addEventListener("click", async () => {
    const keys = [...$("svcs").querySelectorAll("input:checked")].map((i) => i.value);
    const p = {
      id: editing ? editing.id : "",
      start_date: form.start_date.value, end_date: form.end_date.value || form.start_date.value,
      client: form.client.value.trim(), contact: form.contact.value, services: keys.length ? S.svcText(keys) : freeServices,
      times: form.times.value, location: form.location.value, lead: form.lead.value,
      staffing: ed.querySelector('.pick[data-f="staffing"]').dataset.val || "",
      threat_level: ed.querySelector('.pick[data-f="threat_level"]').dataset.val || "",
      notes: form.notes.value
    };
    if (!p.start_date) { $("edErr").textContent = "Pick a start date."; return; }
    if (p.end_date < p.start_date) { $("edErr").textContent = "The end date is before the start date."; return; }
    if (!p.client) { $("edErr").textContent = "Type the client's name."; return; }
    $("saveBtn").disabled = true;
    try { await IQ.rpc("web_sched_save", { p }); ed.close(); await load(); }
    catch (err) { $("edErr").textContent = IQ.explain(err); }
    finally { $("saveBtn").disabled = false; }
  });
  $("rmBtn").addEventListener("click", async () => {
    if (!editing || !confirm("Take “" + editing.client + "” off the schedule?")) return;
    try { await IQ.rpc("web_sched_remove", { p_id: editing.id }); ed.close(); await load(); }
    catch (err) { $("edErr").textContent = IQ.explain(err); }
  });

  /* ---------- import ---------- */
  const imp = $("imp");
  let pending = [];
  function showPreview(rows) {
    const mapped = S.mapRows(rows);
    const prev = $("impPrev"); prev.replaceChildren(); pending = [];
    if (mapped.error) { $("impMsg").className = "msg bad"; $("impMsg").textContent = "Couldn't find the header row. The table needs columns called Date and Client."; $("impGo").disabled = true; return; }
    const have = new Set(all.map((e) => e.start_date + "|" + e.client.trim().toLowerCase()));
    const seen = new Set();
    let skip = 0, bad = 0;
    mapped.rows.forEach((r) => {
      const k = r.start_date + "|" + r.client.trim().toLowerCase();
      const dup = !r.problem && (have.has(k) || seen.has(k));
      seen.add(k);
      const div = document.createElement("div");
      if (r.problem) { bad++; div.className = "skip"; div.innerHTML = `<b>Row ${r.line}: skipped</b><small>${esc(r.problem)}</small>`; }
      else if (dup) { skip++; div.className = "skip"; div.innerHTML = `<b>${esc(S.whenText(r))} · ${esc(r.client)}</b><small>Already on the schedule, skipped</small>`; }
      else { pending.push(r); div.innerHTML = `<b>${esc(S.whenText(r))} · ${esc(r.client)}</b><small>${esc([r.services, r.location].filter(Boolean).join(" · "))}</small>`; }
      prev.appendChild(div);
    });
    $("impMsg").className = "msg";
    $("impMsg").textContent = `${pending.length} new event${pending.length === 1 ? "" : "s"} to add` + (skip ? `, ${skip} already on the schedule` : "") + (bad ? `, ${bad} row${bad === 1 ? "" : "s"} couldn't be read` : "") + ".";
    $("impGo").disabled = !pending.length;
    $("impGo").textContent = pending.length ? `Add ${pending.length} event${pending.length === 1 ? "" : "s"}` : "Add events";
  }
  $("impBtn").addEventListener("click", () => {
    $("impFile").value = ""; $("impPaste").value = ""; $("impName").textContent = ".xlsx, .docx or .csv";
    $("impMsg").textContent = ""; $("impPrev").replaceChildren(); $("impGo").disabled = true; pending = [];
    imp.showModal();
  });
  $("impCancel").addEventListener("click", () => imp.close());
  $("impFile").addEventListener("change", async () => {
    const f = $("impFile").files[0]; if (!f) return;
    $("impName").textContent = f.name;
    try { showPreview(await SHEET.readFile(f)); }
    catch (e) {
      $("impMsg").className = "msg bad";
      const m = String(e && e.message);
      $("impMsg").textContent = /old_xls/.test(m) ? "That's an old .xls file. In Excel, use Save As and pick .xlsx, then try again."
        : /old_doc/.test(m) ? "That's an old .doc file. In Word, use Save As and pick .docx, then try again."
        : /no_table/.test(m) ? "That Word file has no table of events. Put the events in a table with a header row (Date, Client, Location...), then try again."
        : "Couldn't read that file. Try saving it as .xlsx, .docx or .csv.";
    }
  });
  $("impPaste").addEventListener("input", () => { const t = $("impPaste").value; if (t.trim()) showPreview(SHEET.readText(t)); });
  $("impGo").addEventListener("click", async () => {
    $("impGo").disabled = true;
    const rows = pending.map(({ line, problem, ...r }) => r);
    try {
      const res = await IQ.rpc("web_sched_import", { p_rows: rows });
      imp.close(); await load();
      $("err").className = "msg good";
      $("err").textContent = `Added ${res.added} event${res.added === 1 ? "" : "s"}` + (res.skipped ? `, skipped ${res.skipped} already on the schedule.` : ".");
      setTimeout(() => { $("err").className = "msg bad"; $("err").textContent = ""; }, 6000);
    } catch (e) { $("impMsg").className = "msg bad"; $("impMsg").textContent = IQ.explain(e); $("impGo").disabled = false; }
  });

  load();
})();
