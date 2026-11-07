/* Shared code for every page: Supabase connection, login screen, top bar, install support. */
window.IQ = (() => {
  const SUPABASE_URL = "https://pceknxpgvuzlgslyjxxg.supabase.co";
  // Publishable key: safe to ship in a web page. Data is protected by login + database rules.
  const SUPABASE_KEY = "sb_publishable_5pYHcYIy8xvAX1cg67ndOQ_Qr1q18U4";

  const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  async function rpc(name, args) {
    const { data, error } = await sb.rpc(name, args || {});
    if (error) throw error;
    return data;
  }

  function explain(err) {
    const m = String((err && (err.message || err.msg)) || err || "");
    if (/not_allowed|permission denied/i.test(m)) return "Your login doesn't have access to this yet. Ask Joe to turn it on.";
    if (/JWT|token|session/i.test(m)) return "Your login has expired. Reload the page and sign in again.";
    if (/Failed to fetch|NetworkError|network/i.test(m)) return "No internet connection right now. The page will try again.";
    if (/no_event/i.test(m)) return "There's no event set up for your account yet.";
    return "Something went wrong: " + m.slice(0, 160);
  }

  /* ---------- top bar ---------- */
  function topbar(active) {
    const bar = document.createElement("nav");
    bar.className = "iq-bar";
    bar.innerHTML = `
      <a class="iq-brand" href="/">Stapleton&nbsp;IQ</a>
      <span class="iq-links">
        <a href="/dashboard" data-dash hidden ${active === "dashboard" ? 'aria-current="page"' : ""}>Dashboard</a>
        <a href="/schedule" data-staff hidden ${active === "schedule" ? 'aria-current="page"' : ""}>Schedule</a>
        <a href="/setup" data-staff hidden ${active === "setup" ? 'aria-current="page"' : ""}>Setup</a>
        <a href="/client" data-cv hidden ${active === "client" ? 'aria-current="page"' : ""}>Client view</a>
        <a href="/gear" data-field hidden ${active === "gear" ? 'aria-current="page"' : ""}>Equipment</a>
      </span>
      <button type="button" class="iq-out" hidden>Sign out</button>`;
    document.body.prepend(bar);
    bar.querySelector(".iq-out").addEventListener("click", async () => { await sb.auth.signOut(); location.reload(); });
    return bar;
  }

  /* ---------- login screen ---------- */
  function loginScreen(mode) {
    return new Promise((resolve) => {
      const wrap = document.createElement("div");
      wrap.className = "iq-login";
      document.body.appendChild(wrap);
      let view = mode || "signin";
      const draw = (msg, kind) => {
        const titles = { signin: "Sign in", signup: "Create your login", forgot: "Reset password", newpass: "Choose a new password" };
        wrap.innerHTML = `
          <form class="iq-card" novalidate>
            <img class="iq-logo" src="/icons/stapleton-logo.png" alt="Stapleton Security Services" width="471" height="86">
            <div class="iq-mark">Stapleton IQ</div>
            <h1>${titles[view]}</h1>
            ${view === "signup" ? `<label>Full name<input name="fullname" type="text" autocomplete="name" maxlength="80" required></label>` : ""}
            ${view !== "newpass" ? `<label>Email<input name="email" type="email" autocomplete="email" required></label>` : ""}
            ${view !== "forgot" ? `<label>Password<input name="password" type="password" minlength="8"
                autocomplete="${view === "signin" ? "current-password" : "new-password"}" required></label>` : ""}
            <p class="iq-msg ${kind || ""}" role="status">${msg || ""}</p>
            <button class="iq-primary" type="submit">${{ signin: "Sign in", signup: "Create login", forgot: "Email me a reset link", newpass: "Save password" }[view]}</button>
            <div class="iq-alt">
              ${view === "signin" ? `<a href="#" data-v="forgot">Forgot password?</a><span>New here? Ask Joe for a login.</span>` : ""}
              ${view === "signup" || view === "forgot" ? `<a href="#" data-v="signin">Back to sign in</a>` : ""}
            </div>
          </form>`;
        wrap.querySelectorAll("[data-v]").forEach((a) => a.addEventListener("click", (e) => { e.preventDefault(); view = a.dataset.v; draw(); }));
        const f = wrap.querySelector("form");
        f.addEventListener("submit", async (e) => {
          e.preventDefault();
          const email = f.email ? f.email.value.trim() : "", password = f.password ? f.password.value : "";
          const btn = f.querySelector("button"); btn.disabled = true;
          try {
            if (view === "signin") {
              const { error } = await sb.auth.signInWithPassword({ email, password });
              if (error) throw error;
              wrap.remove(); resolve();
            } else if (view === "signup") {
              const fullName = f.fullname ? f.fullname.value.trim() : "";
              if (fullName.length < 2) throw new Error("Type your full name.");
              if (password.length < 8) throw new Error("Use at least 8 characters for the password.");
              const { data, error } = await sb.auth.signUp({ email, password, options: { data: { full_name: fullName }, emailRedirectTo: location.origin + location.pathname } });
              if (error) throw error;
              if (data.session) { wrap.remove(); resolve(); return; }
              view = "signin"; draw("Check your email and tap the link to confirm, then sign in here.", "good");
            } else if (view === "forgot") {
              const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + "/" });
              if (error) throw error;
              draw("If that email has a login, a reset link is on its way.", "good");
            } else if (view === "newpass") {
              if (password.length < 8) throw new Error("Use at least 8 characters for the password.");
              const { error } = await sb.auth.updateUser({ password });
              if (error) throw error;
              wrap.remove(); resolve();
            }
          } catch (err) {
            const m = String(err.message || err);
            draw(/Invalid login/i.test(m) ? "That email and password don't match." :
                 /not confirmed/i.test(m) ? "Confirm your email first (check your inbox), then sign in." : m, "bad");
          } finally { const b = wrap.querySelector("button"); if (b) b.disabled = false; }
        });
        const first = wrap.querySelector("input"); if (first) first.focus();
      };
      draw();
    });
  }

  /* Wait for a signed-in user. Returns { email, role, staff, field, dash }.
     Roles: admin + manager (staff) see everything; field_tech (Field Tech) sees Equipment only;
     client sees Client view for its own approved events only (Dashboard is Stapleton's own page). */
  let recovering = false;
  sb.auth.onAuthStateChange((evt) => { if (evt === "PASSWORD_RECOVERY") recovering = true; });

  async function requireLogin(opts) {
    opts = opts || {};
    const bar = opts.bar;
    let { data } = await sb.auth.getSession();
    if (recovering || /type=recovery/.test(location.hash)) { await loginScreen("newpass"); recovering = false; }
    else if (!data.session) await loginScreen(location.hash === "#join" ? "signup" : "signin");
    let me;
    try { me = await rpc("web_me"); } catch (e) { me = { signed_in: true, staff: false, role: null, error: e }; }
    me.field = !!(me.staff || me.field);
    me.client = !me.staff && me.role === "client";
    me.dash = !!me.staff;
    me.cv = !!(me.staff || me.client);
    // Tabs start hidden and only appear for roles that can use them, so nobody sees a tab they can't open.
    if (bar) {
      bar.querySelector(".iq-out").hidden = false;
      bar.querySelectorAll("[data-staff]").forEach((a) => (a.hidden = !me.staff));
      bar.querySelectorAll("[data-dash]").forEach((a) => (a.hidden = !me.dash));
      bar.querySelectorAll("[data-cv]").forEach((a) => (a.hidden = !me.cv));
      bar.querySelectorAll("[data-field]").forEach((a) => (a.hidden = !me.field));
    }
    const ok = opts.staff ? me.staff : opts.field ? me.field : opts.dash ? me.dash : opts.cv ? me.cv : (me.dash || me.field || me.cv);
    if (!ok) {
      // A page they can't use (e.g. a typed-in link): send them to the page they can use instead of a dead end.
      const home = me.field ? "/gear" : me.client ? "/client" : me.dash ? "/dashboard" : null;
      if (home && location.pathname !== home) { location.replace(home); throw new Error("no_access"); }
      noAccess(me);
      throw new Error("no_access");
    }
    return me;
  }

  function noAccess(me) {
    const d = document.createElement("div");
    d.className = "iq-login";
    d.innerHTML = `<div class="iq-card"><div class="iq-mark">Stapleton IQ</div><h1>Almost there</h1>
      <p>You're signed in${me && me.email ? " as <b>" + String(me.email).replace(/[<>&"]/g, "") + "</b>" : ""}, but this login hasn't been given access to this page yet.
      Ask Joe to turn it on, then reload.</p>
      <button class="iq-primary" type="button">Sign out</button></div>`;
    d.querySelector("button").addEventListener("click", async () => { await sb.auth.signOut(); location.reload(); });
    document.body.appendChild(d);
  }

  /* ---------- install to home screen ---------- */
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
  }

  const ROLE_NAMES = { admin: "Admin", manager: "Manager", field_tech: "Field Tech", client: "Client" };
  const roleName = (r) => ROLE_NAMES[r] || r || "";

  return { sb, rpc, explain, topbar, requireLogin, roleName };
})();
