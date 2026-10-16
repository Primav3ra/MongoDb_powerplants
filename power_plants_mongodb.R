# Global Power Plants: load solar, nuclear and hydro plants into MongoDB,
# then map and chart them.
#
# Run from the project folder:  Rscript power_plants_mongodb.R
# Needs a MongoDB server; set MONGO_URL to use one other than localhost.

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(mongolite)
  library(leaflet)
  library(htmlwidgets)
  library(ggplot2)
})

csv_path   <- "data/global_power_plant_database.csv"
out_dir    <- "output"
mongo_url  <- Sys.getenv("MONGO_URL", "mongodb://localhost:27017")
fuel_types <- c("Solar", "Nuclear", "Hydro")
fuel_colors <- c(Solar = "#E8A317", Nuclear = "#C0392B", Hydro = "#2E86C1")

if (!file.exists(csv_path)) {
  stop("Dataset not found at ", csv_path, ". Run this script from the project folder.")
}
dir.create(out_dir, showWarnings = FALSE)

# Step 1: Read the dataset
power_plants <- read_csv(csv_path, show_col_types = FALSE, guess_max = 40000)

# Step 2: Keep the relevant plant types and columns
filtered_plants <- power_plants %>%
  filter(primary_fuel %in% fuel_types) %>%
  select(name, country_long, latitude, longitude, capacity_mw,
         primary_fuel, commissioning_year, owner, source, url, generation_gwh_2013)

# Step 3: Drop rows without a location or capacity, and rename columns
filtered_plants <- filtered_plants %>%
  filter(!is.na(latitude) & !is.na(longitude) & !is.na(capacity_mw)) %>%
  rename(
    country = country_long,
    fuel_type = primary_fuel,
    annual_generation_gwh = generation_gwh_2013
  )

cat("Read", nrow(power_plants), "plants; kept", nrow(filtered_plants),
    "solar, nuclear and hydro plants in", n_distinct(filtered_plants$country), "countries\n")

# Step 4: Insert into MongoDB. Inserting the data frame directly keeps
# numbers as numbers, so no conversion is needed after reading back.
plants_collection <- mongo(collection = "power_plants", db = "energy_db", url = mongo_url)
plants_collection$drop()  # Clear old data
invisible(plants_collection$insert(filtered_plants))
invisible(plants_collection$index(add = '{"fuel_type": 1}'))
cat("MongoDB energy_db.power_plants now holds", plants_collection$count(), "documents\n")

# Retrieve data from MongoDB
plants_data <- plants_collection$find(fields = '{"_id": 0}')
plants_data$fuel_type <- factor(plants_data$fuel_type, levels = fuel_types)

# Summary by fuel type, also used by the charts below
fuel_summary <- plants_data %>%
  group_by(fuel_type) %>%
  summarise(plants = n(),
            capacity_gw = round(sum(capacity_mw) / 1000, 1),
            .groups = "drop") %>%
  mutate(percentage = round(100 * plants / sum(plants), 1),
         label = paste0(fuel_type, " (", percentage, "%)"))
print(fuel_summary)

# The interactive map. Circle size follows capacity, which every plant has;
# 2013 generation is missing for most plants, so it is shown in the popup only.
fuel_pal <- colorFactor(unname(fuel_colors), levels = names(fuel_colors))

fmt_value <- function(x, unit) {
  ifelse(is.na(x), "n/a", paste(format(round(x, 1), big.mark = ","), unit))
}

plants_data <- plants_data %>%
  mutate(popup = paste0(
    "<strong>", htmltools::htmlEscape(name), "</strong><br>",
    "Type: ", fuel_type, "<br>",
    "Capacity: ", fmt_value(capacity_mw, "MW"), "<br>",
    "Annual Gen (2013): ", fmt_value(annual_generation_gwh, "GWh"), "<br>",
    "Commissioned: ", ifelse(is.na(commissioning_year), "n/a", floor(commissioning_year)), "<br>",
    "Owner: ", ifelse(is.na(owner), "n/a", htmltools::htmlEscape(owner)), "<br>",
    "Country: ", country
  ))

plant_map <- leaflet(options = leafletOptions(preferCanvas = TRUE)) %>%
  addTiles()  # OpenStreetMap tiles; CARTO basemaps now need an API key

