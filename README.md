# sample_r
Coding example for SDTM, ADaM, and TLG

# Purpose
The purpose of this repository to to provide sample code to create SDTM, ADaM, TLG in R. This area also includes an example that creates an LLM to use pandas to answer queries. 

# Structure
The repository is organized into 4 folders to reflect each question. 
* Question 1: Generate the SDTM DS
* Question 2: Generate the ADaM ADSL
* Question 3: Genetate an AE Table, and two figures 
* Question 4: Generate an LLM

  Each folder titled after the above question includes a variety of deliverables including the code, log, and output(s). 

# Process
## Question 1: Generate DS
To generate the SDTM DS, I spent time reading through the sdtm.oak and pharmaverse documentation before getting started. I also reviewed the SDTMiG requested. To start, I reviewed the raw data and the pharmaverse example for creating DM. I used this structure to start creating some variables in DS, and then used this knowledge to develop code for the requested variables. 

In the sdtm.oak package there is a suggested order for variable derivation. I used this to guide my own structure. Finally, I spent some time doing online searches for how to label the variables. I then moved on to Question 2 before returning to question 1 to apply any new lessons. In this case, the primary lesson I brough back was attempting to use xportr to export this dataset to XPT format. While this didn't work out, I was still able to export the file as an XPT format and confirm the file reads correctly with labels. 

## Question 2: Generate ADSL
After generating the SDTM, I had a good idea of where to start. I began by using the provided example, and then brought over code from that example that was similar to the requested variables. I then edited that code where applicable, and created new code where needed. This question was much quicker thanks to the time I spent getting oriented with the first question. I was able to use the admiral and xportr packages, as well as a sample specification from an Atorus example to complete the dataset. 

One challenge I noted during this question is that to generate the age grouping variables, the document said "Analysis Age" and then referred to DM.AGE. I defaulted to use AAGE in this case, and derived this variable based on the CDISC guidance. 

## Question 3: Generate TLGs
