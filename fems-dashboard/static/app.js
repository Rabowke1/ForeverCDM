"use strict";

const $ = (id) => document.getElementById(id);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const nf0 = new Intl.NumberFormat("de-DE", { maximumFractionDigits: 0 });
const nf1 = new Intl.NumberFormat("de-DE", { minimumFractionDigits: 1, maximumFractionDigits: 1 });

function fmtPower(w) {
  if (w == null) return "–";
  return Math.abs(w) >= 1000 ? `${nf1.format(w / 1000)} kW` : `${nf0.format(w)} W`;
}
function fmtEnergy(wh) {
  if (wh == null) return "–";
  return Math.abs(wh) >= 1e6 ? `${nf1.format(wh / 1e6)} MWh` : `${nf1.format(wh / 1000)} kWh`;
}
const fmtPct = (p) => (p == null ? "–" : `${nf0.format(p)} %`);
const isoDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

async function getJSON(url) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

/* ---------- Live-Werte ---------- */

let lastLiveTs = null;

async function refreshLive() {
  let data;
  try {
    data = await getJSON("/api/live");
  } catch (e) {
    setStatus("error", "Dashboard-Server nicht erreichbar");
    return;
  }
  const v = data.values || {};
  $("v-production").textContent = fmtPower(v.production);
  $("v-consumption").textContent = fmtPower(v.consumption);
  $("v-ess").textContent = fmtPower(v.ess == null ? null : Math.abs(v.ess));
  $("v-ess-dir").textContent = v.ess == null ? "–" : v.ess > 20 ? "entlädt" : v.ess < -20 ? "lädt" : "Standby";
  $("v-grid").textContent = fmtPower(v.grid == null ? null : Math.abs(v.grid));
  $("v-grid-dir").textContent = v.grid == null ? "–" : v.grid > 20 ? "Bezug" : v.grid < -20 ? "Einspeisung" : "ausgeglichen";
  $("v-soc").textContent = fmtPct(v.soc);
  $("soc-fill").style.width = `${Math.max(0, Math.min(100, v.soc || 0))}%`;
  $("soc-meter").setAttribute("aria-valuenow", v.soc ?? 0);

  const t = data.today || {};
  for (const k of ["production", "consumption", "grid_buy", "grid_sell"]) $(`t-${k}`).textContent = fmtEnergy(t[k]);
  $("t-autarky").textContent = fmtPct(t.autarky);
  $("t-self_consumption").textContent = fmtPct(t.self_consumption);

  const when = data.ts ? new Date(data.ts * 1000).toLocaleTimeString("de-DE") : "–";
  const demo = data.demo ? " · Demo-Modus" : "";
  if (data.ok) setStatus("ok", `Verbunden · ${when}${demo}`);
  else setStatus("error", `${data.error}${data.ts ? ` · letzte Daten ${when}` : ""}`);

  // Beim Blick auf heute die Kurve jede Minute nachziehen.
  if (data.ts && currentDay === isoDay(new Date()) && (!lastLiveTs || data.ts - lastLiveTs >= 60)) {
    lastLiveTs = data.ts;
    loadHistory();
  }
}

function setStatus(kind, text) {
  $("status").className = `status ${kind}`;
  $("status-text").textContent = text;
}

/* ---------- Diagramme ---------- */

const POWER_SERIES = [
  { key: "production", label: "Erzeugung", slot: 1 },
  { key: "consumption", label: "Verbrauch", slot: 2 },
  { key: "ess", label: "Batterie", slot: 3 },
  { key: "grid", label: "Netz", slot: 4 },
];
const ENERGY_SERIES = [
  { key: "production", label: "Erzeugung", slot: 1 },
  { key: "consumption", label: "Verbrauch", slot: 2 },
  { key: "grid_buy", label: "Netzbezug", slot: 4 },
  { key: "grid_sell", label: "Einspeisung", slot: 5 },
];

function legend(el, series) {
  el.innerHTML = series.map((s) => `<span data-series="${s.slot}"><i class="swatch"></i>${s.label}</span>`).join("");
}

