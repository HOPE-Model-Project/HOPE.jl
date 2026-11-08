"""Generate the interactive Maryland adaptive-agent experiment map.

The generated page embeds all experiment and GIS data. It uses D3 only for
projection and drawing at runtime; it does not fetch model data in the browser.
"""

from __future__ import annotations

import csv
import json
import math
import urllib.request
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "src" / "assets" / "adaptive_maryland_r01_r03_story.html"
COUNTY_CACHE = ROOT / ".tmp" / "us-counties-10m.json"
COUNTY_URL = "https://cdn.jsdelivr.net/npm/us-atlas@3/counties-10m.json"

PCM_DATA = (
    ROOT
    / "ModelCases"
    / "MD_PCM_transmission_public_case"
    / "Data_MD_PCM_transmission_public"
)
ZONE_GEOJSON = ROOT / "tools" / "hope_dashboard" / "data" / "pjm_utility_zones.geojson"
R03 = ROOT / "artifacts" / "adaptive_agent_studies" / "claude-md-adaptive-20261107-r03"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def point_segment_distance(point, start, end):
    px, py = point
    x1, y1 = start
    x2, y2 = end
    dx = x2 - x1
    dy = y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(px - x1, py - y1)
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def rdp(points, tolerance):
    if len(points) <= 2:
        return points
    start, end = points[0], points[-1]
    best_index = 0
    best_distance = 0.0
    for index, point in enumerate(points[1:-1], 1):
        distance = point_segment_distance(point, start, end)
        if distance > best_distance:
            best_index = index
            best_distance = distance
    if best_distance > tolerance:
        left = rdp(points[: best_index + 1], tolerance)
        right = rdp(points[best_index:], tolerance)
        return left[:-1] + right
    return [start, end]


def simplify_ring(ring, tolerance=0.0015):
    if len(ring) < 5:
        return ring
    closed = ring[0] == ring[-1]
    body = ring[:-1] if closed else ring
    reduced = rdp(body + [body[0]], tolerance)
    if reduced[0] != reduced[-1]:
        reduced.append(reduced[0])
    return reduced if len(reduced) >= 4 else ring


def simplify_geometry(geometry, tolerance=0.0015):
    kind = geometry["type"]
    coordinates = geometry["coordinates"]
    if kind == "Polygon":
        coordinates = [simplify_ring(ring, tolerance) for ring in coordinates]
    elif kind == "MultiPolygon":
        coordinates = [
            [simplify_ring(ring, tolerance) for ring in polygon]
            for polygon in coordinates
        ]
    return {"type": kind, "coordinates": coordinates}


def decode_topology_geometry(topology, geometry):
    transform = topology.get("transform")

    def decode_arc(index):
        reverse = index < 0
        source = topology["arcs"][~index if reverse else index]
        x = y = 0
        points = []
        for dx, dy in source:
            x += dx
            y += dy
            if transform:
                point = [
                    x * transform["scale"][0] + transform["translate"][0],
                    y * transform["scale"][1] + transform["translate"][1],
                ]
            else:
                point = [x, y]
            points.append(point)
        return list(reversed(points)) if reverse else points

    def stitch(indices):
        result = []
        for index in indices:
            arc = decode_arc(index)
            if result and arc and result[-1] == arc[0]:
                result.extend(arc[1:])
            else:
                result.extend(arc)
        return result

    kind = geometry["type"]
    if kind == "Polygon":
        coordinates = [stitch(ring) for ring in geometry["arcs"]]
    elif kind == "MultiPolygon":
        coordinates = [
            [stitch(ring) for ring in polygon] for polygon in geometry["arcs"]
        ]
    else:
        raise ValueError(f"Unsupported TopoJSON geometry: {kind}")
    return {"type": kind, "coordinates": coordinates}


def load_maryland_boundaries():
    if not COUNTY_CACHE.exists():
        COUNTY_CACHE.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(COUNTY_URL, COUNTY_CACHE)
    topology = json.loads(COUNTY_CACHE.read_text(encoding="utf-8"))
    counties = []
    for geometry in topology["objects"]["counties"]["geometries"]:
        identifier = str(geometry["id"]).zfill(5)
        if not identifier.startswith("24"):
            continue
        counties.append(
            {
                "type": "Feature",
                "properties": {
                    "id": identifier,
                    "name": geometry.get("properties", {}).get("name", identifier),
                },
                "geometry": simplify_geometry(
                    decode_topology_geometry(topology, geometry), 0.002
                ),
            }
        )
    state_geometry = next(
        geometry
        for geometry in topology["objects"]["states"]["geometries"]
        if str(geometry["id"]).zfill(2) == "24"
    )
    state = {
        "type": "Feature",
        "properties": {"name": "Maryland"},
        "geometry": simplify_geometry(
            decode_topology_geometry(topology, state_geometry), 0.001
        ),
    }
    return state, counties


