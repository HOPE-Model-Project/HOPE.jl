# HOPE Model Constants and Shared Configuration

# Guard against redefinition
if !@isdefined(COLOR_MAP)

    # Color mappings for plotting
    const COLOR_MAP = Dict(
        "Coal" => "Black",
        "Oil" => "Bisque",
        "NGCT" => "LightSlateGray",
        "NGCT_CCS" => "LightSlateGray",
        "Hydro" => "MidnightBlue",
        "Hydro_pump" => "LightPurple",
        "Hydro_pump_c" => "LightPurple",
        "Hydro_pump_dc" => "LightPurple",
        "Hydro_pump_dis" => "LightPurple",
        "Nuc" => "Orange",
        "MSW" => "Saddlebrown",
        "Bio" => "LightGreen",
        "Landfill_NG" => "Gold",
        "NGCC" => "LightSteelBlue",
        "NGCC_CCS" => "LightSteelBlue",
        "NG" => "LightSteelBlue",
        "WindOn" => "LightSkyBlue",
        "WindOff" => "Blue",
        "SolarPV" => "Yellow",
        "Battery" => "Purple",
        "Battery_dc" => "Purple",
        "Battery_c" => "Purple",
        "Battery_dis" => "Purple",
        "Other" => "Pink",
    )

    # Technology acronym mappings
    const TECH_ACRONYM_MAP = Dict(
        "Batteries" => "Battery",
        "Biomass" => "Bio",
        "HPS" => "Hydro_pump",
        "BES" => "Battery",
        "MSW" => "Bio",
        "Landfill_NG" => "Bio",
        "NG" => "NGCC",
        "NuC" => "Nuc",
    )

    # Technology ordering for plots
    const ORDERED_TECH_POWER = [
        "Nuc",
        "Coal",
        "NGCC_CCS",
        "NGCT_CCS",
        "Hydro",
        "Bio",
        "WindOn",
        "WindOff",
        "SolarPV",
        "Other",
    ]
    const ORDERED_TECH_CAPACITY = [
        "Nuc",
        "Coal",
        "NGCC",
        "NGCC_CCS",
        "NGCT",
        "NGCT_CCS",
        "Hydro",
        "Bio",
        "WindOff",
        "WindOn",
        "SolarPV",
        "Battery",
    ]
    const ORDERED_ES_TECH = ["Hydro_pump", "Battery"]

    # Model configuration constants
    const VALID_MODEL_MODES = ["GTEP", "PCM", "DART"]
    const HOURS_PER_YEAR = 8760

    # File patterns
    const REQUIRED_FILES = Dict(
        "GTEP" => ["GTEP_input_total.xlsx", "HOPE_model_settings.yml"],
        "PCM" => ["PCM_input_total.xlsx", "HOPE_model_settings.yml"],
        "DART" => ["manifest.yml", "stable_ids.csv", "HOPE_model_settings.yml"],
    )

end # Guard against redefinition
