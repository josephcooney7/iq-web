/* SOPs that pop up when someone signs equipment out. One per kind of equipment (matches equipment.kind).
   To change the wording, edit the steps below and bump "version" so the sheet shows which one was read. */
window.GEAR_SOP = {
  OpenGate: {
    version: "2026-11-04d",
    title: "OpenGate SOP",
    draft: false,
    sections: [
      { h: "Before you leave", steps: [
        "Check each gate for cracks and loose panels. If anything is wrong, mark that gate Damaged and add a photo.",
        "Take 5 fully charged batteries for each OpenGate set, and count them.",
        "Put every gate in its protective sleeve for transport, every time.",
        "Load at least 1 table, 1 handheld wand, 3 baskets and the operational test piece with the gates."
      ] },
      { h: "Setting up on site", steps: [
        "Set the gates on flat, level ground.",
        "Keep them away from large metal objects, doors, and power cables. These can cause false alarms.",
        "The Stapleton branded socks stay on every gate.",
        "Turn the gates on and wait for the start-up check to finish.",
        "Set each gate to the standard 2B setting with sensitivity 0, unless otherwise authorized.",
        "Walk the operational test piece through each gate and confirm it alarms before the doors open."
      ] },
      { h: "Packing up and returning", steps: [
        "Turn the gates off and wipe them down.",
        "Check each gate again for damage.",
        "Put every gate back in its protective sleeve for transport.",
        "Count the batteries, tables, wands and baskets.",
        "Back at the warehouse, put the batteries on charge.",
        "Return the gates in this app: scan a sticker, tick every gate coming back, and enter what came back."
      ] },
      { h: "If a gate is damaged or not working", steps: [
        "Stop using that gate.",
        "In this app, mark it Damaged. Say what's wrong and add a photo.",
        "Don't sign a damaged gate out again until it's fixed and returned as OK."
      ] }
    ]
  }
};

/* Show the SOP in a pop-up. needAck: they must tick "I've read this" to continue. Resolves true if they continue. */
window.showSop = function (kind, needAck) {
  const sop = window.GEAR_SOP[kind];
  if (!sop) return Promise.resolve(true);
  return new Promise((resolve) => {
    const d = document.createElement("dialog");
    d.className = "sop";
    d.innerHTML = `<form method="dialog">
      <h3 data-t="title"></h3>
      ${sop.draft ? '<p class="draft">Draft: Joe is still checking this wording.</p>' : ""}
      <div class="sopbody"></div>
      ${needAck ? '<label class="ack"><input type="checkbox"> I've read and understand the SOP</label>' : ""}
      <div class="sopbtns">
        ${needAck ? '<button type="button" class="cancel">Back</button>' : ""}
        <button type="submit" class="primary go">${needAck ? "I understand, sign out" : "Close"}</button>
      </div></form>`;
    d.querySelector("[data-t=title]").textContent = sop.title;
    const body = d.querySelector(".sopbody");
    sop.sections.forEach((s) => {
      const h = document.createElement("h4"); h.textContent = s.h; body.appendChild(h);
      const ol = document.createElement("ol");
      s.steps.forEach((t) => { const li = document.createElement("li"); li.textContent = t; ol.appendChild(li); });
      body.appendChild(ol);
    });
    const go = d.querySelector(".go"), cb = d.querySelector(".ack input");
    if (cb) { go.disabled = true; cb.onchange = () => (go.disabled = !cb.checked); }
    let ok = false;
    go.onclick = () => { ok = !cb || cb.checked; };
    const c = d.querySelector(".cancel"); if (c) c.onclick = () => d.close();
    d.addEventListener("close", () => { d.remove(); resolve(ok); });
    document.body.appendChild(d);
    d.showModal();
  });
};
