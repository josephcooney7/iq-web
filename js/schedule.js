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
      notStaffed: evs.filter((e) => e.staffing !== "Staffed").length
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
  let view = "up";
  const now = new Date();
  let calY = now.getFullYear(), calM = now.getMonth(); // month shown in the calendar (0-11)
  let selDay = null;

  async function load() {
    try { all = await IQ.rpc("web_sched_list"); $("err").textContent = ""; }
    catch (e) { $("err").textContent = IQ.explain(e); all = []; }
    draw();
  }

  /* ---------- drawing ---------- */
  const cls = (e) => (e.staffing === "Staffed" ? "staffed" : e.staffing === "Unstaffed" ? "unstaffed" : "");
  function card(e) {
    const b = document.createElement("button");
    b.type = "button"; b.className = "ev " + cls(e);
    const keys = S.svcKeys(e.services);
    const svcTags = keys.length ? S.SVC.filter((s) => keys.includes(s.key)).map((s) => `<span class="tag svc">${s.short}</span>`).join("")
      : e.services ? `<span class="tag svc">${esc(e.services)}</span>` : "";
    const staff = e.staffing === "Staffed" ? `<span class="tag in">Staffed</span>` : e.staffing === "Unstaffed" ? `<span class="tag dmg">Unstaffed</span>` : `<span class="tag blank">Staffing not set</span>`;
    const tn = +e.threat_level;
    const th = tn ? `<span class="tag ${tn >= 7 ? "dmg" : tn >= 4 ? "med" : "in"}">Threat: ${tn}/10</span>` : `<span class="tag blank">Threat not set</span>`;
    b.innerHTML = `<div class="row1"><span class="when">${esc(S.whenText(e))}</span><span class="client">${esc(e.client)}</span></div>
      <div class="meta">${[e.location, e.times].filter(Boolean).map(esc).join("<br>")}</div>
      <div class="meta">Lead: ${e.lead ? "<b>" + esc(e.lead) + "</b>" : "not set"}</div>
      <div class="tags">${svcTags}${staff}${th}</div>`;
    b.addEventListener("click", () => openEd(e));
    return b;
  }

  function tiles(evs, label) {
    const c = S.counts(evs);
    $("tiles").innerHTML = [
      ["Events" + label, c.events], ["Clients", c.clients], ["K9", c.k9], ["Screening", c.screening], ["Guard details", c.guards],
      ["Not staffed yet", c.notStaffed, c.notStaffed ? "alert" : ""]
    ].map(([t, n, k]) => `<div class="tile2 ${k || ""}"><b>${n}</b><small>${t}</small></div>`).join("");
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
    const shown = selDay ? all.filter((e) => e.start_date <= selDay && e.end_date >= selDay) : inMonth;
    const h = document.createElement("h2"); h.style.marginTop = "18px";
    h.textContent = selDay ? S.toLocal(selDay).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" }) : "All events this month";
    dl.appendChild(h);
    if (!shown.length) dl.insertAdjacentHTML("beforeend", `<p class="empty" style="margin-top:4px">No events${selDay ? " on this day" : " this month"}.</p>`);
    shown.forEach((e) => dl.appendChild(card(e)));
  }

  function draw() {
    document.querySelectorAll("#views button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === view)));
    $("listView").hidden = view === "cal"; $("calView").hidden = view !== "cal";
    const today = S.todayIso();
    if (view === "cal") return drawCal();
    if (view === "up") {
      const evs = all.filter((e) => e.end_date >= today);
      tiles(evs, " coming up"); drawList(evs, "Nothing coming up. Tap + Add event, or import a spreadsheet.");
    } else {
      const evs = all.filter((e) => e.end_date < today).reverse();
      tiles(evs, " done"); drawList(evs, "No past events yet.");
    }
  }

  document.querySelectorAll("#views button").forEach((b) => b.addEventListener("click", () => { view = b.dataset.v; draw(); }));
  $("prevM").addEventListener("click", () => { calM--; if (calM < 0) { calM = 11; calY--; } selDay = null; drawCal(); });
  $("nextM").addEventListener("click", () => { calM++; if (calM > 11) { calM = 0; calY++; } selDay = null; drawCal(); });

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

  function openEd(e) {
    editing = e || null;
    $("edTitle").textContent = e ? "Edit event" : "Add event";
    $("rmBtn").hidden = !e; $("edErr").textContent = "";
    form.start_date.value = e ? e.start_date : selDay || "";
    form.end_date.value = e && e.end_date !== e.start_date ? e.end_date : "";
    ["client", "contact", "times", "location", "notes"].forEach((k) => (form[k].value = (e && e[k]) || ""));
    // Lead is Joe, Kievon or Paul. An older value that isn't one of them stays as its own choice.
    form.lead.querySelectorAll("option[data-extra]").forEach((o) => o.remove());
    const lead = (e && e.lead) || "";
    if (lead && ![...form.lead.options].some((o) => o.value === lead)) { const o = new Option(lead, lead); o.dataset.extra = "1"; form.lead.add(o); }
    form.lead.value = lead;
    const keys = S.svcKeys(e && e.services);
    freeServices = e && e.services && !keys.length ? e.services : "";
    $("svcs").querySelectorAll("input").forEach((i) => (i.checked = keys.includes(i.value)));
    setPick("staffing", e && e.staffing); setPick("threat_level", e && e.threat_level ? String(e.threat_level) : "");
    $("byline").textContent = e && e.updated_by ? "Last changed by " + e.updated_by + " · " + new Date(e.updated_at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "";
    ed.showModal();
  }
  $("addBtn").addEventListener("click", () => openEd(null));
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
    if (mapped.error) { $("impMsg").className = "msg bad"; $("impMsg").textContent = "Couldn't find the header row. It needs columns called Date and Client."; $("impGo").disabled = true; return; }
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
    $("impFile").value = ""; $("impPaste").value = ""; $("impName").textContent = ".xlsx or .csv";
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
      $("impMsg").textContent = /old_xls/.test(e.message) ? "That's an old .xls file. In Excel, use Save As and pick .xlsx, then try again." : "Couldn't read that file. Try saving it as .xlsx or .csv.";
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