function baseOptions() {
  const muted = css("--muted"), grid = css("--grid");
  return {
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    interaction: { mode: "index", intersect: false },
    plugins: {
      legend: { display: false },
      tooltip: {
        backgroundColor: css("--surface"), titleColor: css("--text"), bodyColor: css("--text-2"),
        borderColor: css("--axis"), borderWidth: 1, padding: 10, boxPadding: 4, usePointStyle: true,
      },
    },
    scales: {
      x: { grid: { display: false }, border: { color: css("--axis") }, ticks: { color: muted, maxRotation: 0, autoSkipPadding: 16 } },
      y: { grid: { color: grid }, border: { display: false }, ticks: { color: muted } },
    },
  };
}

let powerChart, socChart, energyChart;
let currentDay = isoDay(new Date());
let currentGroup = "day";
let historyData = null, energyData = null;

function timeTicks(chart) {
  chart.options.scales.x.type = "linear";
  chart.options.scales.x.ticks.callback = (v) => new Date(v).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
  chart.options.scales.x.ticks.stepSize = 3 * 3600 * 1000;
  chart.options.plugins.tooltip.callbacks = {
    title: (items) => new Date(items[0].parsed.x).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" }),
    ...(chart.options.plugins.tooltip.callbacks || {}),
  };
}

function renderHistory() {
  if (!historyData) return;
  const pts = historyData.points;
  const [y, m, d] = currentDay.split("-").map(Number);
  const dayStart = new Date(y, m - 1, d).getTime();
  const dayEnd = dayStart + 24 * 3600 * 1000;

  const powerOpts = baseOptions();
  powerOpts.scales.x.min = dayStart;
  powerOpts.scales.x.max = dayEnd;
  powerOpts.scales.y.ticks.callback = (v) => fmtPower(v);
  powerOpts.plugins.tooltip.callbacks = { label: (c) => ` ${c.dataset.label}: ${fmtPower(c.parsed.y)}` };
  const datasets = POWER_SERIES.map((s) => ({
    label: s.label,
    data: pts.map((p) => ({ x: p.ts * 1000, y: p[s.key] })),
    borderColor: css(`--series-${s.slot}`),
    backgroundColor: css(`--series-${s.slot}`),
    borderWidth: 2, pointRadius: 0, pointHoverRadius: 4, tension: 0.2, spanGaps: 5 * 60 * 1000,
  }));
  if (powerChart) powerChart.destroy();
  powerChart = new Chart($("power-chart"), { type: "line", data: { datasets }, options: powerOpts });
  timeTicks(powerChart);
  powerChart.update();

  const socOpts = baseOptions();
  socOpts.scales.x.min = dayStart;
  socOpts.scales.x.max = dayEnd;
  socOpts.scales.y.min = 0;
  socOpts.scales.y.max = 100;
  socOpts.scales.y.ticks.stepSize = 50;
  socOpts.scales.y.ticks.callback = (v) => `${v} %`;
  socOpts.plugins.tooltip.callbacks = { label: (c) => ` Ladezustand: ${fmtPct(c.parsed.y)}` };
  const socColor = css("--series-3");
  if (socChart) socChart.destroy();
  socChart = new Chart($("soc-chart"), {
    type: "line",
    data: { datasets: [{
      label: "Ladezustand", data: pts.map((p) => ({ x: p.ts * 1000, y: p.soc })),
      borderColor: socColor, backgroundColor: socColor + "33", fill: "origin",
      borderWidth: 2, pointRadius: 0, pointHoverRadius: 4, spanGaps: 5 * 60 * 1000,
    }] },
    options: socOpts,
  });
  timeTicks(socChart);
  socChart.update();
}

async function loadHistory() {
  $("day-input").value = currentDay;
  $("day-next").disabled = currentDay >= isoDay(new Date());
  try {
    historyData = await getJSON(`/api/history?date=${currentDay}`);
    renderHistory();
  } catch (e) { /* Status-Anzeige übernimmt refreshLive */ }
}

function labelFor(key) {
  if (currentGroup === "year") return key;
  if (currentGroup === "month") {
    const [y, m] = key.split("-").map(Number);
    return new Date(y, m - 1, 1).toLocaleDateString("de-DE", { month: "short", year: "2-digit" });
  }
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d).toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" });
}

