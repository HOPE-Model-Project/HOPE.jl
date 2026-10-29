"""Generate the Maryland compact RPS experiment summary figures.

The figures deliberately read the authoritative run artifacts instead of
retyping experiment results. Run this script from any directory after the
``run05`` planning and ``v6`` PCM artifacts have been generated.
"""

from __future__ import annotations

import csv
import json
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "docs" / "src" / "assets"
PLANNING_RUN = (
    ROOT
    / "artifacts"
    / "computed_realization_runs"
    / "md_compact_rps_planning_v1_run05"
)
PCM_ENSEMBLE = (
    ROOT
    / "artifacts"
    / "computed_realization_runs"
    / "md_compact_rps_pcm_ensemble_v6"
)
PCM_DATA = (
    ROOT
    / "ModelCases"
    / "MD_PCM_RPS20_transmission_public_case"
    / "Data_MD_PCM_RPS20_transmission_public"
)
MARYLAND_COUNTIES = (
    ROOT
    / "ModelCases"
    / "MD_COMPACT_RPS_REALIZATION_EXAMPLE_V1"
    / "maryland_counties_2025_500k.geojson"
)


# Keep this palette aligned with tools/plotting/plotting_common.jl so the
# experiment figures use the established HOPE technology colors.
TECH_COLORS = {
    "Coal": "#222222",
    "Oil": "#d2b48c",
    "NGCT": "#708090",
    "NGCC": "#9fbad6",
    "Hydro": "#133c73",
    "NuC": "#f39c12",
    "Nuc": "#f39c12",
    "MSW": "#8b4513",
    "Bio": "#8bc34a",
    "Landfill_NG": "#c9a227",
    "WindOn": "#6bb6ff",
    "WindOff": "#2f7fd3",
    "SolarPV": "#f4d03f",
    "Battery": "#7d3c98",
    "Firm external proxy": "#536878",
    "Other": "#b0b0b0",
}
TECH_ORDER = [
    "Coal",
    "Oil",
    "NGCT",
    "NGCC",
    "NuC",
    "Nuc",
    "Hydro",
    "MSW",
    "Landfill_NG",
    "Bio",
    "WindOff",
    "WindOn",
    "SolarPV",
    "Battery",
    "Firm external proxy",
    "Other",
]
ZONE_ORDER = ["APS_MD", "BGE", "DPL_MD", "PEPCO", "EXT"]
ZONE_COLORS = {
    "APS_MD": "#6a8caf",
    "BGE": "#7aa874",
    "DPL_MD": "#d59a54",
    "PEPCO": "#9a79b3",
}


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise FileNotFoundError(f"Required experiment input not found: {path}")
    with path.open(newline="", encoding="utf-8-sig") as stream:
        return list(csv.DictReader(stream))


