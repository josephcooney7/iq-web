/* Reads the first sheet of an Excel (.xlsx) or CSV file in the browser, or rows pasted from a spreadsheet.
   Returns an array of rows, each an array of cell values (strings, numbers). No outside library. */
window.SHEET = (() => {
  async function inflate(bytes) {
    const ds = new DecompressionStream("deflate-raw");
    const out = new Blob([bytes]).stream().pipeThrough(ds);
    return new Uint8Array(await new Response(out).arrayBuffer());
  }

  // Minimal zip reader: find files through the central directory.
  async function unzip(buf, wanted) {
    const dv = new DataView(buf), u8 = new Uint8Array(buf), dec = new TextDecoder();
    let eocd = -1;
    for (let i = buf.byteLength - 22; i >= Math.max(0, buf.byteLength - 66000); i--) if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    if (eocd < 0) throw new Error("not_xlsx");
    const count = dv.getUint16(eocd + 10, true);
    let p = dv.getUint32(eocd + 16, true);
    const files = {};
    for (let n = 0; n < count; n++) {
      if (dv.getUint32(p, true) !== 0x02014b50) break;
      const method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true);
      const nlen = dv.getUint16(p + 28, true), xlen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true);
      const off = dv.getUint32(p + 42, true);
      const name = dec.decode(u8.subarray(p + 46, p + 46 + nlen));
      p += 46 + nlen + xlen + clen;
      if (!wanted(name)) continue;
      const start = off + 30 + dv.getUint16(off + 26, true) + dv.getUint16(off + 28, true);
      const raw = u8.subarray(start, start + csize);
      files[name] = dec.decode(method === 0 ? raw : await inflate(raw));
    }
    return files;
  }

  const xml = (s) => new DOMParser().parseFromString(s, "application/xml");
  const kids = (el, tag) => Array.from(el.getElementsByTagNameNS("*", tag));
  const colNum = (ref) => { let n = 0; for (const ch of ref.replace(/\d+/g, "")) n = n * 26 + ch.charCodeAt(0) - 64; return n - 1; };

  async function readXlsx(buf) {
    const files = await unzip(buf, (n) => /^xl\/(workbook\.xml|_rels\/workbook\.xml\.rels|sharedStrings\.xml|worksheets\/sheet\d+\.xml)$/.test(n));
    let sheetPath = "xl/worksheets/sheet1.xml";
    try { // first sheet in the workbook's own order
      const wb = xml(files["xl/workbook.xml"]), rels = xml(files["xl/_rels/workbook.xml.rels"]);
      const rid = kids(wb, "sheet")[0].getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
      const target = kids(rels, "Relationship").find((r) => r.getAttribute("Id") === rid).getAttribute("Target");
      sheetPath = target.startsWith("/") ? target.slice(1) : "xl/" + target.replace(/^\.\//, "");
    } catch {}
    const shared = files["xl/sharedStrings.xml"]
      ? kids(xml(files["xl/sharedStrings.xml"]), "si").map((si) => kids(si, "t").map((t) => t.textContent).join("")) : [];
    const sheet = files[sheetPath] || Object.entries(files).find(([n]) => /worksheets\/sheet\d+\.xml$/.test(n))?.[1];
    if (!sheet) throw new Error("not_xlsx");
    const rows = [];
    kids(xml(sheet), "row").forEach((row) => {
      const r = [];
      kids(row, "c").forEach((c) => {
        const t = c.getAttribute("t"), v = kids(c, "v")[0], ref = c.getAttribute("r");
        let val = "";
        if (t === "s" && v) val = shared[+v.textContent] ?? "";
        else if (t === "inlineStr") val = kids(c, "t").map((x) => x.textContent).join("");
        else if (t === "str" || t === "b" || t === "e") val = v ? v.textContent : "";
        else if (v) val = Number(v.textContent);
        r[ref ? colNum(ref) : r.length] = val;
      });
      rows.push(Array.from(r, (x) => (x === undefined ? "" : x)));
    });
    return rows;
  }

  // CSV or tab-separated text (pasting from Excel / Google Sheets gives tabs).
  function readText(text) {
    const tab = text.includes("\t");
    const sep = tab ? "\t" : ",";
    const rows = []; let row = [], cell = "", q = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (q) { if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += ch; }
      else if (ch === '"' && cell === "") q = true;
      else if (ch === sep) { row.push(cell); cell = ""; }
      else if (ch === "\n" || ch === "\r") { if (ch === "\r" && text[i + 1] === "\n") i++; row.push(cell); rows.push(row); row = []; cell = ""; }
      else cell += ch;
    }
    if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
    return rows;
  }

  async function readFile(file) {
    const buf = await file.arrayBuffer();
    const head = new Uint8Array(buf, 0, Math.min(4, buf.byteLength));
    if (head[0] === 0x50 && head[1] === 0x4b) return readXlsx(buf); // "PK" = zip = .xlsx
    if (/\.xls$/i.test(file.name)) throw new Error("old_xls");
    return readText(new TextDecoder().decode(buf));
  }

  return { readFile, readText };
})();
