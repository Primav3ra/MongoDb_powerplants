# Global Power Plants in MongoDB

Loads the solar, nuclear and hydro plants from the WRI Global Power Plant Database into MongoDB using R, then reads them back to build an interactive world map and three charts.

## What it does

1. Reads the full dataset (34,936 plants).
2. Keeps solar, nuclear and hydro plants that have a location and a capacity: **18,016 plants in 147 countries**.
3. Inserts them into MongoDB (`energy_db.power_plants`) and indexes `fuel_type`.
4. Reads the data back from MongoDB and saves the outputs to `output/`.

| Fuel | Plants | Installed capacity |
|---|---:|---:|
| Solar | 10,665 | 188.3 GW |
| Nuclear | 195 | 407.9 GW |
| Hydro | 7,156 | 1,053.2 GW |

Solar has the most plants but the least capacity. Just 195 nuclear plants hold more than twice solar's total.

## Outputs

| File | What it shows |
|---|---|
| `output/power_plants_map.html` | Interactive map. Circles are sized by capacity, colored by fuel, and can be toggled per fuel. Click a plant for its details. |
| `output/capacity_by_fuel.png` | Installed capacity by fuel type |
| `output/fuel_mix.png` | Share of plants by fuel type |
| `output/capacity_vs_generation.png` | Capacity against 2013 generation, log scales, for the 2,062 plants that report it |

## Power generation analysis

`power_generation_analysis.R` looks at how much electricity the plants actually produce. For each plant it takes the most recent reported year of generation (2013–2019; the dataset's modelled estimates are left out) and computes its **capacity factor**: actual output divided by what the plant would produce running at full capacity all year. The data goes into a second MongoDB collection, `energy_db.plant_generation`, and the per-fuel totals come from a MongoDB aggregation pipeline.

| Fuel | Plants with reported generation | Correlation, capacity vs generation (log Pearson r) | Median capacity factor |
|---|---:|---:|---:|
| Solar | 3,228 | 0.85 | 19% |
| Nuclear | 112 | 0.90 | 84% |
| Hydro | 2,004 | 0.89 | 41% |

Generation rises closely with capacity for every fuel. What differs is how hard each type of plant runs: a nuclear plant produces about 4 times as much per MW as a solar farm.

| File | What it shows |
|---|---|
| `output/generation_vs_capacity_by_fuel.png` | Generation against capacity, one panel per fuel, with reference lines for 10%, 25% and 90% capacity factor |
| `output/capacity_factor_by_fuel.png` | Distribution of capacity factor by fuel |
| `output/top_generators.png` | The 15 plants with the highest annual generation |
| `output/generation_correlations.csv` | The correlation table above |

Open the map HTML in a browser. It loads its JavaScript from the `power_plants_map_files/` folder next to it, so keep the two together.

## Run it

Requirements: R 4.4+, a running MongoDB server, and these packages:

```r
install.packages(c("readr", "dplyr", "mongolite", "leaflet", "htmlwidgets", "ggplot2", "scales", "tidyr"))
```

From this folder:

```bash
Rscript power_plants_mongodb.R          # MongoDB load, map, capacity charts
Rscript power_generation_analysis.R     # generation, capacity factor, correlations
```

Or open the script in RStudio, set the working directory to this folder, and source it. The map and charts also open in the viewer.

MongoDB defaults to `mongodb://localhost:27017`. To use another server, set `MONGO_URL` first, for example `MONGO_URL="mongodb+srv://user:pass@cluster/..."`. Each run drops and reloads the collection.

## Project layout

```
power_plants_mongodb.R       read, filter, load to MongoDB, map, capacity charts
power_generation_analysis.R  generation and capacity factor analysis, correlation charts
data/                    WRI Global Power Plant Database v1.3.0 (CSV, docs, licence)
output/                  generated map and charts
```

## Data

Global Power Plant Database v1.3.0, World Resources Institute (2021), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). See `data/README.txt`. Generation figures for 2013 are reported for only part of the plants, so they appear in the map popups and the scatter plot but don't drive circle size.