def load_zones():
    source = json.loads(ZONE_GEOJSON.read_text(encoding="utf-8"))
    wanted = {"BC_MD": "BGE", "PEP_MD": "PEPCO"}
    features = []
    for feature in source["features"]:
        zone_id = feature["properties"].get("zone_id")
        if zone_id not in wanted:
            continue
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "zone": wanted[zone_id],
                    "utility": feature["properties"].get("utility", ""),
                },
                "geometry": simplify_geometry(feature["geometry"], 0.002),
            }
        )
    return features


def load_network():
    buses_raw = read_csv(PCM_DATA / "busdata.csv")
    buses = {}
    for row in buses_raw:
        latitude = float(row["Latitude"])
        longitude = float(row["Longitude"])
        if not (-79.7 <= longitude <= -74.8 and 37.6 <= latitude <= 39.9):
            continue
        buses[row["Bus_id"]] = {
            "id": row["Bus_id"],
            "zone": row["Zone_id"],
            "state": row["State"],
            "lat": round(latitude, 6),
            "lon": round(longitude, 6),
            "loadShare": round(float(row.get("Load_share") or 0), 7),
        }

    branches = []
    for row in read_csv(PCM_DATA / "branchdata.csv"):
        source = buses.get(row["from_bus"])
        target = buses.get(row["to_bus"])
        if not source or not target:
            continue
        branches.append(
            {
                "id": row["Corridor_ID"],
                "from": source["id"],
                "to": target["id"],
                "capacity": float(row["Forward Capacity (MW)"]),
                "coordinates": [
                    [source["lon"], source["lat"]],
                    [target["lon"], target["lat"]],
                ],
            }
        )
    return list(buses.values()), branches


def technology_group(value):
    value = (value or "Other").lower()
    if "solar" in value:
        return "Solar"
    if "wind" in value:
        return "Wind"
    if "nuclear" in value:
        return "Nuclear"
    if "hydro" in value:
        return "Hydro"
    if "battery" in value or "storage" in value:
        return "Storage"
    if any(token in value for token in ("ng", "gas", "coal", "oil", "steam", "thermal")):
        return "Thermal"
    return "Other"


def load_generators():
    grouped = defaultdict(lambda: {"mw": 0.0, "units": 0, "names": set()})
    for row in read_csv(PCM_DATA / "gendata.csv"):
        try:
            latitude = float(row["Latitude"])
            longitude = float(row["Longitude"])
            capacity = float(row["Pmax (MW)"] or 0)
        except (TypeError, ValueError):
            continue
        if capacity <= 0 or not (-79.7 <= longitude <= -74.8 and 37.6 <= latitude <= 39.9):
            continue
        group = technology_group(row.get("Type") or row.get("SourceTechnology"))
        key = (round(latitude, 4), round(longitude, 4), group, row.get("Zone", ""))
        grouped[key]["mw"] += capacity
        grouped[key]["units"] += 1
        grouped[key]["names"].add(row.get("PlantName") or row.get("GeneratorID") or "Plant")
    result = []
    for (latitude, longitude, group, zone), values in grouped.items():
        result.append(
            {
                "lat": latitude,
                "lon": longitude,
                "group": group,
                "zone": zone,
                "mw": round(values["mw"], 2),
                "units": values["units"],
                "name": ", ".join(sorted(values["names"])[:3]),
            }
        )
    return result


def load_allocations(iteration, bus_index):
    path = R03 / "iterations" / f"{iteration:02d}" / "pcm_ensemble" / "realization_allocations.csv"
    result = []
    for row in read_csv(path):
        bus = bus_index[row["BusID"]]
        result.append(
            {
                "variant": row["Variant"],
                "project": row["PlanItemID"],
                "bus": row["BusID"],
                "zone": row["Zone"],
                "type": row["Type"],
                "mw": round(float(row["AllocatedMW"]), 3),
                "review": row["ReviewRequired"].lower() == "true",
                "reason": row["ReviewReason"],
                "lat": bus["lat"],
                "lon": bus["lon"],
            }
        )
    return result