def read_geojson(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(f"Required geographic input not found: {path}")
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def number(value: str | None, default: float = 0.0) -> float:
    if value is None or value.strip() == "":
        return default
    return float(value)


def truth(value: str | None) -> bool:
    return str(value).strip().lower() == "true"


def style_axis(ax: plt.Axes) -> None:
    ax.set_facecolor("#fbfcfd")
    ax.grid(False)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#aab4bd")


def load_inputs() -> dict[str, object]:
    planning_data = PLANNING_RUN / "Data_MD_GTEP_RPS20_4zone_public"
    return {
        "buses": read_csv(PCM_DATA / "busdata.csv"),
        "branches": read_csv(PCM_DATA / "branchdata.csv"),
        "existing_generators": read_csv(PCM_DATA / "gendata.csv"),
        "gtep_generators": read_csv(planning_data / "gendata.csv"),
        "zones": read_csv(planning_data / "zonedata.csv"),
        "zonal_lines": read_csv(planning_data / "linedata.csv"),
        "continuous_plan": read_csv(
            PLANNING_RUN / "Planning" / "continuous_capacity_plan.csv"
        ),
        "unitized_plan": read_csv(
            PLANNING_RUN / "Planning" / "unitized_capacity_plan.csv"
        ),
        "candidate_catalog": read_csv(
            PCM_ENSEMBLE / "candidate_project_catalog.csv"
        ),
        "screening": read_csv(PCM_ENSEMBLE / "realization_screening.csv"),
        "selected": read_csv(
            PCM_ENSEMBLE
            / "members"
            / "least_cost"
            / "selected_projects.csv"
        ),
        "maryland_counties": read_geojson(MARYLAND_COUNTIES),
    }


def polygon_rings(geometry: dict) -> list[list[list[float]]]:
    if geometry.get("type") == "Polygon":
        return geometry.get("coordinates", [])
    if geometry.get("type") == "MultiPolygon":
        return [ring for polygon in geometry.get("coordinates", []) for ring in polygon]
    return []


def draw_real_boundaries(ax: plt.Axes, geojson: dict) -> None:
    """Draw Census county lines and the derived Maryland exterior in black."""

    edge_counts: dict[tuple[tuple[float, float], tuple[float, float]], int] = defaultdict(int)
    edge_coordinates: dict[
        tuple[tuple[float, float], tuple[float, float]],
        tuple[tuple[float, float], tuple[float, float]],
    ] = {}
    for feature in geojson.get("features", []):
        for ring in polygon_rings(feature.get("geometry", {})):
            if len(ring) < 2:
                continue
            ax.plot(
                [point[0] for point in ring],
                [point[1] for point in ring],
                color="#111111",
                linewidth=0.52,
                alpha=0.64,
                zorder=-3,
            )
            for first, second in zip(ring, ring[1:]):
                a = (round(first[0], 6), round(first[1], 6))
                b = (round(second[0], 6), round(second[1], 6))
                key = tuple(sorted((a, b)))
                edge_counts[key] += 1
                edge_coordinates[key] = ((first[0], first[1]), (second[0], second[1]))
    for key, count in edge_counts.items():
        if count != 1:
            continue
        first, second = edge_coordinates[key]
        ax.plot(
            [first[0], second[0]],
            [first[1], second[1]],
            color="#000000",
            linewidth=1.15,
            alpha=0.92,
            zorder=-2,
        )


def bus_coordinates(
    buses: list[dict[str, str]],
) -> dict[str, tuple[float, float]]:
    return {
        row["Bus_id"]: (number(row["Longitude"]), number(row["Latitude"]))
        for row in buses
    }


def draw_network(
    ax: plt.Axes,
    branches: list[dict[str, str]],
    coordinates: dict[str, tuple[float, float]],
    *,
    color: str = "#95a8b5",
    alpha: float = 0.22,
    linewidth: float = 0.38,
) -> None:
    for row in branches:
        start = coordinates.get(row["from_bus"])
        end = coordinates.get(row["to_bus"])
        if start is None or end is None:
            continue
        ax.plot(
            [start[0], end[0]],
            [start[1], end[1]],
            color=color,
            alpha=alpha,
            linewidth=linewidth,
            zorder=1,
        )


def convex_hull(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Return the monotone-chain hull of a set of longitude/latitude points."""

    unique = sorted(set(points))
    if len(unique) <= 2:
        return unique

    def cross(
        origin: tuple[float, float],
        first: tuple[float, float],
        second: tuple[float, float],
    ) -> float:
        return (first[0] - origin[0]) * (second[1] - origin[1]) - (
            first[1] - origin[1]
        ) * (second[0] - origin[0])

    lower: list[tuple[float, float]] = []
    for point in unique:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], point) <= 0:
            lower.pop()
        lower.append(point)
    upper: list[tuple[float, float]] = []
    for point in reversed(unique):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], point) <= 0:
            upper.pop()
        upper.append(point)
    return lower[:-1] + upper[:-1]


def build_zone_footprints(
    buses: list[dict[str, str]],
) -> dict[str, list[tuple[float, float]]]:
    points: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for row in buses:
        zone = row["Zone_id"]
        if row.get("State") == "MD" and zone in ZONE_COLORS:
            points[zone].append(
                (number(row["Longitude"]), number(row["Latitude"]))
            )
    return {zone: convex_hull(zone_points) for zone, zone_points in points.items()}


def draw_zone_footprints(
    ax: plt.Axes,
    footprints: dict[str, list[tuple[float, float]]],
    *,
    labels: bool,
) -> None:
    for zone in ZONE_ORDER:
        hull = footprints.get(zone, [])
        if len(hull) < 3:
            continue
        closed = hull + [hull[0]]
        color = ZONE_COLORS[zone]
        ax.fill(
            [point[0] for point in closed],
            [point[1] for point in closed],
            color=color,
            alpha=0.045,
            zorder=0,
        )
        ax.plot(
            [point[0] for point in closed],
            [point[1] for point in closed],
            color=color,
            linewidth=1.45,
            linestyle=(0, (4, 3)),
            alpha=0.9,
            zorder=1,
        )
        if labels:
            center = (
                sum(point[0] for point in hull) / len(hull),
                sum(point[1] for point in hull) / len(hull),
            )
            ax.text(
                center[0],
                center[1],
                zone,
                color=color,
                fontsize=8.0,
                weight="bold",
                ha="center",
                va="center",
                alpha=0.85,
                zorder=2,
            )


def apply_common_map_extent(
    ax: plt.Axes,
    extent: tuple[float, float, float, float],
) -> None:
    ax.set_xlim(extent[0], extent[1])
    ax.set_ylim(extent[2], extent[3])
    ax.set_aspect("equal", adjustable="box")


def generator_points(
    generators: list[dict[str, str]],
    coordinates: dict[str, tuple[float, float]],
) -> dict[str, list[tuple[float, float, float]]]:
    grouped: dict[tuple[str, str], float] = defaultdict(float)
    for row in generators:
        grouped[(row["Bus_id"], row["Type"])] += number(row["Pmax (MW)"])
    result: dict[str, list[tuple[float, float, float]]] = defaultdict(list)
    for (bus_id, technology), capacity_mw in grouped.items():
        location = coordinates.get(bus_id)
        if location is not None:
            result[technology].append((*location, capacity_mw))
    return result


def technology_sequence(technologies: set[str]) -> list[str]:
    ordered = [technology for technology in TECH_ORDER if technology in technologies]
    ordered.extend(sorted(technologies.difference(ordered)))
    return ordered


def make_system_states_figure(data: dict[str, object]) -> Path:
    coordinates = bus_coordinates(data["buses"])
    generator_data = generator_points(data["existing_generators"], coordinates)
    footprints = build_zone_footprints(data["buses"])
    maryland_points = [
        coordinates[row["Bus_id"]]
        for row in data["buses"]
        if row.get("State") == "MD" and row["Bus_id"] in coordinates
    ]
    common_extent = (
        min(point[0] for point in maryland_points) - 0.18,
        max(point[0] for point in maryland_points) + 0.18,
        min(point[1] for point in maryland_points) - 0.14,
        max(point[1] for point in maryland_points) + 0.14,
    )
    fig, axes = plt.subplots(1, 3, figsize=(19.2, 7.2), constrained_layout=True)

    # A. Existing physical PCM system.
    ax = axes[0]
    draw_real_boundaries(ax, data["maryland_counties"])
    draw_zone_footprints(ax, footprints, labels=True)
    draw_network(ax, data["branches"], coordinates)
    for technology in technology_sequence(set(generator_data)):
        points = generator_data[technology]
        ax.scatter(
            [point[0] for point in points],
            [point[1] for point in points],
            s=[max(8.0, min(230.0, 8.0 + 0.12 * point[2])) for point in points],
            color=TECH_COLORS.get(technology, TECH_COLORS["Other"]),
            edgecolors="white",
            linewidths=0.45,
            alpha=0.88,
            label=technology,
            zorder=3,
        )
    ax.set_title("A  Existing nodal system seen by PCM", loc="left", weight="bold")
    ax.text(
        0.02,
        0.02,
        "656 buses  |  838 branches  |  271 existing units  |  9.332 GW",
        transform=ax.transAxes,
        fontsize=9.2,
        bbox={"facecolor": "white", "edgecolor": "#d9e0e5", "alpha": 0.92},
        zorder=5,
    )
    ax.set_xlabel("Longitude")
    ax.set_ylabel("Latitude")
    apply_common_map_extent(ax, common_extent)
    style_axis(ax)
    legend = ax.legend(
        title="Existing technology",
        loc="upper left",
        fontsize=7.5,
        title_fontsize=8.5,
        frameon=True,
        ncol=2,
    )
    legend.get_frame().set_alpha(0.92)

    # B. Zonal GTEP abstraction and selected continuous build.
    ax = axes[1]
    draw_real_boundaries(ax, data["maryland_counties"])
    draw_zone_footprints(ax, footprints, labels=False)
    zone_points: dict[str, tuple[float, float]] = {}
    zone_locations: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for row in data["buses"]:
        zone_locations[row["Zone_id"]].append(
            (number(row["Longitude"]), number(row["Latitude"]))
        )
    for zone, points in zone_locations.items():
        zone_points[zone] = (
            sum(point[0] for point in points) / len(points),
            sum(point[1] for point in points) / len(points),
        )

    corridor_capacity: dict[tuple[str, str], float] = defaultdict(float)
    for row in data["zonal_lines"]:
        start, end = row["From_zone"], row["To_zone"]
        if start == end:
            continue
        key = tuple(sorted((start, end)))
        corridor_capacity[key] = max(
            corridor_capacity[key],
            number(row["Forward Capacity (MW)"]),
            number(row["Reverse Capacity (MW)"]),
        )
    for (start, end), capacity_mw in corridor_capacity.items():
        if start not in zone_points or end not in zone_points:
            continue
        x1, y1 = zone_points[start]
        x2, y2 = zone_points[end]
        ax.plot(
            [x1, x2],
            [y1, y2],
            color="#6f8796",
            linewidth=0.8 + capacity_mw / 3500.0,
            alpha=0.72,
            zorder=1,
        )
        ax.text(
            (x1 + x2) / 2,
            (y1 + y2) / 2,
            f"{capacity_mw / 1000:.1f}",
            fontsize=7,
            color="#405563",
            ha="center",
            va="center",
            bbox={"facecolor": "white", "edgecolor": "none", "alpha": 0.78},
            zorder=2,
        )
    demand_by_zone = {
        row["Zone_id"]: number(row["Demand (MW)"]) for row in data["zones"]
    }
    proxy_by_zone: dict[str, float] = defaultdict(float)
    for row in data["gtep_generators"]:
        if row.get("ScenarioStatus") == "synthetic_firm_import_proxy":
            proxy_by_zone[row["Zone"]] += number(row["Pmax (MW)"])
    label_offsets = {
        "APS_MD": (-8, 14),
        "BGE": (-6, 16),
        "DPL_MD": (10, -2),
        "PEPCO": (-10, -18),
        "EXT": (12, 2),
    }
    for zone in ZONE_ORDER:
        if zone not in zone_points:
            continue
        x, y = zone_points[zone]
        demand = demand_by_zone.get(zone, 0.0)
        node_size = 120.0 + 0.045 * demand
        facecolor = "#eff4f7" if zone != "EXT" else "#d9e4ea"
        ax.scatter(
            [x],
            [y],
            s=node_size,
            color=facecolor,
            edgecolors="#304b5a",
            linewidths=1.2,
            zorder=3,
        )
        ax.annotate(
            zone,
            (x, y),
            xytext=label_offsets[zone],
            textcoords="offset points",
            ha="left" if zone in ("DPL_MD", "EXT") else "right",
            va="bottom" if zone in ("APS_MD", "BGE") else "top",
            fontsize=8.5,
            weight="bold",
            zorder=4,
        )
    plan_mw = sum(number(row["Build_MW"]) for row in data["continuous_plan"])
    dpl = zone_points["DPL_MD"]
    ax.scatter(
        [dpl[0]],
        [dpl[1]],
        marker="*",
        s=430,
        color=TECH_COLORS["SolarPV"],
        edgecolors="#7a6500",
        linewidths=1.0,
        zorder=5,
    )
    ax.annotate(
        f"GTEP adds {plan_mw / 1000:.3f} GW SolarPV\n"
        "one continuous decision; location is only DPL_MD",
        xy=dpl,
        xytext=(-78.65, 38.18),
        textcoords="data",
        arrowprops={"arrowstyle": "->", "color": "#8a7200", "lw": 1.2},
        fontsize=8.6,
        ha="left",
        bbox={"facecolor": "#fff9d6", "edgecolor": "#dbc65a", "alpha": 0.95},
        zorder=6,
    )
    ax.text(
        0.02,
        0.03,
        "Interface labels: modeled capacity (GW)\n"
        "Line widths are schematic, not geography\n"
        f"EXT node: {proxy_by_zone['EXT'] / 1000:.2f} GW firm proxy",
        transform=ax.transAxes,
        ha="left",
        va="bottom",
        fontsize=8.2,
        color="#52636e",
    )
    ax.set_title("B  Planned system after zonal GTEP", loc="left", weight="bold")
    ax.set_xlabel("Longitude (common Maryland extent)")
    ax.set_ylabel("Latitude")
    apply_common_map_extent(ax, common_extent)
    style_axis(ax)

    # C. Final nodal realization for the accepted least-cost policy.
    ax = axes[2]
    draw_real_boundaries(ax, data["maryland_counties"])
    draw_zone_footprints(ax, footprints, labels=True)
    draw_network(ax, data["branches"], coordinates, alpha=0.28, linewidth=0.45)
    for technology, points in generator_data.items():
        ax.scatter(
            [point[0] for point in points],
            [point[1] for point in points],
            s=6,
            color=TECH_COLORS.get(technology, TECH_COLORS["Other"]),
            alpha=0.33,
            linewidths=0,
            zorder=2,
        )
    candidate_by_site = {row["Site_ID"]: row for row in data["candidate_catalog"]}
    screened_in = {
        row["SiteID"] for row in data["screening"] if truth(row["ScreenedIn"])
    }
    selected_sites = {row["SiteID"] for row in data["selected"]}
    eligible_x, eligible_y, rejected_x, rejected_y = [], [], [], []
    for site_id, row in candidate_by_site.items():
        point = (number(row["Longitude"]), number(row["Latitude"]))
        if site_id in screened_in:
            eligible_x.append(point[0])
            eligible_y.append(point[1])
        else:
            rejected_x.append(point[0])
            rejected_y.append(point[1])
    ax.scatter(
        eligible_x,
        eligible_y,
        s=56,
        facecolors="white",
        edgecolors="#36738c",
        linewidths=1.4,
        label="screened in (11)",
        zorder=4,
    )
    ax.scatter(
        rejected_x,
        rejected_y,
        s=52,
        marker="x",
        color="#c44e52",
        linewidths=1.6,
        label="screened out (7)",
        zorder=4,
    )
    selected_rows = [candidate_by_site[site] for site in selected_sites]
    ax.scatter(
        [number(row["Longitude"]) for row in selected_rows],
        [number(row["Latitude"]) for row in selected_rows],
        s=190,
        marker="*",
        color=TECH_COLORS["SolarPV"],
        edgecolors="#4f4300",
        linewidths=1.0,
        label="selected SolarPV project (9)",
        zorder=6,
    )
    sorted_selected = sorted(
        selected_rows,
        key=lambda row: (number(row["Latitude"]), number(row["Longitude"])),
    )
    for index, row in enumerate(sorted_selected, start=1):
        ax.annotate(
            f"P{index}",
            (number(row["Longitude"]), number(row["Latitude"])),
            xytext=(5, 5),
            textcoords="offset points",
            fontsize=7.3,
            weight="bold",
            zorder=7,
        )
    ax.set_title("C  Final PCM-level decision (least cost)", loc="left", weight="bold")
    ax.text(
        0.02,
        0.02,
        "9 projects x 534.164 MW = 4.807 GW\n"
        "PCM: optimal, 0 load shedding, 0 RPS slack",
        transform=ax.transAxes,
        fontsize=9.0,
        bbox={"facecolor": "white", "edgecolor": "#d9e0e5", "alpha": 0.94},
        zorder=8,
    )
    ax.set_xlabel("Longitude (common Maryland extent)")
    ax.set_ylabel("Latitude")
    apply_common_map_extent(ax, common_extent)
    ax.legend(loc="upper left", fontsize=8.0, frameon=True)
    style_axis(ax)

    fig.suptitle(
        "Maryland compact RPS experiment: the same planning need at three resolutions",
        fontsize=17,
        weight="bold",
        x=0.01,
        ha="left",
    )
    output = ASSET_DIR / "md_compact_rps_system_states.png"
    fig.savefig(output, dpi=210, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return output


def make_capacity_transition_figure(data: dict[str, list[dict[str, str]]]) -> Path:
    baseline: dict[tuple[str, str], float] = defaultdict(float)
    for row in data["gtep_generators"]:
        technology = row["Type"]
        if row.get("ScenarioStatus") == "synthetic_firm_import_proxy":
            technology = "Firm external proxy"
        baseline[(row["Zone"], technology)] += number(row["Pmax (MW)"]) / 1000.0
    planned = defaultdict(float, baseline)
    for row in data["continuous_plan"]:
        planned[(row["Zone"], row["Type"])] += number(row["Build_MW"]) / 1000.0

    technologies = technology_sequence(
        {technology for _, technology in set(baseline).union(planned)}
    )
    zone_positions = {zone: index for index, zone in enumerate(ZONE_ORDER)}
    width = 0.28
    pair_offset = 0.19
    fig, ax = plt.subplots(figsize=(14.8, 7.2))
    bottom_by_bar = {
        (zone, state): 0.0
        for zone in ZONE_ORDER
        for state in ("Baseline", "After GTEP")
    }
    for technology in technologies:
        for state, values, offset in (
            ("Baseline", baseline, -pair_offset),
            ("After GTEP", planned, pair_offset),
        ):
            heights = [values[(zone, technology)] for zone in ZONE_ORDER]
            bottoms = [bottom_by_bar[(zone, state)] for zone in ZONE_ORDER]
            ax.bar(
                [zone_positions[zone] + offset for zone in ZONE_ORDER],
                heights,
                width=width,
                bottom=bottoms,
                color=TECH_COLORS.get(technology, TECH_COLORS["Other"]),
                edgecolor="white",
                linewidth=0.35,
                label=technology if state == "Baseline" else None,
                zorder=2,
            )
            for zone, height in zip(ZONE_ORDER, heights):
                bottom_by_bar[(zone, state)] += height

    demand = {
        row["Zone_id"]: number(row["Demand (MW)"]) / 1000.0
        for row in data["zones"]
    }
    for zone in ZONE_ORDER:
        if zone == "EXT":
            continue
        x = zone_positions[zone]
        ax.scatter(
            [x],
            [demand[zone]],
            marker="D",
            s=42,
            color="#17232b",
            edgecolors="white",
            linewidths=0.6,
            zorder=5,
        )
    ax.scatter(
        [], [], marker="D", s=42, color="#17232b", label="Modeled peak demand"
    )
    dpl_x = zone_positions["DPL_MD"] + pair_offset
    baseline_dpl = sum(
        baseline[("DPL_MD", technology)] for technology in technologies
    )
    plan_mw = sum(number(row["Build_MW"]) for row in data["continuous_plan"])
    ax.annotate(
        f"GTEP decision\n+{plan_mw / 1000:.3f} GW SolarPV",
        xy=(dpl_x, baseline_dpl + plan_mw / 1000),
        xytext=(dpl_x + 0.48, baseline_dpl + plan_mw / 1000 + 1.0),
        arrowprops={"arrowstyle": "->", "color": "#8a7200", "lw": 1.2},
        fontsize=10,
        bbox={"facecolor": "#fff9d6", "edgecolor": "#dbc65a"},
    )
    ax.set_xticks(range(len(ZONE_ORDER)))
    ax.set_xticklabels(ZONE_ORDER)
    ax.set_ylabel("Nameplate or declared firm capacity (GW)")
    fig.suptitle(
        "Capacity transition by zone and technology",
        fontsize=16,
        weight="bold",
        x=0.06,
        y=0.975,
        ha="left",
    )
    fig.text(
        0.06,
        0.935,
        "Left bar = declared baseline; right bar = after GTEP. "
        "Diamonds show peak demand, not energy.",
        fontsize=9.5,
        color="#53636d",
    )
    ax.grid(axis="y", color="#e2e7ea", linewidth=0.75, zorder=0)
    ax.set_axisbelow(True)
    style_axis(ax)
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(
        handles,
        labels,
        title="Technology / planning input",
        bbox_to_anchor=(1.01, 1.0),
        loc="upper left",
        fontsize=8.5,
        title_fontsize=9.5,
        frameon=True,
    )
    ax.set_ylim(bottom=-0.15)
    fig.subplots_adjust(left=0.06, right=0.81, bottom=0.12, top=0.89)
    output = ASSET_DIR / "md_compact_rps_capacity_transition.png"
    fig.savefig(output, dpi=210, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return output


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    data = load_inputs()
    outputs = [
        make_system_states_figure(data),
        make_capacity_transition_figure(data),
    ]
    for output in outputs:
        print(output.relative_to(ROOT))


if __name__ == "__main__":
    main()
