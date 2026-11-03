/* SOPs that pop up when someone signs equipment out. One per kind of equipment (matches equipment.kind).
   To change the wording, edit the steps below and bump "version" so the sheet shows which one was read. */
window.GEAR_SOP = {
  OpenGate: {
    version: "draft-2026-11-03",
    title: "OpenGate SOP",
    draft: true,
    sections: [
      { h: "Before you leave", steps: [
        "Check each gate for cracks, loose panels or damaged cables. If anything is wrong, mark that gate Damaged and add a photo.",
        "Make sure the batteries are charged, and count them.",
        "Pack the gates in their cases. Lift with two people."
      ] },
      { h: "Setting up", steps: [
        "Set the gates on flat, level ground.",
        "Keep them away from large metal objects, doors, and power cables. These can cause false alarms.",
        "Turn the gates on and wait for the start-up check to finish before you screen anyone.",
        "Walk a test item through to make sure the gate alarms before the doors open."
      ] },
      { h: "During the event", steps: [
        "Never leave the gates unattended.",
        "Report any problem to your supervisor right away."
      ] },
      { h: "Packing up", steps: [
        "Turn the gates off, wipe them down, and check again for damage.",
        "Count the batteries and put them on charge when you're back.",
        "Return the gates in this app so we know they're back."
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
      ${needAck ? '<label class="ack"><input type="checkbox"> I\'ve read this and will follow it</label>' : ""}
      <div class="sopbtns">
        ${needAck ? '<button type="button" class="cancel">Back</button>' : ""}
        <button type="submit" class="primary go">${needAck ? "Continue" : "Close"}</button>
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