def load_findings(iteration):
    path = R03 / "iterations" / f"{iteration:02d}" / "pcm_ensemble" / "ensemble_findings.csv"
    result = {}
    for row in read_csv(path):
        result[row["Variant"]] = {
            "accepted": row["Accepted"].lower() == "true",
            "classification": row["Classification"],
            "loadShed": round(float(row["LoadSheddingMWh"]), 3),
            "dispatch": round(float(row["NewGenerationDispatchMWh"]), 3),
            "review": row["HumanReviewRequired"].lower() == "true",
            "reason": row["Reason"],
        }
    return result


def build_data():
    state, counties = load_maryland_boundaries()
    buses, branches = load_network()
    bus_index = {bus["id"]: bus for bus in buses}
    return {
        "state": state,
        "counties": counties,
        "zones": load_zones(),
        "buses": buses,
        "branches": branches,
        "generators": load_generators(),
        "iteration1": {
            "allocations": load_allocations(1, bus_index),
            "findings": load_findings(1),
        },
        "iteration2": {
            "allocations": load_allocations(2, bus_index),
            "findings": load_findings(2),
        },
        "replicates": {
            "r01": {
                "label": "Workflow shakedown",
                "status": "Passed after evidence-interface improvement",
                "calls": "24 calls · 7 active · 16 waits · 1 status",
                "lesson": "The agent stopped rather than assume the BGE/PEPCO diagnosis. Build-zone and shortfall-zone evidence was then added to adaptive responses.",
            },
            "r02": {
                "label": "Development validation",
                "status": "Passed after completion-state repair",
                "calls": "25 calls · 7 active · 17 waits · 1 status",
                "lesson": "The evidence contract worked, then exposed inconsistent handling of equivalent done/completed process states.",
            },
            "r03": {
                "label": "Clean formal benchmark",
                "status": "Model passed · Agent passed",
                "calls": "20 calls · 7 active · 13 waits · 0 status · 0 invalid",
                "lesson": "The unchanged corrected workflow completed with exactly two launches, one approved revision, and one accepted realization.",
            },
        },
    }


