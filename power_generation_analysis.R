# Power generation analysis: how much electricity solar, nuclear and hydro
# plants actually produce, and how closely that tracks their capacity.
#
# Run from the project folder:  Rscript power_generation_analysis.R
# Needs a MongoDB server; set MONGO_URL to use one other than localhost.

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(mongolite)
  library(ggplot2)
})

csv_path    <- "data/global_power_plant_database.csv"
out_dir     <- "output"
mongo_url   <- Sys.getenv("MONGO_URL", "mongodb://localhost:27017")
fuel_types  <- c("Solar", "Nuclear", "Hydro")
fuel_colors <- c(Solar = "#E8A317", Nuclear = "#C0392B", Hydro = "#2E86C1")
hours_per_year <- 8760

if (!file.exists(csv_path)) {
  stop("Dataset not found at ", csv_path, ". Run this script from the project folder.")
}
dir.create(out_dir, showWarnings = FALSE)

# Step 1: Read the dataset and keep each plant's most recent reported generation.
# Only reported figures are used; the dataset's modelled estimates are left out.
power_plants <- read_csv(csv_path, show_col_types = FALSE, guess_max = 40000)

generation <- power_plants %>%
  filter(primary_fuel %in% fuel_types, !is.na(capacity_mw), capacity_mw > 0) %>%
  select(gppd_idnr, name, country = country_long, fuel_type = primary_fuel,
         capacity_mw, starts_with("generation_gwh_")) %>%
  pivot_longer(starts_with("generation_gwh_"), names_to = "year",
               names_prefix = "generation_gwh_", values_to = "generation_gwh",
               values_drop_na = TRUE) %>%
  filter(generation_gwh > 0) %>%
  mutate(year = as.integer(year)) %>%
  group_by(gppd_idnr) %>%
  slice_max(year, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  # Capacity factor: share of the year's maximum possible output actually produced
  mutate(capacity_factor = generation_gwh * 1000 / (capacity_mw * hours_per_year))

# Drop physically impossible rows (more output than running flat out all year)
n_before <- nrow(generation)
generation <- filter(generation, capacity_factor <= 1)
cat("Plants with reported generation:", n_before, "; dropped", n_before - nrow(generation),
    "with a capacity factor above 100%\n")

# Step 2: Store in MongoDB, then let MongoDB do the per-fuel summary
gen_collection <- mongo(collection = "plant_generation", db = "energy_db", url = mongo_url)
gen_collection$drop()
invisible(gen_collection$insert(generation))

fuel_summary <- gen_collection$aggregate('[
  {"$group": {
    "_id": "$fuel_type",
    "plants": {"$sum": 1},
    "capacity_gw": {"$sum": {"$divide": ["$capacity_mw", 1000]}},
    "generation_twh": {"$sum": {"$divide": ["$generation_gwh", 1000]}}
  }},
  {"$sort": {"generation_twh": -1}}
]') %>%
  rename(fuel_type = `_id`)

plants_data <- gen_collection$find(fields = '{"_id": 0}')
plants_data$fuel_type <- factor(plants_data$fuel_type, levels = fuel_types)

# Correlation between capacity and generation, per fuel. Both are heavily
# skewed, so Pearson r is computed on log values; Spearman uses ranks.
correlations <- plants_data %>%
  group_by(fuel_type) %>%
  summarise(
    plants = n(),
    pearson_log = cor(log10(capacity_mw), log10(generation_gwh)),
    spearman = cor(capacity_mw, generation_gwh, method = "spearman"),
    median_cf = median(capacity_factor),
    .groups = "drop"
  )

cat("\nTotals by fuel (from MongoDB aggregation):\n")
print(mutate(fuel_summary, across(where(is.double), ~ round(.x, 1))))
cat("\nCapacity vs generation, per fuel:\n")
print(mutate(correlations, across(where(is.double), ~ round(.x, 2))))

# Chart 1: generation against capacity, one panel per fuel. Dashed lines show
# fixed capacity factors, so a point's position tells you how hard the plant runs.
# Each panel gets its own capacity range, so the reference lines span only that panel
cap_ranges <- plants_data %>%
  group_by(fuel_type) %>%
  summarise(cap_min = min(capacity_mw), cap_max = max(capacity_mw), .groups = "drop")

cf_lines <- crossing(cf = c(0.1, 0.25, 0.9), cap_ranges) %>%
  mutate(label = paste0(cf * 100, "%"))

cf_line_points <- cf_lines %>%
  pivot_longer(c(cap_min, cap_max), values_to = "capacity_mw") %>%
  mutate(generation_gwh = capacity_mw * hours_per_year * cf / 1000)

r_labels <- correlations %>%
  mutate(text = sprintf("r = %.2f  |  n = %s  |  median CF %.0f%%",
                        pearson_log, format(plants, big.mark = ",", trim = TRUE), median_cf * 100))

correlation_plot <- ggplot(plants_data, aes(capacity_mw, generation_gwh)) +
  geom_line(data = cf_line_points, aes(group = cf), linetype = "dashed",
            color = "grey60", linewidth = 0.4) +
  geom_point(aes(color = fuel_type), alpha = 0.45, size = 1.6, show.legend = FALSE) +
  geom_smooth(method = "lm", formula = y ~ x, se = FALSE, color = "black", linewidth = 0.7) +
  geom_label(data = r_labels, aes(label = text), x = -Inf, y = Inf,
             hjust = -0.03, vjust = 1.3, size = 3.3, label.size = 0, fill = "white") +
  scale_x_log10(labels = scales::label_comma()) +
  scale_y_log10(labels = scales::label_comma(accuracy = 0.01, drop0trailing = TRUE)) +
  scale_color_manual(values = fuel_colors) +
  facet_wrap(~fuel_type, nrow = 1, scales = "free_x") +
  labs(
    title = "Bigger plants generate more, but how much more depends on the fuel",
    subtitle = "Most recent reported year per plant (2013-2019). Dashed lines, bottom to top: 10%, 25% and 90% capacity factor. Black line: log-log fit.",
    x = "Installed capacity (MW, log scale)",
    y = "Annual generation (GWh, log scale)"
  ) +
  theme_minimal(base_size = 12) +
  theme(strip.text = element_text(face = "bold", size = 12),
        panel.spacing = unit(1.2, "lines"))

# Chart 2: capacity factor by fuel, the clearest single comparison
cf_plot <- ggplot(plants_data, aes(fuel_type, capacity_factor, fill = fuel_type)) +
  geom_violin(alpha = 0.35, color = NA, scale = "width") +
  geom_boxplot(width = 0.18, outlier.shape = NA, alpha = 0.9) +
  geom_text(data = correlations, aes(y = median_cf, label = paste0(round(median_cf * 100), "%")),
            nudge_x = 0.24, size = 4, fontface = "bold", hjust = 0) +
  scale_y_continuous(labels = scales::label_percent(), limits = c(0, 1)) +
  scale_fill_manual(values = fuel_colors, guide = "none") +
  labs(
    title = "How hard each type of plant runs",
    subtitle = "Capacity factor = actual generation / output if running at full capacity all year. Label = median.",
    x = NULL,
    y = "Capacity factor"
  ) +
  theme_minimal(base_size = 12)

# Chart 3: the biggest generators in the dataset
top_plants <- plants_data %>%
  slice_max(generation_gwh, n = 15) %>%
  mutate(name = ifelse(name == toupper(name), tools::toTitleCase(tolower(name)), name),
         country = recode(country, "United States of America" = "USA"),
         label = paste0(name, " (", country, ")"),
         label = reorder(label, generation_gwh))

top_plot <- ggplot(top_plants, aes(generation_gwh / 1000, label, fill = fuel_type)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = paste0(round(generation_gwh / 1000, 1), " TWh")),
            hjust = -0.1, size = 3.4) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.15))) +
  scale_fill_manual(values = fuel_colors, name = "Fuel type") +
  labs(
    title = "The 15 largest generators",
    subtitle = "Annual generation in the most recent reported year",
    x = "Annual generation (TWh)",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top", legend.justification = "left")

ggsave(file.path(out_dir, "generation_vs_capacity_by_fuel.png"), correlation_plot,
       width = 12, height = 5, dpi = 150, bg = "white")
ggsave(file.path(out_dir, "capacity_factor_by_fuel.png"), cf_plot,
       width = 8, height = 5, dpi = 150, bg = "white")
ggsave(file.path(out_dir, "top_generators.png"), top_plot,
       width = 9, height = 6, dpi = 150, bg = "white")
write_csv(correlations, file.path(out_dir, "generation_correlations.csv"))

if (interactive()) {
  print(correlation_plot)
  print(cf_plot)
  print(top_plot)
}

cat("\nSaved the generation charts and correlation table to", out_dir, "\n")