for (fuel in fuel_types) {
  plant_map <- plant_map %>%
    addCircleMarkers(
      data = filter(plants_data, fuel_type == fuel),
      group = fuel,
      lng = ~longitude,
      lat = ~latitude,
      fillColor = ~fuel_pal(fuel_type),
      fillOpacity = 0.75,
      stroke = TRUE,
      color = "black",  # black border
      weight = 0.5,
      # Radius scaled by capacity, kept between 2 and 15 pixels
      radius = ~pmax(2, pmin(sqrt(capacity_mw) / 3, 15)),
      popup = ~popup
    )
}

plant_map <- plant_map %>%
  addLegend("bottomright", pal = fuel_pal, values = fuel_types,
            title = "Fuel type", opacity = 0.9) %>%
  addLayersControl(overlayGroups = fuel_types,
                   options = layersControlOptions(collapsed = FALSE))

map_file <- file.path(out_dir, "power_plants_map.html")
saveWidget(plant_map, file = normalizePath(map_file, mustWork = FALSE),
           selfcontained = rmarkdown::pandoc_available(),
           title = "Global Power Plants")

# Pie chart of fuel type share by number of plants
fuel_mix_plot <- ggplot(fuel_summary, aes(x = "", y = plants, fill = fuel_type)) +
  geom_col(width = 1, color = "white") +
  coord_polar(theta = "y") +
  scale_fill_manual(values = fuel_colors, labels = setNames(fuel_summary$label, fuel_summary$fuel_type)) +
  theme_void() +
  labs(title = "Fuel Type Distribution in Power Plants", fill = "Fuel Type") +
  # Label large slices only; the legend carries every share, so tiny slices stay readable
  geom_text(aes(label = ifelse(percentage >= 5, label, "")),
            position = position_stack(vjust = 0.5), size = 4)

# Bar chart of installed capacity: solar has the most plants but the least capacity
capacity_plot <- ggplot(fuel_summary, aes(x = reorder(fuel_type, capacity_gw), y = capacity_gw, fill = fuel_type)) +
  geom_col(width = 0.6, show.legend = FALSE) +
  geom_text(aes(label = paste0(capacity_gw, " GW (", format(plants, big.mark = ",", trim = TRUE), " plants)")),
            hjust = -0.05, size = 3.8) +
  scale_fill_manual(values = fuel_colors) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.45))) +
  coord_flip() +
  labs(title = "Installed Capacity by Fuel Type", x = NULL, y = "Capacity (GW)") +
  theme_minimal()

# Scatter plot of capacity vs generation; log scales need positive values
scatter_data <- plants_data %>%
  filter(!is.na(annual_generation_gwh), annual_generation_gwh > 0, capacity_mw > 0)

scatter_plot <- ggplot(scatter_data, aes(x = capacity_mw, y = annual_generation_gwh, color = fuel_type)) +
  geom_point(alpha = 0.6, size = 2) +
  scale_x_log10(labels = scales::label_comma()) +
  scale_y_log10(labels = scales::label_comma(accuracy = 0.01, drop0trailing = TRUE)) +
  scale_color_manual(values = fuel_colors) +
  labs(
    title = "Capacity vs Annual Generation (2013)",
    subtitle = paste(format(nrow(scatter_data), big.mark = ","), "plants with reported 2013 generation"),
    x = "Capacity (MW, log scale)",
    y = "Annual Generation (GWh, log scale)",
    color = "Fuel Type"
  ) +
  theme_minimal()

ggsave(file.path(out_dir, "fuel_mix.png"), fuel_mix_plot, width = 6, height = 5, dpi = 150, bg = "white")
ggsave(file.path(out_dir, "capacity_by_fuel.png"), capacity_plot, width = 7, height = 3.5, dpi = 150, bg = "white")
ggsave(file.path(out_dir, "capacity_vs_generation.png"), scatter_plot, width = 7, height = 5, dpi = 150, bg = "white")

# Show the map and charts when run interactively in RStudio
if (interactive()) {
  print(plant_map)
  print(fuel_mix_plot)
  print(capacity_plot)
  print(scatter_plot)
}

cat("Saved the map and charts to", out_dir, "\n")
