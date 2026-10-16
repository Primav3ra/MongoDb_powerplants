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

Open the map HTML in a browser. It loads its JavaScript from the `power_plants_map_files/` folder next to it, so keep the two together.

## Run it

Requirements: R 4.4+, a running MongoDB server, and these packages:

```r
install.packages(c("readr", "dplyr", "mongolite", "leaflet", "htmlwidgets", "ggplot2", "scales"))
```

From this folder:

```bash
Rscript power_plants_mongodb.R
```

Or open the script in RStudio, set the working directory to this folder, and source it. The map and charts also open in the viewer.

MongoDB defaults to `mongodb://localhost:27017`. To use another server, set `MONGO_URL` first, for example `MONGO_URL="mongodb+srv://user:pass@cluster/..."`. Each run drops and reloads the collection.

## Project layout

```
power_plants_mongodb.R   the whole pipeline: read, filter, load to MongoDB, map, charts
data/                    WRI Global Power Plant Database v1.3.0 (CSV, docs, licence)
output/                  generated map and charts
```

## Data

Global Power Plant Database v1.3.0, World Resources Institute (2021), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). See `data/README.txt`. Generation figures for 2013 are reported for only part of the plants, so they appear in the map popups and the scatter plot but don't drive circle size.
