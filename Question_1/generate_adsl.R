#-------------------------------------------------------------------------------
# Program Name   : generate_adsl.R
# Purpose        : generate adsl variables
#
# Programmer     : Sarah Kate Rogers
# Last Updated   : 2026-07-03
#
# Input          : DM, DS_RAW
# Output         : DS
#-------------------------------------------------------------------------------

## Call Packages ----
library(sdtm.oak)
library(pharmaverseraw)
library(dplyr)
library(labelled)
library(xportr)
library(logr)
library(haven)

## Open Log 
log_open()

## Call DM, raw DS, Controlled Terminology ----
ds_raw <- pharmaverseraw::ds_raw
dm <- pharmaversesdtm::dm
study_ct <- read.csv("sdtm_ct.csv")

## Start Code ----
ds1 <- ds_raw %>%
  generate_oak_id_vars(
    pat_var = "PATNUM",
    raw_src = "ds_raw"
  )

## Map all CT Vars for DS DSTERM, DSCAT, DSDECOD ----
ds2 <-
  ## Map DSTERM from study_ct (no CT) (where OTHERSP is NA)
  assign_no_ct(
    raw_dat = condition_add(ds1, is.na(OTHERSP)),
    raw_var = "IT.DSTERM",
    tgt_var = "DSTERM",
    id_vars = oak_id_vars()
  ) %>%
  ## Map DSDECOD from study_ct (no CT) (where OTHERSP is NA)
  assign_ct(
    raw_dat = condition_add(ds1, is.na(OTHERSP)),
    raw_var = "IT.DSDECOD",
    tgt_var = "DSDECOD",
    ct_spec = study_ct,
    ct_clst = "C66727",
    id_vars = oak_id_vars()
  ) %>%
  ## Map DSTERM where OTHERSP is NOT NULL
  assign_no_ct(
    raw_dat = condition_add(ds1, !is.na(OTHERSP)),
    raw_var = "OTHERSP",
    tgt_var = "DSTERM",
    id_vars = oak_id_vars()
  ) %>%
  assign_no_ct(
    ## Map DSDECOD where OTHERSP is NOT NULL
    raw_dat = condition_add(ds1, !is.na(OTHERSP)),
    raw_var = "OTHERSP",
    tgt_var = "DSDECOD",
    id_vars = oak_id_vars()
  )
  ##Check DSDECOD is toupper() at the end!

## DSCAT
dscat <-
  hardcode_ct(
    tgt_var = "DSCAT",
    raw_dat = condition_add(ds2, DSDECOD=="RANDOMIZED"),
    raw_var = "DSDECOD",
    tgt_val = "PROTOCOL MILESTONE",
    ct_spec = study_ct,
    ct_clst = "C74558"
  ) %>%
  hardcode_ct(
    tgt_var = "DSCAT",
    raw_dat = condition_add(ds2, !DSDECOD=="RANDOMIZED"),
    raw_var = "DSDECOD",
    tgt_val = "DISPOSITION EVENT",
    ct_spec = study_ct,
    ct_clst = "C74558"
  )

##Combine to check work----
ds3 <- merge(ds2, dscat)

#VISITNUM,VISIT, DSDTC, DSSTDTC, DSSTDY---- 
ds4 <- ds3 %>%
  #Map DSDTC from DSDTCOL
  assign_datetime(
    raw_dat = ds1,
    raw_var = "DSDTCOL",
    tgt_var = "DSDTC",
    raw_fmt = c("m-d-y")
  ) %>%
  # Map DSSTDTC from IT.DSSTDAT
  assign_datetime(
    raw_dat = ds1,
    raw_var = "IT.DSSTDAT",
    tgt_var = "DSSTDTC",
    raw_fmt = c("m-d-y"),
    id_vars = oak_id_vars()
  )   %>%
  # Map VISIT from INSTANCE
  assign_ct(
    raw_dat = ds1,
    raw_var = "INSTANCE",
    tgt_var = "VISIT",
    ct_spec = study_ct,
    ct_clst = "VISIT",
    id_vars = oak_id_vars()
  ) %>%
  # Map VISITNUM from INSTANCE
  assign_ct(
    raw_dat = ds1,
    raw_var = "INSTANCE",
    tgt_var = "VISITNUM",
    ct_spec = study_ct,
    ct_clst = "VISITNUM",
    id_vars = oak_id_vars()
  )

##DM Vars and Select final Vars ----
ds <- ds4 %>%
  dplyr::mutate(
    STUDYID = ds1$STUDY,
    DOMAIN = "DS",
    USUBJID = paste0("01-", ds1$PATNUM),
    DSTERM = toupper(DSTERM)
  ) %>%
  derive_seq(
    tgt_var = "DSSEQ",
    rec_vars = c("USUBJID", "DSTERM")
  ) %>%
  derive_study_day(
    sdtm_in = .,
    dm_domain = dm,
    tgdt = "DSSTDTC",
    refdt = "RFXSTDTC",
    study_day_var = "DSSTDY"
  ) %>%
      select(
        "STUDYID", "DOMAIN", "USUBJID", "DSSEQ", "DSTERM", "DSDECOD", "DSCAT",
        "DSDTC", "VISITNUM", "VISIT", "DSSTDTC", "DSSTDY" )

##Add variable labels? 
ds <- ds %>% 
  set_variable_labels(
    STUDYID    = "Study Identifier",
    DOMAIN     = "Domain Abbreviation",
    USUBJID    = "Unique Subject Identifier",
    DSSEQ      = "Sequence Number",
    DSTERM     = "Reported Term for the Disposition Event",
    DSDECOD    = "Standardized Disposition Term",
    DSCAT      = "Category for Disposition Event", 
    VISITNUM   = "Visit Number",
    VISIT      = "Visit Name", 
    DSDTC      = "Date/Time of Collection", 
    DSSTDTC     = "Start Date/Time of Disposition Event", 
    DSSTDY     = "Study Day of Start of Disposition Event"
  )

## Assign dataset label
dfmeta <- data.frame(
  dataset = c("DS"),
  label = c("Disposition")
)

ds <- xportr_df_label(ds, dfmeta, domain = "DS")

## Create XPT File
write_xpt(ds, "ds.xpt", version = 5)

## Generate Log
log_close()

