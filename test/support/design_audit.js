/*
 * The design-fundamentals DOM walker. One function expression, run in the page by
 *   - .claude/skills/verify/audit.py (headless Firefox, Playwright), and
 *   - test/system/design_audit_test.rb (headless Chrome, Selenium, CI).
 * It returns an array of {rule, selector, measured, expected, detail}. Rules: .claude/skills/verify/ui-brief.md
 * "Design fundamentals". The stylesheet-literal check (is this on a token scale?) is a Rails lint test instead,
 * because computed values of clamp()/vh declarations are off-scale at almost every width and would drown the report.
 * opts: {scales: false|true (also report off-scale radius/spacing/font-size from computed values; noisy), skip: [rules]}
 */
(opts) => {
  opts = opts || {};
  const findings = [];
  const root = document.documentElement;
  const rootStyle = getComputedStyle(root);
  const rem = parseFloat(rootStyle.fontSize) || 16;
  const tokenPx = (name) => {
    const probe = document.createElement("div");
    probe.style.cssText = `position:absolute;visibility:hidden;width:var(${name})`;
    root.appendChild(probe);
    const w = probe.getBoundingClientRect().width;
    probe.remove();
    return w;
  };
  const radiusFloor = tokenPx("--radius-inner-min") || 4;

  // Justified exceptions. Each: rule, a regex on the selector, and why. Keep this short and honest.
  const ALLOW = [
    { rule: "*", sel: /^(html|body)$/, why: "the document" },
    { rule: "targets", sel: /notification-settings__box|preferences_/, why: "the checkbox is 24px but the whole settings row is its label (::after covers the row, 44px tall)" },
    { rule: "targets", sel: /\bsr-only\b|\bvisually-hidden\b|skip-link/, why: "visually hidden or skip links reveal on focus" },
    { rule: "even-inset", sel: /\b(btn|cta|chip|choice|age-choice|pill|badge)\b/, why: "raised buttons fold the edge into their bottom padding (--press)" },
    { rule: "concentric", sel: /\b(sg-swatch)\b/, why: "styleguide swatches are demo chips" },
    { rule: "even-inset", sel: /fight__text/, why: "the sign board paints its bottom edge as an inset shadow, so its bottom padding is larger by the edge on purpose" },
    { rule: "badge", sel: /fight__post/, why: "signpost poles are painted art standing on the sign board, not badges" },
  ];
  const allowed = (rule, sel) => ALLOW.some((a) => (a.rule === "*" || a.rule === rule) && a.sel.test(sel));

  const skip = new Set(opts.skip || []);
  const px = (v) => parseFloat(v) || 0;
  const shortSel = (el) => {
    const parts = [];
    for (let e = el, n = 0; e && e.nodeType === 1 && n < 3; e = e.parentElement, n++) {
      let s = e.tagName.toLowerCase();
      if (e.id) { parts.unshift(s + "#" + e.id); break; }
      const cls = [...e.classList].slice(0, 2).join(".");
      if (cls) s += "." + cls;
      parts.unshift(s);
    }
    return parts.join(" > ");
  };
  const visible = (el, cs, r) => {
    if (cs.display === "none" || cs.visibility === "hidden" || parseFloat(cs.opacity) === 0) return false;
    return r.width > 1 && r.height > 1;
  };
  const add = (rule, el, measured, expected, detail) => {
    const selector = shortSel(el);
    if (skip.has(rule) || allowed(rule, selector)) return;
    findings.push({ rule, selector, measured, expected, detail: detail || "" });
  };
  const fmt = (n) => (Math.round(n * 10) / 10).toString();

  // Effective corner radii in px [tl, tr, br, bl], clamped the way CSS clamps them when they overflow a side.
  const corners = (el, cs, r) => {
    const one = (v, dim) => {
      const first = String(v).split(" ")[0];
      return first.endsWith("%") ? (parseFloat(first) / 100) * dim : px(first);
    };
    let [tl, tr, br, bl] = [
      one(cs.borderTopLeftRadius, r.width), one(cs.borderTopRightRadius, r.width),
      one(cs.borderBottomRightRadius, r.width), one(cs.borderBottomLeftRadius, r.width),
    ];
    const f = Math.min(1, r.width / (tl + tr || 1), r.width / (bl + br || 1), r.height / (tl + bl || 1), r.height / (tr + br || 1));
    return [tl * f, tr * f, br * f, bl * f];
  };
  const isPill = (c, r) => Math.max(...c) >= Math.min(r.width, r.height) / 2 - 0.5 && Math.max(...c) > 0;
  const isBox = (el, cs) => {
    const bg = cs.backgroundColor;
    const hasBg = bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent";
    const hasImg = cs.backgroundImage !== "none";
    const hasBorder = px(cs.borderTopWidth) + px(cs.borderBottomWidth) + px(cs.borderLeftWidth) + px(cs.borderRightWidth) > 0;
    const replaced = /^(IMG|VIDEO|CANVAS|PICTURE|SVG)$/i.test(el.tagName);
    return hasBg || hasImg || hasBorder || replaced;
  };

  const all = [...document.body.querySelectorAll("*")].filter((el) => !/^(SCRIPT|STYLE|LINK|META|NOSCRIPT|TEMPLATE|PATH|G|DEFS|USE|CIRCLE|RECT|LINE|POLYGON|POLYLINE|ELLIPSE|CLIPPATH|MASK|TITLE|DESC)$/i.test(el.tagName));
  const info = new Map();
  for (const el of all) {
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    info.set(el, { cs, r, vis: visible(el, cs, r) });
  }
  const nearestBoxAncestor = (el) => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const i = info.get(p);
      if (i && i.vis && isBox(p, i.cs) && corners(p, i.cs, i.r).some((c) => c > 0)) return p;
      if (i && i.cs.overflow !== "visible" && corners(p, i.cs, i.r).some((c) => c > 0)) return p;
    }
    return null;
  };

  const SCALE_SPACE = [0, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128].map((n) => n * (rem / 16));

  for (const el of all) {
    const { cs, r, vis } = info.get(el);
    if (!vis) continue;

    // 1 + 2: concentric corners (child radius vs parent radius minus the gap), per corner.
    if (isBox(el, cs)) {
      const c = corners(el, cs, r);
      // Form controls and buttons keep the control radius (rule 5: one radius per kind of thing), so they are not held to the
      // concentric formula; cards, tiles and pictures are.
      const isControl = /^(BUTTON|INPUT|SELECT|TEXTAREA)$/.test(el.tagName) || el.matches("a.btn, a.cta, .btn, .cta");
      if (c.some((n) => n > 0) && !isPill(c, r) && !isControl && cs.position !== "absolute" && cs.position !== "fixed") {
        const parent = nearestBoxAncestor(el);
        if (parent) {
          const pi = info.get(parent);
          const pc = corners(parent, pi.cs, pi.r);
          const pr = pi.r;
          const bw = [px(pi.cs.borderTopWidth), px(pi.cs.borderRightWidth), px(pi.cs.borderBottomWidth), px(pi.cs.borderLeftWidth)];
          const inL = r.left - pr.left - bw[3], inR = pr.right - r.right - bw[1], inT = r.top - pr.top - bw[0], inB = pr.bottom - r.bottom - bw[2];
          const gaps = [Math.min(inT, inL), Math.min(inT, inR), Math.min(inB, inR), Math.min(inB, inL)];
          const names = ["top-left", "top-right", "bottom-right", "bottom-left"];
          if (!isPill(pc, pr)) {
            for (let k = 0; k < 4; k++) {
              if (pc[k] <= 0 || gaps[k] < -1 || gaps[k] >= pc[k]) continue;
              const expected = Math.min(Math.min(r.width, r.height) / 2, Math.max(radiusFloor, pc[k] - Math.max(0, gaps[k])));
              // Near the corner (gap under half the outer radius) the child must match within 2px. Farther in, the outer curve is
              // distant, so the child may be rounder than the formula by up to a third of the outer radius, but not by more.
              const far = gaps[k] >= pc[k] / 2;
              const bad = far ? c[k] - expected > Math.max(2, pc[k] * 0.35) : Math.abs(c[k] - expected) > 2;
              if (bad) {
                add("concentric", el, `${fmt(c[k])}px ${names[k]}`, `${fmt(expected)}px (parent ${fmt(pc[k])} - gap ${fmt(Math.max(0, gaps[k]))})`, `inside ${shortSel(parent)}`);
              }
            }
          }
        }
      }
    }

    // 3: even insets. (a) declared padding of a card: left = right, top = bottom (minus the raised edge).
    if (isBox(el, cs) && el.children.length && !/^(A|BUTTON|INPUT|SELECT|SUMMARY|TD|TH|TR|TABLE)$/.test(el.tagName) && !el.closest("a,button")) {
      const pad = [px(cs.paddingTop), px(cs.paddingRight), px(cs.paddingBottom), px(cs.paddingLeft)];
      const edge = px(cs.borderBottomWidth);
      const corner = corners(el, cs, r);
      const looksCard = Math.max(...corner) >= 8 && Math.min(...pad) > 0;
      if (looksCard) {
        if (Math.abs(pad[1] - pad[3]) > 2) add("even-inset", el, `padding left ${fmt(pad[3])}px, right ${fmt(pad[1])}px`, "equal sides", "");
        if (Math.abs(pad[0] - pad[2]) > 2) add("even-inset", el, `padding top ${fmt(pad[0])}px, bottom ${fmt(pad[2])}px`, "equal top and bottom", edge ? `bottom border ${fmt(edge)}px` : "");
      }
      // (b) a visual-box child near the start corner: its gaps to the sides it sits near must match each other.
      const kids = [...el.children].filter((k) => { const i = info.get(k); return i && i.vis && isBox(k, i.cs) && i.cs.position !== "absolute" && i.cs.position !== "fixed"; });
      if (looksCard) {
        for (const k of kids) {
          const kr = info.get(k).r;
          const bw = [px(cs.borderTopWidth), px(cs.borderRightWidth), px(cs.borderBottomWidth), px(cs.borderLeftWidth)];
          const L = kr.left - r.left - bw[3], T = kr.top - r.top - bw[0], B = r.bottom - kr.bottom - bw[2];
          const near = [["left", L], ["top", T], ["bottom", B]].filter(([, v]) => v >= 0 && v < 64);
          if (near.length >= 3 || (near.length === 2 && kr.height >= (r.height - bw[0] - bw[2]) * 0.6)) {
            const vals = near.map(([, v]) => v);
            if (Math.max(...vals) - Math.min(...vals) > 2) {
              add("even-inset", k, near.map(([n, v]) => `${n} ${fmt(v)}px`).join(", "), "equal gaps on the sides it sits near", `child of ${shortSel(el)}`);
            }
          }
        }
      }
    }

    // 4: touch targets.
    if (el.matches('a[href], button, input:not([type=hidden]), select, summary, [role=button], [role=tab], [tabindex]:not([tabindex="-1"])')) {
      let skipIt = false;
      if (el.tagName === "A" && cs.display === "inline") {
        const parent = el.parentElement;
        const text = [...parent.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 0);
        if (text) skipIt = true; // inline link in running text (WCAG 2.5.8 exemption)
      }
      if (el.tagName === "INPUT" && (el.type === "checkbox" || el.type === "radio") && el.closest("label")) skipIt = true;
      if (!skipIt && (r.width < 43.5 || r.height < 43.5)) add("targets", el, `${fmt(r.width)}x${fmt(r.height)}px`, "at least 44x44px", (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 30));
    }

    // 5: text measure (widest rendered line over 75 characters, in the element's own font).
    if (/^(P|LI|BLOCKQUOTE|DD|DIV|SPAN)$/.test(el.tagName)) {
      const own = [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim().length > 0);
      const total = own.map((n) => n.textContent.trim()).join(" ");
      if (total.length > 80) {
        const range = document.createRange();
        let widest = 0;
        for (const n of own) { range.selectNodeContents(n); for (const rect of range.getClientRects()) widest = Math.max(widest, rect.width); }
        const canvas = (opts._canvas = opts._canvas || document.createElement("canvas")).getContext("2d");
        canvas.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
        const zero = canvas.measureText("0").width || px(cs.fontSize) * 0.55;
        const chars = widest / zero;
        if (chars > 75) add("measure", el, `${Math.round(chars)}ch (${fmt(widest)}px)`, "at most 75ch", total.slice(0, 30));
      }
    }

    // 5b: orphans. A heading or a centered short paragraph whose last row is a lone word or fragment (under 15% of the row above).
    if (/^(H1|H2|H3|H4|H5|H6|LEGEND|P|DIV|SPAN)$/.test(el.tagName) && (/^H[1-6]$|^LEGEND$/.test(el.tagName) || /card__title|__title|__heading|__head$/.test(el.className) || (cs.textAlign === "center" && el.tagName === "P"))) {
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      const rows = new Map();
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (!n.textContent.trim()) continue;
        const range = document.createRange();
        range.selectNodeContents(n);
        for (const rect of range.getClientRects()) {
          if (rect.width < 1) continue;
          const key = Math.round(rect.top / 4);
          const row = rows.get(key) || { left: rect.left, right: rect.right };
          row.left = Math.min(row.left, rect.left); row.right = Math.max(row.right, rect.right);
          rows.set(key, row);
        }
      }
      const ordered = [...rows.entries()].sort((a, b) => a[0] - b[0]).map(([, v]) => v.right - v.left);
      if (ordered.length >= 2) {
        const last = ordered[ordered.length - 1], prev = ordered[ordered.length - 2];
        if (last < prev * 0.15) add("orphan", el, `last row ${fmt(last)}px of ${fmt(prev)}px above (${Math.round((last / prev) * 100)}%)`, "at least 15% of the row above (text-wrap: balance or pretty)", (el.textContent || "").trim().slice(-24));
      }
    }

    // 6: badges and overlays: small absolutely placed boxes must sit inside the container (clear of the corner curve) or exactly on its corner/edge.
    if ((cs.position === "absolute") && r.width <= 96 && r.height <= 96 && isBox(el, cs) && el.parentElement) {
      const parent = el.parentElement;
      const pi = info.get(parent);
      if (pi && pi.vis && isBox(parent, pi.cs) && parent !== document.body) {
        const pr = pi.r, pc = corners(parent, pi.cs, pr);
        const inside = r.left >= pr.left - 0.5 && r.right <= pr.right + 0.5 && r.top >= pr.top - 0.5 && r.bottom <= pr.bottom + 0.5;
        const cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        const rad = Math.min(r.width, r.height) / 2;
        const ptsX = [pr.left, pr.right], ptsY = [pr.top, pr.bottom];
        const onCorner = ptsX.some((x) => Math.abs(cx - x) <= 1.5) && ptsY.some((y) => Math.abs(cy - y) <= 1.5);
        const onEdge = ptsX.some((x) => Math.abs(cx - x) <= 1.5) || ptsY.some((y) => Math.abs(cy - y) <= 1.5);
        if (inside) {
          // fully inside: must clear the corner arc
          const arcs = [[pr.left + pc[0], pr.top + pc[0], pc[0], r.left < pr.left + pc[0] && r.top < pr.top + pc[0]],
            [pr.right - pc[1], pr.top + pc[1], pc[1], r.right > pr.right - pc[1] && r.top < pr.top + pc[1]],
            [pr.right - pc[2], pr.bottom - pc[2], pc[2], r.right > pr.right - pc[2] && r.bottom > pr.bottom - pc[2]],
            [pr.left + pc[3], pr.bottom - pc[3], pc[3], r.left < pr.left + pc[3] && r.bottom > pr.bottom - pc[3]]];
          for (const [ax, ay, ar, hit] of arcs) {
            if (!hit || ar <= 0) continue;
            const round = px(cs.borderTopLeftRadius) >= Math.min(r.width, r.height) / 2 - 0.5;
            const d = round ? Math.hypot(cx - ax, cy - ay) + rad : Math.hypot((cx < ax ? r.left : cx > ax ? r.right : cx) - ax, (cy < ay ? r.top : cy > ay ? r.bottom : cy) - ay);
            if (d > ar + 0.5) add("badge", el, `reaches ${fmt(d)}px from the corner arc center`, `inside the curve (${fmt(ar)}px)`, `inside ${shortSel(parent)}; it touches the corner curve`);
          }
        } else if (!onCorner && !(onEdge && pr.width > 0)) {
          add("badge", el, `box ${fmt(r.left - pr.left)},${fmt(r.top - pr.top)} partly outside ${shortSel(parent)}`, "fully inside, or centered exactly on the corner or edge", "half hanging off by accident");
        }
      }
    }

    // 7 (opt-in): computed values that are off the scales.
    if (opts.scales && isBox(el, cs)) {
      const c = corners(el, cs, r);
      const known = ["--radius-sm", "--radius-md", "--radius-lg", "--radius-xl", "--radius-card"].map(tokenPx).concat([0, radiusFloor]);
      for (const v of c) if (v > 0 && !isPill(c, r) && !known.some((k) => Math.abs(k - v) < 0.6)) { add("scale-radius", el, `${fmt(v)}px`, "a --radius-* token or the concentric value", ""); break; }
    }
    if (opts.scales && el.children.length) {
      for (const p of ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft", "rowGap", "columnGap"]) {
        const v = px(cs[p]);
        if (v > 0 && !SCALE_SPACE.some((k) => Math.abs(k - v) < 0.6)) { add("scale-space", el, `${p} ${fmt(v)}px`, "a --space-* step", ""); break; }
      }
    }
  }
  // collapse duplicates (same rule, selector, measured)
  const seen = new Set();
  return findings.filter((f) => { const k = f.rule + f.selector + f.measured; if (seen.has(k)) return false; seen.add(k); return true; });
}
