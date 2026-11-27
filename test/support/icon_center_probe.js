// Measures how far every icon is from the center of its box, in screen pixels. Used by test/system/icon_centering_test.rb
// and by .claude/skills/verify/icon_offsets.py, so the test and the agents' check run the same code.
//
// Convention (see IconHelper): an icon is an inline <svg> (or <img>) inside a container marked data-icon-box. The icon's
// *drawn geometry* (getBBox of each shape, mapped to the screen through its CTM, so the viewBox and any CSS rotation are
// included) is compared with the center of the box's content box (border box minus border and padding). The box marks
// data-icon-axis="y" when the icon sits beside a label: then only the vertical offset counts.
//
// Returns { icons: [{ icon, box, axis, dx, dy, off, center, rect }], unmarked: [selector, ...] } (center: the box's content-box center; rect: the icon's client rect).
(() => {
  const describe = (el) => {
    const bits = [el.tagName.toLowerCase()];
    if (el.id) bits.push("#" + el.id);
    const cls = typeof el.className === "string" ? el.className : (el.className.baseVal || "");
    cls.split(/\s+/).filter(Boolean).slice(0, 3).forEach((c) => bits.push("." + c));
    return bits.join("");
  };
  const geometryCenter = (el) => {
    if (el.tagName.toLowerCase() !== "svg") {
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
    }
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    el.querySelectorAll("path, circle, ellipse, line, polyline, polygon, rect").forEach((shape) => {
      if (shape.closest("defs, symbol, clipPath, mask")) return;
      const b = shape.getBBox(), m = shape.getScreenCTM();
      if (!m) return;
      [[b.x, b.y], [b.x + b.width, b.y], [b.x, b.y + b.height], [b.x + b.width, b.y + b.height]].forEach(([x, y]) => {
        const sx = m.a * x + m.c * y + m.e, sy = m.b * x + m.d * y + m.f;
        minX = Math.min(minX, sx); maxX = Math.max(maxX, sx); minY = Math.min(minY, sy); maxY = Math.max(maxY, sy);
      });
    });
    if (minX === Infinity) return null;
    return { x: (minX + maxX) / 2, y: (minY + maxY) / 2, w: maxX - minX, h: maxY - minY };
  };
  const contentCenter = (box) => {
    const r = box.getBoundingClientRect(), s = getComputedStyle(box);
    const left = r.left + parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft);
    const right = r.right - parseFloat(s.borderRightWidth) - parseFloat(s.paddingRight);
    const top = r.top + parseFloat(s.borderTopWidth) + parseFloat(s.paddingTop);
    const bottom = r.bottom - parseFloat(s.borderBottomWidth) - parseFloat(s.paddingBottom);
    return { x: (left + right) / 2, y: (top + bottom) / 2 };
  };
  const out = { icons: [], unmarked: [] };
  document.querySelectorAll("svg, img").forEach((icon) => {
    if (icon.closest("[data-icon-skip]") || icon.closest("symbol, defs")) return;
    const r = icon.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return; // hidden (the other half of a plus/minus pair, a tick that is not picked)
    const box = icon.closest("[data-icon-box]");
    if (!box) {
      // Only icons in controls are the rule's business; scenery (the landing props) is not.
      // (A plain <img> is a picture, such as the logo; only <svg> and <img class="icon"> count as icons.)
      if (icon.tagName.toLowerCase() === "img" && !icon.classList.contains("icon")) return;
      if (icon.closest("a, button, summary, label, [role=button], .badge")) out.unmarked.push(describe(icon.parentElement) + " > " + describe(icon));
      return;
    }
    const g = geometryCenter(icon);
    if (!g) return;
    const c = contentCenter(box), axis = box.dataset.iconAxis || "xy";
    const dx = axis === "y" ? 0 : g.x - c.x, dy = g.y - c.y;
    out.icons.push({ icon: describe(icon), box: describe(box), axis, dx: +dx.toFixed(2), dy: +dy.toFixed(2), off: +Math.max(Math.abs(dx), Math.abs(dy)).toFixed(2),
      center: [c.x, c.y], rect: [r.left, r.top, r.width, r.height] });
  });
  return out;
})()
