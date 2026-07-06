#-------------------------------------------------------------------------------
# Program Name   : generate_adsl.R
# Purpose        : generate adsl variables
#
# Programmer     : Sarah Kate Rogers
# Date Created   : 2026-07-02
#
# Input          : DM, AE, VS, DS, EX
# Output         : ADSL
#-------------------------------------------------------------------------------

## Call Libraries ----
library(metacore)
library(metatools)
library(pharmaversesdtm)
library(admiral)
library(xportr)
library(dplyr)
library(tidyr)
library(lubridate)
library(stringr)
library(labelled)
library(readxl)
library(logr)
library(haven)

## Generate Log
log_open("adsl_log")

# Turn logger on and show notes 
options("logr.on" = TRUE, "logr.notes" = TRUE)


# Read in input SDTM data
dm <- pharmaversesdtm::dm
ds <- pharmaversesdtm::ds
ex <- pharmaversesdtm::ex
ae <- pharmaversesdtm::ae
vs <- pharmaversesdtm::vs
suppdm <- pharmaversesdtm::suppdm

# Convert to NA
dm <- convert_blanks_to_na(dm)
ds <- convert_blanks_to_na(ds)
ex <- convert_blanks_to_na(ex)
ae <- convert_blanks_to_na(ae)
vs <- convert_blanks_to_na(vs)
suppdm <- convert_blanks_to_na(suppdm)

# Combine Parent and Supp ----
dm_suppdm <- combine_supp(dm, suppdm) ## Just to look

## Generate Treatment Vars and ITTFL
adsl1 <- dm_suppdm %>%
  mutate(
    TRT01P = ARM,
    TRT01A = ACTARM,
    ITTFL = case_when(is.na(ARM) ~ NA, !is.na(ARM) ~ "Y")
  )

# Impute start and end time of exposure to first and last respectively
ex_ext <- ex %>%
  derive_vars_dtm(
    dtc = EXSTDTC,
    new_vars_prefix = "EXST"
  ) %>%
  derive_vars_dtm(
    dtc = EXENDTC,
    new_vars_prefix = "EXEN",
    time_imputation = "last"
  )

adsl1 <- adsl1 %>%
  derive_vars_merged(
    dataset_add = ex_ext,
    filter_add = (EXDOSE > 0 |
      (EXDOSE == 0 &
        str_detect(EXTRT, "PLACEBO"))) & !is.na(EXSTDTM),
    new_vars = exprs(TRTSDTM = EXSTDTM, TRTSTMF = EXSTTMF),
    order = exprs(EXSTDTM, EXSEQ),
    mode = "first",
    by_vars = exprs(STUDYID, USUBJID)
  ) %>%
  derive_vars_merged(
    dataset_add = ex_ext,
    filter_add = (EXDOSE > 0 |
      (EXDOSE == 0 &
        str_detect(EXTRT, "PLACEBO"))) & !is.na(EXENDTM),
    new_vars = exprs(TRTEDTM = EXENDTM, TRTETMF = EXENTMF),
    order = exprs(EXENDTM, EXSEQ),
    mode = "last",
    by_vars = exprs(STUDYID, USUBJID)
  )

## Generate LSTALVDT using VS
adsl2 <- adsl1 %>%
  derive_vars_extreme_event(
    by_vars = exprs(STUDYID, USUBJID),
    events = list(
      # Last obs with VSSTRESN and VSSTRESC not missing and VSDTC not missing
      event(
        dataset_name = "vs",
        order = exprs(VSTDC, VSSEQ),
        condition = !is.na(VSSTRESN) & !is.na(VSSTRESC) & !is.na(VSDTC),
        set_values_to = exprs(
          LSTALVDT = convert_dtc_to_dt(VSDTC, highest_imputation = "M"),
          seq = VSSEQ
        ),
      ),
      ## Last complete ONSET of an AE
      event(
        dataset_name = "ae",
        order = exprs(AESTDTC, AESEQ),
        condition = !is.na(AESTDTC),
        set_values_to = exprs(
          LSTALVDT = convert_dtc_to_dt(AESTDTC, highest_imputation = "M"),
          seq = AESEQ
        ),
      ),
      ## Last complete disposition date
      event(
        dataset_name = "ds",
        order = exprs(DSDTC, DSSEQ),
        condition = !is.na(DSDTC),
        set_values_to = exprs(
          LSTALVDT = convert_dtc_to_dt(DSDTC, highest_imputation = "M"),
          seq = DSSEQ
        ),
      ),
      ## last date of treatment admin. where patient received valid dose
      event(
        dataset_name = "adsl",
        condition = !is.na(TRTEDTM),
        set_values_to = exprs(LSTALVDT = TRTEDTM, seq = 0),
      )
    ),
    source_datasets = list(vs = vs, ae = ae, ds = ds, adsl = adsl1),
    tmp_event_nr_var = event_nr,
    order = exprs(LSTALVDT, seq, event_nr),
    mode = "last",
    new_vars = exprs(LSTALVDT)
  )

