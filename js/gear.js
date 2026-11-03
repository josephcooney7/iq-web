/* Shared bits for the equipment pages. */
window.GEAR = (() => {
  function when(t) {
    if (!t) return "";
    const d = new Date(t), now = new Date();
    const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    if (d.toDateString() === now.toDateString()) return "today " + time;
    const y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return "yesterday " + time;
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" }) + " " + time;
  }

  // Put text into [data-t=key] spans safely.
  function fill(root, map) {
    root.querySelectorAll("[data-t]").forEach((s) => (s.textContent = map[s.dataset.t] == null ? "" : map[s.dataset.t]));
  }

  // Shrink a phone photo to a small JPEG (base64, no prefix).
  function shrink(file) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        const max = 1024, s = Math.min(1, max / Math.max(img.width, img.height));
        const c = document.createElement("canvas");
        c.width = Math.round(img.width * s); c.height = Math.round(img.height * s);
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(img.src);
        let q = 0.7, out = c.toDataURL("image/jpeg", q);
        while (out.length > 650000 && q > 0.3) { q -= 0.1; out = c.toDataURL("image/jpeg", q); }
        resolve(out.split(",")[1]);
      };
      img.onerror = () => reject(new Error("Couldn't read that photo."));
      img.src = URL.createObjectURL(file);
    });
  }

  // One unit row: tick box, OK / Damaged, and a note + photo when damaged.
  let n = 0;
  function row(item, checked, disabled, reason) {
    const id = "r" + (++n);
    const el = document.createElement("div");
    el.className = "item" + (disabled ? " off" : "");
    el.innerHTML = `
      <div class="top">
        <input type="checkbox" id="${id}" ${checked ? "checked" : ""} ${disabled ? "disabled" : ""}>
        <label class="name" for="${id}"><span data-t="serial"></span><small data-t="sub"></small></label>
        <span class="seg" ${disabled ? "hidden" : ""}>
          <button type="button" class="ok" aria-pressed="true">OK</button>
          <button type="button" class="dmg" aria-pressed="false">Damaged</button>
        </span>
      </div>
      <div class="dmgbox" hidden>
        <textarea placeholder="What's wrong? (e.g. cracked panel, won't power on)" maxlength="1000"></textarea>
        <div class="photo"><img alt="" hidden><label>Add photo<input type="file" accept="image/*" capture="environment"></label><span></span></div>
      </div>`;
    fill(el, { serial: item.serial, sub: reason || (item.flag_damaged ? "Reported damaged earlier" : "") });
    let condition = "ok", photo = null;
    const cb = el.querySelector("input[type=checkbox]"), box = el.querySelector(".dmgbox");
    const [bOk, bDmg] = el.querySelectorAll(".seg button");
    const set = (c) => {
      condition = c; bOk.setAttribute("aria-pressed", c === "ok"); bDmg.setAttribute("aria-pressed", c === "damaged");
      box.hidden = c !== "damaged"; if (c === "damaged") { cb.checked = true; el.querySelector("textarea").focus(); }
    };
    bOk.onclick = () => set("ok"); bDmg.onclick = () => set("damaged");
    const fileIn = el.querySelector("input[type=file]"), img = el.querySelector(".photo img"), stat = el.querySelector(".photo span");
    fileIn.onchange = async () => {
      const f = fileIn.files && fileIn.files[0]; if (!f) return;
      stat.textContent = "Getting photo ready…";
      try { photo = await shrink(f); img.src = "data:image/jpeg;base64," + photo; img.hidden = false; stat.textContent = ""; el.querySelector(".photo label").firstChild.textContent = "Change photo"; }
      catch (e) { stat.textContent = e.message; }
    };
    return {
      el, serial: item.serial,
      checked: () => cb.checked && !cb.disabled,
      value: () => ({ id: item.id, condition, note: condition === "damaged" ? el.querySelector("textarea").value.trim() : "", photo_b64: condition === "damaged" ? photo : null })
    };
  }

  function day(d) { return d ? new Date(d + "T12:00:00").toLocaleDateString(undefined, { month: "short", day: "numeric" }) : ""; }
  // "Hall B · 4 batteries · out Nov 3 · back Nov 5"
  function batchText(b) {
    if (!b) return "";
    return [b.location, b.batteries != null ? b.batteries + " batter" + (b.batteries === 1 ? "y" : "ies") : "",
      b.date_out ? "out " + day(b.date_out) : "", b.date_back ? "back " + day(b.date_back) : ""].filter(Boolean).join(" · ");
  }

  // History list. withSerial: show which unit each line is about.
  function history(ul, rows, withSerial) {
    if (!rows.length) { ul.innerHTML = "<li>Nothing yet.</li>"; return; }
    ul.replaceChildren(...rows.map((h) => {
      const li = document.createElement("li");
      li.innerHTML = `<span class="tag ${h.action}">${h.action === "out" ? "Out" : "Back"}</span>
        ${h.condition === "damaged" ? '<span class="tag dmg">Damaged</span>' : ""}
        ${withSerial ? "<b data-t=serial></b> ·" : ""} <b data-t="ev"></b><br>
        <span data-t="by"></span> · ${when(h.at)}
        ${h.batch ? "<br><span data-t=extra></span>" : ""}
        ${h.note ? "<br>“<span data-t=note></span>”" : ""}
        ${h.has_photo ? '<br><a href="#" class="link">Show photo</a>' : ""}`;
      fill(li, { serial: h.kind ? h.kind + " " + h.serial : h.serial, ev: h.event_name, by: h.by_name, note: h.note, extra: batchText(h.batch) });
      const a = li.querySelector("a.link");
      if (a) a.onclick = async (e) => {
        e.preventDefault(); a.textContent = "Loading…";
        try { const b64 = await IQ.rpc("web_gear_photo", { p_move_id: h.id }); const im = document.createElement("img"); im.className = "thumb"; im.alt = "Damage photo"; im.src = "data:image/jpeg;base64," + b64; a.replaceWith(im); }
        catch (err) { a.textContent = IQ.explain(err); }
      };
      return li;
    }));
  }

  return { when, fill, row, history, shrink, day, batchText };
})();
