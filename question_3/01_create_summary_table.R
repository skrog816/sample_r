#-------------------------------------------------------------------------------
# Program Name   : 01_create_ae_summary_table.R
# Purpose        : generate AE Summary Table 
#
# Programmer     : Sarah Kate Rogers
# Date Created   : 2026-07-03
#
# Input          : ADAE
# Output         : adae_table.html
#-------------------------------------------------------------------------------

# Load libraries & data -------------------------------------
library(dplyr)
library(gtsummary)
library(logr)

## Open Log 
log_open()

## Call Data
adae <- pharmaverseadam::adae

# Pre-processing --------------------------------------------
adae <- adae %>%
  filter(
    # Treatment Emergent
    TRTEMFL == "Y"
  )

##Generate Table
tbl <- adae %>%
  tbl_hierarchical(
    variables = c(AESOC, AETERM), ##define heirarchy
    by = ACTARM,
    id = USUBJID,
    denominator = adsl,
    overall_row = TRUE,
    label = "..ard_hierarchical_overall.." ~ "Treatement Emergent AEs"
  )

##display table
tbl

log_close()