HTML = r'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Maryland adaptive-agent experiment</title>
  <script src="https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js"></script>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f5f7f9; --panel: #ffffff; --text: #17212b; --muted: #5f6b76;
      --border: #d7dde3; --network: #6f7c87; --county: #101820;
      --bge: #337ab7; --pepco: #7a4ea3; --danger: #c43d4b; --ok: #23835b;
      --warning: #b46a17; --accent: #145da0; --project: #f28e2b;
      --shadow: 0 8px 26px rgba(20, 32, 44, .10);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #10161d; --panel: #18212a; --text: #eef3f7; --muted: #aab6c1;
        --border: #35424d; --network: #8a98a5; --county: #e8edf2;
        --bge: #6eafe3; --pepco: #b48bd4; --danger: #ef7781; --ok: #62c99a;
        --warning: #e1a65b; --accent: #7cb9ed; --project: #ffb45e;
        --shadow: 0 8px 26px rgba(0, 0, 0, .32);
      }
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 system-ui, -apple-system, Segoe UI, sans-serif; }
    main { max-width: 1480px; margin: auto; padding: 22px; }
    h1, h2, h3, p { margin: 0; }
    h1 { font-size: clamp(24px, 3vw, 38px); font-weight: 650; letter-spacing: -.02em; }
    h2 { font-size: 18px; font-weight: 650; }
    h3 { font-size: 15px; font-weight: 650; }
    .subtitle { color: var(--muted); max-width: 960px; margin-top: 6px; }
    .toolbar { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin: 18px 0 12px; }
    button, select { font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--border); border-radius: 8px; min-height: 40px; padding: 8px 12px; }
    button { cursor: pointer; }
    button[aria-pressed="true"] { color: #fff; background: var(--accent); border-color: var(--accent); }
    button:focus-visible, select:focus-visible { outline: 3px solid color-mix(in srgb, var(--accent) 45%, transparent); outline-offset: 2px; }
    .replicate { margin-left: auto; }
    .replicate-label { color: var(--muted); font-size: 13px; }
    .replicate-note { display: grid; grid-template-columns: minmax(170px, .8fr) minmax(220px, 1fr) minmax(280px, 2fr); gap: 12px; padding: 12px 14px; background: var(--panel); border: 1px solid var(--border); border-radius: 10px; margin-bottom: 14px; }
    .replicate-note strong { display: block; }
    .replicate-note span { color: var(--muted); }
    .layout { display: grid; grid-template-columns: minmax(0, 2.25fr) minmax(280px, .8fr); gap: 16px; align-items: stretch; }
    .map-wrap, .detail { background: var(--panel); border: 1px solid var(--border); border-radius: 12px; box-shadow: var(--shadow); }
    .map-wrap { position: relative; min-height: 650px; overflow: hidden; }
    #map { display: block; width: 100%; height: 650px; }
    .map-title { position: absolute; left: 14px; top: 14px; background: color-mix(in srgb, var(--panel) 92%, transparent); border: 1px solid var(--border); border-radius: 9px; padding: 9px 11px; max-width: 390px; }
    .map-title strong { display: block; }
    .map-title span { color: var(--muted); font-size: 13px; }
    .legend { position: absolute; left: 14px; bottom: 14px; display: flex; flex-wrap: wrap; gap: 8px 12px; max-width: calc(100% - 28px); background: color-mix(in srgb, var(--panel) 94%, transparent); border: 1px solid var(--border); border-radius: 9px; padding: 8px 10px; font-size: 12px; }
    .legend span { display: inline-flex; align-items: center; gap: 5px; }
    .swatch { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
    .swatch.line { width: 18px; height: 2px; border-radius: 0; }
    .detail { padding: 18px; display: flex; flex-direction: column; gap: 15px; }
    .status { display: inline-flex; width: fit-content; padding: 4px 8px; border-radius: 999px; font-size: 12px; font-weight: 650; background: color-mix(in srgb, var(--accent) 14%, transparent); color: var(--accent); }
    .metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
    .metric { padding: 10px; background: color-mix(in srgb, var(--text) 4%, var(--panel)); border-radius: 8px; }
    .metric strong { display: block; font-size: 19px; }
    .metric span { color: var(--muted); font-size: 12px; }
    .explain { color: var(--muted); }
    .decision { border-left: 4px solid var(--accent); padding-left: 11px; }
    .variant-control { display: flex; flex-direction: column; gap: 5px; }
    .variant-control label { color: var(--muted); font-size: 13px; }
    .source { color: var(--muted); font-size: 12px; margin-top: 14px; }
    .source a { color: var(--accent); }
    .county { fill: none; stroke: var(--county); stroke-width: .65; opacity: .52; vector-effect: non-scaling-stroke; }
    .state { fill: color-mix(in srgb, var(--panel) 96%, var(--accent)); stroke: var(--county); stroke-width: 1.8; vector-effect: non-scaling-stroke; }
    .zone { stroke-width: 2.4; vector-effect: non-scaling-stroke; }
    .branch { fill: none; stroke: var(--network); stroke-width: .55; opacity: .28; vector-effect: non-scaling-stroke; }
    .bus { fill: var(--network); opacity: .3; }
    .generator { stroke: var(--panel); stroke-width: 1; opacity: .8; }
    .project { fill: var(--project); stroke: var(--text); stroke-width: 1.4; vector-effect: non-scaling-stroke; }
    .project.accepted { fill: var(--ok); }
    .shortfall { fill: var(--danger); opacity: .16; stroke: var(--danger); stroke-width: 3; vector-effect: non-scaling-stroke; }
    .arrow { stroke: var(--danger); stroke-width: 3; fill: none; vector-effect: non-scaling-stroke; }
    .arrow.approved { stroke: var(--ok); }
    .map-label { fill: var(--text); paint-order: stroke; stroke: var(--panel); stroke-width: 4px; stroke-linejoin: round; font-size: 12px; font-weight: 650; }
    .zone-label { font-size: 15px; }
    .tooltip { position: fixed; z-index: 4; pointer-events: none; max-width: 300px; padding: 8px 10px; border-radius: 7px; background: var(--panel); border: 1px solid var(--border); box-shadow: var(--shadow); color: var(--text); font-size: 12px; opacity: 0; }
    .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
    @media (max-width: 920px) {
      .replicate { margin-left: 0; }
      .replicate-note { grid-template-columns: 1fr; }
      .layout { grid-template-columns: 1fr; }
      .map-wrap, #map { min-height: 540px; height: 540px; }
    }
    @media (max-width: 560px) {
      main { padding: 12px; }
      .toolbar button { flex: 1 1 140px; }
      .map-wrap, #map { min-height: 470px; height: 470px; }
      .map-title { right: 12px; max-width: none; }
      .metrics { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
<main>
  <header>
    <h1>Maryland adaptive-agent experiment</h1>
    <p class="subtitle">One geographic story, three engineering replicates: GTEP builds dispatchable capacity, realization places projects on PCM buses, PCM exposes a spatial shortfall, and a human-approved revision moves the planning eligibility to the affected zone.</p>
  </header>

  <div class="toolbar" aria-label="Map controls">
    <button class="step" data-step="0" aria-pressed="true">1 · Existing system</button>
    <button class="step" data-step="1" aria-pressed="false">2 · BGE plan</button>
    <button class="step" data-step="2" aria-pressed="false">3 · PCM diagnosis</button>
    <button class="step" data-step="3" aria-pressed="false">4 · Approved fix</button>
    <button class="step" data-step="4" aria-pressed="false">5 · PEPCO rerun</button>
    <button class="step" data-step="5" aria-pressed="false">6 · Final selection</button>
    <label class="replicate replicate-label">Engineering run
      <select id="replicate" aria-label="Engineering replicate">
        <option value="r01">r01</option>
        <option value="r02">r02</option>
        <option value="r03" selected>r03</option>
      </select>
    </label>
  </div>

  <section class="replicate-note" aria-live="polite">
    <div><span>Classification</span><strong id="rep-label"></strong></div>
    <div><span>Execution</span><strong id="rep-status"></strong><small id="rep-calls"></small></div>
    <div><span>What changed</span><strong id="rep-lesson"></strong></div>
  </section>

  <div class="layout">
    <section class="map-wrap" aria-labelledby="map-heading">
      <svg id="map" role="img" aria-labelledby="map-heading map-description"></svg>
      <p id="map-description" class="sr-only">Interactive Maryland map showing county and utility boundaries, the OSM-derived PCM transmission network, existing generation, new NGCC realization sites, the PEPCO shortfall, and the approved spatial correction.</p>
      <div class="map-title"><strong id="map-heading"></strong><span id="map-subtitle"></span></div>
      <div class="legend" aria-label="Map legend">
        <span><i class="swatch line" style="background:var(--county)"></i>County boundary</span>
        <span><i class="swatch line" style="background:var(--network)"></i>PCM corridor</span>
        <span><i class="swatch" style="background:var(--bge)"></i>BGE</span>
        <span><i class="swatch" style="background:var(--pepco)"></i>PEPCO</span>
        <span><i class="swatch" style="background:var(--project)"></i>New NGCC</span>
        <span><i class="swatch" style="background:var(--danger)"></i>Load shedding</span>
        <span><i class="swatch" style="background:var(--ok)"></i>Accepted site</span>
      </div>
    </section>

    <aside class="detail" aria-live="polite">
      <span class="status" id="step-status"></span>
      <div><h2 id="step-title"></h2><p class="explain" id="step-text"></p></div>
      <div class="metrics" id="metrics"></div>
      <div class="variant-control" id="variant-wrap">
        <label for="variant">Realization policy shown on map</label>
        <select id="variant">
          <option value="balanced_permitting">balanced_permitting</option>
          <option value="least_cost" selected>least_cost</option>
          <option value="environmental_caution">environmental_caution</option>
          <option value="grid_ready">grid_ready</option>
        </select>
      </div>
      <div class="decision"><h3 id="decision-title"></h3><p class="explain" id="decision-text"></p></div>
    </aside>
  </div>

  <p class="source">Geography: US Atlas/Census state and county geometry; HIFLD electric retail service territories; OSM-derived synthetic HOPE bus and corridor geometry © OpenStreetMap contributors, ODbL 1.0. Model evidence: <code>claude-md-adaptive-20261107-r03</code>. Utility polygons and straight-line PCM corridors are study visualization layers, not official PJM planning models or project recommendations.</p>
</main>
<div class="tooltip" id="tooltip" role="status"></div>

<script>
const DATA = __DATA__;
const variants = ["balanced_permitting", "least_cost", "environmental_caution", "grid_ready"];
const params = new URLSearchParams(location.search);
let currentStep = Math.max(0, Math.min(5, +(params.get("step") || 0)));
let currentVariant = variants.includes(params.get("variant")) ? params.get("variant") : "least_cost";

const steps = [
  {
    status: "Starting point", title: "Existing Maryland system", map: "Existing fleet and PCM network",
    subtitle: "County boundaries, utility territories, buses, corridors, and existing generators",
    text: "The planning problem starts from the existing Maryland fleet and an OSM-derived nodal PCM network. The benchmark raises load by 10%, reduces the firm external contribution by 20%, disables RPS and planning reserve requirements, and allows new NGCC only.",
    metrics: [["+10%", "PCM load"], ["10,820.7 MW", "Firm external contribution"], ["NGCC", "Eligible new technology"], ["0%", "Planning reserve margin"]],
    decision: ["Question", "Can the coarse zonal plan create a concrete nodal system that serves the detailed operational load?"]
  },
  {
    status: "Iteration 1 · GTEP", title: "Planning builds in BGE", map: "Iteration 1: zonal planning decision",
    subtitle: "Three equal NGCC projects realize the 1,674.3 MW BGE build",
    text: "GTEP solves optimally with no planning load shedding. It selects 1,674.3 MW of NGCC in BGE, then deterministic unitization creates three 558.1 MW projects. Choose a realization policy to see its three candidate PCM buses.",
    metrics: [["1,674.3 MW", "New NGCC"], ["3 × 558.1 MW", "Discrete projects"], ["BGE", "Planning build zone"], ["0 MWh", "GTEP shedding"]],
    decision: ["Do not accept yet", "A zonal optimum must still be downscaled and tested on the chronological nodal PCM network."]
  },
  {
    status: "Iteration 1 · PCM", title: "Operations expose a PEPCO shortfall", map: "Iteration 1: operational diagnosis",
    subtitle: "BGE construction is dispatched, but all four realizations shed load in PEPCO",
    text: "All four PCM solves are mathematically optimal and feasible, yet all fail the engineering gate. Their nearly identical PEPCO shortage shows that changing the BGE bus alone cannot repair the zonal mismatch.",
    metrics: [["0 of 4", "Accepted variants"], ["≈11,596 MWh", "Load shedding"], ["25 h", "Hours affected"], ["931.0 MW", "Peak shortfall"]],
    decision: ["Diagnosis", "SPATIAL_CAPACITY_MISMATCH: new capacity is in BGE while the operational shortage is in PEPCO."]
  },
  {
    status: "Human approval", title: "One controlled assumption changes", map: "Approved candidate-zone correction",
    subtitle: "Eligibility moves from the original statewide choice to PEPCO only",
    text: "The agent proposes candidate_zone_eligibility = [PEPCO]. Shen Wang approves it. Load, imports, VOLL, RPS, reserve margin, technology eligibility, storage settings, capacity quantity, and acceptance thresholds remain fixed.",
    metrics: [["1", "Revision request"], ["1", "Human approval"], ["PEPCO", "New eligible zone"], ["7", "Controls held fixed"]],
    decision: ["Causal test", "If the diagnosis is correct, the same 1,674.3 MW placed in PEPCO should produce at least one acceptable nodal realization."]
  },
  {
    status: "Iteration 2 · PCM", title: "The PEPCO bus still matters", map: "Iteration 2: PEPCO realization ensemble",
    subtitle: "The zonal correction works for one concrete nodal portfolio, not automatically for all",
    text: "GTEP keeps the same capacity and technology but moves the build zone to PEPCO. The four downscaling policies select different existing network buses. Only least_cost passes; the other three still shed load.",
    metrics: [["1 of 4", "Accepted variants"], ["1,674.3 MW", "Capacity unchanged"], ["PEPCO", "Corrected build zone"], ["0–11,275 MWh", "Variant shedding range"]],
    decision: ["Ownership shifts", "Because one local realization passes, another GTEP change would be inappropriate. Select an independently accepted physical realization."]
  },
  {
    status: "Terminal accepted", title: "least_cost is selected and frozen", map: "Final verified physical realization",
    subtitle: "Three PEPCO NGCC sites serve the tested chronology with zero load shedding",
    text: "The agent selects least_cost only after the authoritative ensemble lists it as accepted. The three 558.1 MW projects dispatch 69,238.6 MWh, PCM sheds no load, and the adaptive study closes as accepted.",
    metrics: [["least_cost", "Selected variant"], ["0 MWh", "Load shedding"], ["69,238.6 MWh", "New NGCC dispatch"], ["Model + agent", "Both passed"]],
    decision: ["Stop condition met", "The selected realization passes every hard gate, so the workflow records acceptance rather than continuing to alter planning assumptions."]
  }
];

const svg = d3.select("#map");
const tooltip = d3.select("#tooltip");
const root = svg.append("g");
const projection = d3.geoMercator();
const path = d3.geoPath(projection);

function color(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }
function featureCollection(features) { return {type: "FeatureCollection", features}; }
function zoneFeature(name) { return DATA.zones.find(feature => feature.properties.zone === name); }

function prepareProjection() {
  const bounds = svg.node().getBoundingClientRect();
  svg.attr("viewBox", `0 0 ${bounds.width} ${bounds.height}`);
  projection.fitExtent([[24, 28], [bounds.width - 24, bounds.height - 28]], DATA.state);
}

function centroid(name) { return path.centroid(zoneFeature(name)); }

function showTooltip(event, html) {
  tooltip.style("opacity", 1).html(html)
    .style("left", `${Math.min(event.clientX + 12, window.innerWidth - 320)}px`)
    .style("top", `${event.clientY + 12}px`);
}
function hideTooltip() { tooltip.style("opacity", 0); }

function drawBase() {
  root.selectAll("*").remove();
  const defs = root.append("defs");
  defs.append("marker").attr("id", "arrowhead").attr("viewBox", "0 -5 10 10")
    .attr("refX", 9).attr("refY", 0).attr("markerWidth", 7).attr("markerHeight", 7).attr("orient", "auto")
    .append("path").attr("d", "M0,-5L10,0L0,5").attr("fill", "context-stroke");

  root.append("path").datum(DATA.state).attr("class", "state").attr("d", path);
  root.append("g").selectAll("path").data(DATA.counties).join("path").attr("class", "county").attr("d", path);

  root.append("g").selectAll("path").data(DATA.zones).join("path")
    .attr("class", "zone")
    .attr("d", path)
    .attr("fill", d => d.properties.zone === "BGE" ? color("--bge") : color("--pepco"))
    .attr("fill-opacity", .10)
    .attr("stroke", d => d.properties.zone === "BGE" ? color("--bge") : color("--pepco"))
    .on("pointermove", (event, d) => showTooltip(event, `<strong>${d.properties.zone}</strong><br>${d.properties.utility}`))
    .on("pointerleave", hideTooltip);

  root.append("g").selectAll("path").data(DATA.branches).join("path")
    .attr("class", "branch")
    .attr("d", d => path({type: "LineString", coordinates: d.coordinates}));

  root.append("g").selectAll("circle").data(DATA.buses).join("circle")
    .attr("class", "bus").attr("r", 1.2)
    .attr("cx", d => projection([d.lon, d.lat])[0]).attr("cy", d => projection([d.lon, d.lat])[1]);

  const zoneLabels = ["BGE", "PEPCO"];
  root.append("g").selectAll("text").data(zoneLabels).join("text")
    .attr("class", "map-label zone-label")
    .attr("x", d => centroid(d)[0]).attr("y", d => centroid(d)[1])
    .attr("text-anchor", "middle").text(d => d);
}

function drawGenerators() {
  const palette = {Thermal: "#d95f02", Nuclear: "#7b3294", Solar: "#e6ab02", Wind: "#1b9e77", Hydro: "#3288bd", Storage: "#66a61e", Other: "#777"};
  root.append("g").selectAll("circle").data(DATA.generators).join("circle")
    .attr("class", "generator")
    .attr("cx", d => projection([d.lon, d.lat])[0]).attr("cy", d => projection([d.lon, d.lat])[1])
    .attr("r", d => Math.max(2.2, Math.min(9, 1.6 + Math.sqrt(d.mw) / 6)))
    .attr("fill", d => palette[d.group] || palette.Other)
    .on("pointermove", (event, d) => showTooltip(event, `<strong>${d.name}</strong><br>${d.group} · ${d.mw.toLocaleString()} MW · ${d.zone}`))
    .on("pointerleave", hideTooltip);
}

function drawProjects(iteration, acceptedOnly = false) {
  const source = iteration === 1 ? DATA.iteration1 : DATA.iteration2;
  let projects = source.allocations.filter(d => d.variant === currentVariant);
  if (acceptedOnly) projects = DATA.iteration2.allocations.filter(d => d.variant === "least_cost");
  const finding = source.findings[acceptedOnly ? "least_cost" : currentVariant];
  const symbol = d3.symbol().type(d3.symbolTriangle).size(150);
  root.append("g").selectAll("path").data(projects).join("path")
    .attr("class", `project${finding.accepted ? " accepted" : ""}`)
    .attr("d", symbol)
    .attr("transform", d => `translate(${projection([d.lon, d.lat]).join(",")})`)
    .on("pointermove", (event, d) => showTooltip(event, `<strong>${d.project}</strong><br>${d.mw.toLocaleString()} MW ${d.type}<br>${d.bus}<br>${d.review ? "Human review required" : "No review flag"}`))
    .on("pointerleave", hideTooltip);
}

function drawShortfall() {
  root.append("path").datum(zoneFeature("PEPCO")).attr("class", "shortfall").attr("d", path);
  const [x, y] = centroid("PEPCO");
  root.append("text").attr("class", "map-label").attr("x", x).attr("y", y + 24).attr("text-anchor", "middle").text("≈11,596 MWh shed");
}

function drawArrow(approved = false) {
  const [x1, y1] = centroid("BGE");
  const [x2, y2] = centroid("PEPCO");
  root.append("path").attr("class", `arrow${approved ? " approved" : ""}`)
    .attr("d", `M${x1},${y1} Q${(x1+x2)/2-30},${(y1+y2)/2-45} ${x2},${y2}`)
    .attr("marker-end", "url(#arrowhead)");
  root.append("text").attr("class", "map-label").attr("x", (x1+x2)/2-10).attr("y", (y1+y2)/2-48)
    .attr("text-anchor", "middle").text(approved ? "Approved: PEPCO eligibility" : "Mismatch");
}

function updateDetails() {
  const step = steps[currentStep];
  d3.select("#map-heading").text(step.map);
  d3.select("#map-subtitle").text(step.subtitle);
  d3.select("#step-status").text(step.status);
  d3.select("#step-title").text(step.title);
  d3.select("#step-text").text(step.text);
  const metrics = d3.select("#metrics").selectAll("div").data(step.metrics).join("div").attr("class", "metric");
  metrics.html(d => `<strong>${d[0]}</strong><span>${d[1]}</span>`);
  d3.select("#decision-title").text(step.decision[0]);
  d3.select("#decision-text").text(step.decision[1]);
  d3.select("#variant-wrap").style("display", [1,2,4].includes(currentStep) ? "flex" : "none");
}

function render() {
  prepareProjection();
  drawBase();
  if (currentStep === 0) drawGenerators();
  if (currentStep === 1) { drawGenerators(); drawProjects(1); }
  if (currentStep === 2) { drawProjects(1); drawShortfall(); drawArrow(false); }
  if (currentStep === 3) { drawShortfall(); drawArrow(true); }
  if (currentStep === 4) { drawProjects(2); if (!DATA.iteration2.findings[currentVariant].accepted) drawShortfall(); }
  if (currentStep === 5) drawProjects(2, true);
  updateDetails();
}

function updateReplicate() {
  const item = DATA.replicates[document.getElementById("replicate").value];
  d3.select("#rep-label").text(item.label);
  d3.select("#rep-status").text(item.status);
  d3.select("#rep-calls").text(item.calls);
  d3.select("#rep-lesson").text(item.lesson);
}

d3.selectAll("button.step").on("click", function() {
  currentStep = +this.dataset.step;
  d3.selectAll("button.step").attr("aria-pressed", "false");
  d3.select(this).attr("aria-pressed", "true");
  render();
});
d3.select("#variant").on("change", function() { currentVariant = this.value; render(); });
d3.select("#replicate").on("change", updateReplicate);
window.addEventListener("resize", render);
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", render);

const requestedReplicate = params.get("replicate");
if (DATA.replicates[requestedReplicate]) document.getElementById("replicate").value = requestedReplicate;
document.getElementById("variant").value = currentVariant;
d3.selectAll("button.step").attr("aria-pressed", function() { return +this.dataset.step === currentStep ? "true" : "false"; });
updateReplicate();
render();
</script>
</body>
</html>
'''


def main():
    data = json.dumps(build_data(), separators=(",", ":"), ensure_ascii=True)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(HTML.replace("__DATA__", data), encoding="utf-8")
    print(f"Wrote {OUTPUT} ({OUTPUT.stat().st_size / 1024:.1f} KiB)")


if __name__ == "__main__":
    main()
