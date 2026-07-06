#-------------------------------------------------------------------------------
# Program Name   : 02_create_visualizations.R
# Purpose        : generate a bar chart and frequency plot
#
# Programmer     : Sarah Kate Rogers
# Last Updated   : 2026-07-03
#
# Input          : ADAE
# Output         : bar_chart.html, frequency_plot.html
#-------------------------------------------------------------------------------

#Call Library----
library(ggplot2)
library(pharmaverseadam)
library(dplyr)

## Open Log
log_open()

#Call Data----
adae <- pharmaverseadam::adae

##Setup for Bar Chart---
bar <-  ggplot(adae, aes(ACTARM))

##Graph it!----
bar + geom_bar(aes(fill=AESEV))

## Part 2
## Count of AETERM, then generate top 10 ----
ae_counts <- adae %>%
  count(AETERM, name = "n") %>%
  arrange(desc(n)) %>% ##sort descending by n
  slice_head(n = 10)

## Get total count of participants in ADAE
N_total <- adae %>%
  distinct(USUBJID) %>%
  nrow()

# Clopper-Pearson exact CI for each AE term ----
ae_summary <- ae_counts %>%
  rowwise() %>%
  mutate(
    test = list(binom.test(n, N_total)),
    prop  = test$estimate,
    lower = test$conf.int[1],
    upper = test$conf.int[2]
  ) %>%
  ungroup() %>%
  select(-test)

# Plot ----
ggplot(ae_summary, aes(x = reorder(AETERM, prop), y = prop)) +
  geom_point(size = 2, color = "black") +
  geom_errorbar(aes(ymin = lower, ymax = upper), width = 0.2, color = "black") +
  coord_flip() +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(
    title = "Top 10 Most Frequent Adverse Events",
    subtitle = paste0("N = ", N_total, "; Exact (Clopper-Pearson) 95% CI"),
    x = NULL,
    y = "Percentage of Subjects (%)"
  )  

## End log
log_close()