function renderEnergy() {
  if (!energyData) return;
  const rows = energyData.rows;
  const opts = baseOptions();
  opts.scales.y.ticks.callback = (v) => fmtEnergy(v);
  opts.plugins.tooltip.callbacks = {
    label: (c) => ` ${c.dataset.label}: ${fmtEnergy(c.parsed.y)}`,
    footer: (items) => {
      const r = rows[items[0].dataIndex];
      return `Autarkie ${fmtPct(r.autarky)} · Eigenverbrauch ${fmtPct(r.self_consumption)}`;
    },
  };
  opts.plugins.tooltip.footerColor = css("--text-2");
  opts.plugins.tooltip.footerFont = { weight: "normal" };
  const datasets = ENERGY_SERIES.map((s) => ({
    label: s.label,
    data: rows.map((r) => r[s.key]),
    backgroundColor: css(`--series-${s.slot}`),
    borderRadius: { topLeft: 4, topRight: 4 }, borderSkipped: "bottom",
    categoryPercentage: 0.8, barPercentage: 0.9,
  }));
  if (energyChart) energyChart.destroy();
  energyChart = new Chart($("energy-chart"), {
    type: "bar", data: { labels: rows.map((r) => labelFor(r.date)), datasets }, options: opts,
  });

  const head = ["Zeitraum", ...ENERGY_SERIES.map((s) => s.label), "Batterie geladen", "Batterie entladen", "Autarkie", "Eigenverbrauch"];
  const body = rows.slice().reverse().map((r) => [
    labelFor(r.date), ...ENERGY_SERIES.map((s) => fmtEnergy(r[s.key])),
    fmtEnergy(r.ess_charge), fmtEnergy(r.ess_discharge), fmtPct(r.autarky), fmtPct(r.self_consumption),
  ]);
  $("energy-table").innerHTML =
    `<thead><tr>${head.map((h) => `<th>${h}</th>`).join("")}</tr></thead>` +
    `<tbody>${body.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("")}</tbody>`;
}

async function loadEnergy() {
  try {
    // Auf schmalen Bildschirmen nur 14 statt 30 Tage, damit die Balken lesbar bleiben.
    let url = `/api/energy?group=${currentGroup}`;
    if (currentGroup === "day" && window.innerWidth < 600) {
      const from = new Date(); from.setDate(from.getDate() - 13);
      url += `&from=${isoDay(from)}`;
    }
    energyData = await getJSON(url);
    renderEnergy();
  } catch (e) { /* s. o. */ }
}

/* ---------- Bedienung ---------- */

function shiftDay(delta) {
  const [y, m, d] = currentDay.split("-").map(Number);
  const next = new Date(y, m - 1, d + delta);
  if (isoDay(next) > isoDay(new Date())) return;
  currentDay = isoDay(next);
  loadHistory();
}

$("day-prev").addEventListener("click", () => shiftDay(-1));
$("day-next").addEventListener("click", () => shiftDay(1));
$("day-today").addEventListener("click", () => { currentDay = isoDay(new Date()); loadHistory(); });
$("day-input").max = isoDay(new Date());
$("day-input").addEventListener("change", (e) => { if (e.target.value) { currentDay = e.target.value; loadHistory(); } });

document.querySelectorAll(".segmented button").forEach((btn) => btn.addEventListener("click", () => {
  document.querySelectorAll(".segmented button").forEach((b) => b.classList.toggle("active", b === btn));
  currentGroup = btn.dataset.group;
  loadEnergy();
}));

// Farben bei Wechsel hell/dunkel neu einlesen.
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { renderHistory(); renderEnergy(); });

legend($("power-legend"), POWER_SERIES);
legend($("energy-legend"), ENERGY_SERIES);
if (window.Chart) {
  Chart.defaults.font.family = 'system-ui, -apple-system, "Segoe UI", sans-serif';
  Chart.defaults.font.size = 12;
}
refreshLive();
loadHistory();
loadEnergy();
setInterval(refreshLive, 5000);
setInterval(loadEnergy, 10 * 60 * 1000);