## Generate AGEGR9/N (needs RANDDT, AAGE, BRTHDT to derive) ----
## Get RANDDT using DS
ds_ext <- derive_vars_dt(
  ds,
  dtc = DSSTDTC,
  new_vars_prefix = "DSST"
)

adsl2 <- adsl2 %>%
  derive_vars_merged(
    dataset_add = ds_ext,
    filter_add = DSDECOD == "RANDOMIZED",
    by_vars = exprs(STUDYID, USUBJID),
    new_vars = exprs(RANDDT = DSSTDT)
  )

adsl2 <- adsl2 %>%
  derive_vars_dt(
    new_vars_prefix = "BRTH",
    dtc = BRTHDTC
  )

adsl2 <- adsl2 %>%
  derive_vars_aage(
    start_date = BRTHDT,
    end_date = RANDDT
  )

## Derive AGEGR9/AGEGR9N as “<18”, “18 - 50”, “>50”
adsl2 <- adsl2 %>%
  mutate(
    AGEGR9 = case_when(
      AAGE < 18 ~ "<18", AAGE >= 18 & AAGE <= 50 ~ "18-50",
      AAGE > 50 ~ ">50"
    ),
    AGEGR9N = case_when(
      AAGE < 18 ~ 1, AAGE >= 18 & AAGE <= 50 ~ 2,
      AAGE > 50 ~ 3)
  ) %>%
  select(
    "STUDYID", "USUBJID", "SUBJID", "SITEID", "AGE", "AGEU", "AAGE",
    "AAGEU", "SEX", "RACE", "TRT01P", "TRT01A", "TRTSDTM", "TRTSTMF",
    "RANDDT", "ITTFL", "LSTALVDT", "AGEGR9", "AGEGR9N"
  )

## Note, CDISC indicated using AAGE and the spec indicate "Analysis Age" in one
## cell, but AGE in the other.

## Assign Attributes
adsl <- adsl2 %>%
  set_variable_labels(
    STUDYID = "Study Identifier",
    USUBJID = "Unique Subject Identifier",
    SITEID = "Study Site Identifier",
    AGE = "Age",
    AGEU = "Age Units",
    AAGE = "Analysis Age",
    AAGEU = "Analysis Age Units",
    SEX = "Sex",
    RACE = "Race",
    TRT01P = "Planned Treatement for Period 01",
    TRT01A = "Actual Treatement  forPeriod 01",
    TRTSDTM = "Datetime of First Exposure to Treatment",
    TRTSTMF = "Datetime of First Exposure Imput. Flag",
    RANDDT = "Date of Randomization",
    ITTFL = "Intent-To-Treat Population Flag",
    LSTALVDT = "Date Last Known Alive",
    AGEGR9 = "Pooled Age Group 9",
    AGEGR9N = "Pooled Age Group 9 (N)"
  )

## Export ----
## Using ATORUS example for ADSL spec
## Read in spex
var_spec <- read_xlsx(
  system.file(file.path("specs/", "ADaM_spec.xlsx"), package = "xportr"),
  sheet = "Variables"
  ) %>%
  rename(type = "Data Type") %>%
  rename_with(tolower)

metadata <- data.frame(
  dataset = c("adsl"),
  label = c("Subject-Level Analysis")
  )

adsl <- xportr_df_label(adsl, metadata, domain = "adsl")

adsl <- adsl %>%
  xportr_type(var_spec, domain = "ADSL", verbose = "message") %>%
  xportr_metadata(domain = "ADSL", metadata = var_spec)

## Will give missing. warning for missing vars
out <- adsl %>%
    xportr_type(verbose = "warn") %>%
    xportr_length(verbose = "warn") %>%
    xportr_label(verbose = "warn") %>%
    xportr_order(verbose = "warn") %>%
    xportr_format() %>%
    xportr_df_label(metadata, "ADSL") %>%
    xportr_write("adsl.xpt")

out
log_print(out)

## Generate Log
log_close()

