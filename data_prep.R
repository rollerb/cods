library(lmtest)
library(xts)
library(forecast)
library(vars)
library(tidyverse)
library(readr)
library(lubridate)
library(gtools)
library(ggthemes)

select <- dplyr::select

deaths2018 <- read_csv("https://data.cdc.gov/api/views/3yf8-kanr/rows.csv?accessType=DOWNLOAD")
deaths2020 <- read_csv("https://data.cdc.gov/api/views/muzy-jte6/rows.csv?accessType=DOWNLOAD")

dim(deaths2018)
dim(deaths2020)

deaths_tidy2018 <- deaths2018 %>%
  rename(
    state = "Jurisdiction of Occurrence",
    year = "MMWR Year",
    week = "MMWR Week",
    week_end = "Week Ending Date",
    all_causes = "All  Cause",
    natural_causes = "Natural Cause",
    septicemia = "Septicemia (A40-A41)",
    diabetes = "Diabetes mellitus (E10-E14)",
    influenza_pneumonia = "Influenza and pneumonia (J10-J18)",
    other_respiratory = "Other diseases of respiratory system (J00-J06,J30-J39,J67,J70-J98)",
    unknown_cause = "Symptoms, signs and abnormal clinical and laboratory findings, not elsewhere classified (R00-R99)",
    cerebrovascular = "Cerebrovascular diseases (I60-I69)",
    cancer = "Malignant neoplasms (C00-C97)",
    alzheimer = "Alzheimer disease (G30)",
    lower_respiratory = "Chronic lower respiratory diseases (J40-J47)",
    kidney_disease = "Nephritis, nephrotic syndrome and nephrosis (N00-N07,N17-N19,N25-N27)",
    heart_disease = "Diseases of heart (I00-I09,I11,I13,I20-I51)"
  ) %>%
  mutate(week_end = mdy(week_end)) %>%
  select(-starts_with("flag_")) %>%
  filter(state != "United States")

deaths_tidy2020 <- deaths2020 %>%
  rename(
    state = "Jurisdiction of Occurrence",
    year = "MMWR Year",
    week = "MMWR Week",
    week_end = "Week Ending Date",
    all_causes = "All Cause",
    natural_causes = "Natural Cause",
    septicemia = "Septicemia (A40-A41)",
    diabetes = "Diabetes mellitus (E10-E14)",
    influenza_pneumonia = "Influenza and pneumonia (J09-J18)",
    other_respiratory = "Other diseases of respiratory system (J00-J06,J30-J39,J67,J70-J98)",
    unknown_cause = "Symptoms, signs and abnormal clinical and laboratory findings, not elsewhere classified (R00-R99)",
    cerebrovascular = "Cerebrovascular diseases (I60-I69)",
    cancer = "Malignant neoplasms (C00-C97)",
    alzheimer = "Alzheimer disease (G30)",
    lower_respiratory = "Chronic lower respiratory diseases (J40-J47)",
    kidney_disease = "Nephritis, nephrotic syndrome and nephrosis (N00-N07,N17-N19,N25-N27)",
    heart_disease = "Diseases of heart (I00-I09,I11,I13,I20-I51)",
    covid  = "COVID-19 (U071, Underlying Cause of Death)",
    covid_multiple = "COVID-19 (U071, Multiple Cause of Death)"
  ) %>%
  select(-starts_with("flag_")) %>%
  filter(state != "United States")

deaths_tidy <- deaths_tidy2018 %>%
  bind_rows(deaths_tidy2020)

deaths_tidy_long <- deaths_tidy %>%
  pivot_longer(all_causes:covid, names_to = "measure", values_to = "value")

max_reliable_date <- max(deaths_tidy$week_end) - weeks(6)

cod_measures <- deaths_tidy %>% 
  filter(week_end <= max_reliable_date) %>%
  group_by(week_end) %>%
  summarize(across(septicemia:covid, ~ sum(.x, na.rm = TRUE)))

cod_measures_long <- deaths_tidy_long %>%
  filter(!(measure %in% c("all_causes", "natural_causes"))) %>%
  filter(week_end <= max_reliable_date) %>%
  group_by(week_end, measure) %>%
  summarize(value = sum(value, na.rm = TRUE)) %>%
  mutate(measure = as.factor(measure)) %>%
  arrange(week_end, measure)

write_rds(cod_measures, "cod_measures.rds")
write_rds(cod_measures_long, "cod_measures_long.rds")

#### Granger Causality

covid_period_measures <- cod_measures %>% filter(covid > 0)
cod_xts <- xts(x = covid_period_measures %>% select(-week_end), order.by = covid_period_measures$week_end)

granger_test <- function(formula, max_lags, data) {
  for(i in 0:(max_lags - 1)) {
    g_test <- tryCatch({
      g_test <- grangertest(formula, order = max_lags - i, data = data)
      return(g_test)
    }, error = function(err) {})
  }
}

get_granger <- function(data) {
  # separate time series
  series <- lapply(1:ncol(data), function (i) data[,i])
  
  # make each series stationary
  stationary_series <- lapply(series, function(a_series) {
    diffs <- ndiffs(a_series)
    if (diffs > 0) {
      na.fill(diff(a_series, lag = diffs), 0)
    } else {
      a_series
    }
  })
  
  # combine all combinations
  series <- do.call(merge.xts, stationary_series)
  fields <- names(series)
  field_comb <- permutations(length(fields), 2, fields)
  compare_inputs <- as.data.frame(field_comb) %>% rename(result = V1, predictor = V2)
  
  # calculate granger p-value
  pairs <- by(compare_inputs, 1:nrow(compare_inputs), function(pair) {
    a <- series[,pair$result]
    b <- series[,pair$predictor]
    var_select <- tryCatch({
      VARselect(merge.xts(a, b), type = "none")
    }, 
    warning = function(war) {
      data.frame(selection = c(10))
    })
    max_lags <- max(var_select$selection)
    g_formula <- paste(pair$result, pair$predictor, sep = " ~ ")
    g_test <- granger_test(as.formula(g_formula), max_lags, series)
    g_test_p_value <- round(g_test["Pr(>F)"][2,], 3)
    cbind(pair, granger = g_test_p_value, granger_formula = g_formula)
  })
  do.call(rbind, pairs)
}

cod_granger <- get_granger(cod_xts)

write_rds(cod_granger, "cod_granger.rds")

#### Predictions

causes_model_params <- list(
  "septicemia" = list(p = 3, d = 0, q = 1, P = 1, D = 0, Q = 1, gamma = 1),
  "cancer" = list(p = 2, d = 0, q = 2, P = 0, D = 0, Q = 0, gamma = 1),
  "diabetes" = list(p = 2, d = 0, q = 2, P = 0, D = 0, Q = 0, gamma = 1),
  "alzheimer" = list(p = 2, d = 0, q = 2, P = 0, D = 0, Q = 0, gamma = 0),
  "influenza_pneumonia" = list(p = 2, d = 0, q = 3, P = 0, D = 0, Q = 0, gamma = 0),
  "lower_respiratory" = list(p = 3, d = 0, q = 1, P = 0, D = 0, Q = 0, gamma = 1),
  "other_respiratory" = list(p = 4, d = 0, q = 3, P = 0, D = 0, Q = 0, gamma = 0),
  "kidney_disease" = list(p = 3, d = 0, q = 2, P = 0, D = 0, Q = 0, gamma = 1),
  "unknown_cause" = list(p = 3, d = 0, q = 2, P = 1, D = 0, Q = 0, gamma = 0),
  "heart_disease" = list(p = 2, d = 0, q = 3, P = 0, D = 0, Q = 0, gamma = 1),
  "cerebrovascular" = list(p = 2, d = 0, q = 2, P = 1, D = 0, Q = 0, gamma = 1)
)

xts_to_tibble <- function(data) {
  as.data.frame(data) %>% 
    rownames_to_column("date") %>%
    mutate(date = as.Date(date)) %>%
    as_tibble()
}

get_prediction <- function(data, disease) {
  train_disease_xts <- data[,disease]["2015/2019"]
  test_disease_xts <- data[,disease]["2020"]
  disease_xts_index = index(test_disease_xts)
  
  fit_params <- causes_model_params[[disease]]
  fit_order <- c(fit_params$p, fit_params$d, fit_params$q)
  fit_seasonal <- list(order = c(0,0,0)) # ignored seasonal
  disease_adjusted <- if (fit_params$gamma == 0) log(train_disease_xts) else train_disease_xts
  disease_fit <- arima(disease_adjusted, order = fit_order, seasonal = fit_seasonal)
  disease_est <- forecast(disease_fit, h = length(test_disease_xts))  
  
  if (fit_params$gamma == 0) {
    disease_est$mean <- exp(disease_est$mean)
    disease_est$upper <- exp(disease_est$upper)
    disease_est$lower <- exp(disease_est$lower)
  }
  
  mean_est_xts <- xts(disease_est$mean, order.by = disease_xts_index)
  upper_est_xts <- xts(disease_est$upper, order.by = disease_xts_index)
  lower_est_xts <- xts(disease_est$lower, order.by = disease_xts_index)
  
  disease_est_xts <- cbind.xts(test_disease_xts, mean_est_xts, upper_est_xts[,"95%"], lower_est_xts[,"95%"])
  names(disease_est_xts) <- c("actual", "mean", "upper", "lower")  
  xts_to_tibble(disease_est_xts) %>% mutate(disease = disease)
}

cod_names <- names(cod_xts)
cod_names <- cod_names[!(cod_names %in% c("covid", "covid_multiple"))]
cod_predictions <- lapply(cod_names, function(name) get_prediction(cod_xts, name))
cod_all_predictions <- do.call(rbind, cod_predictions)

write_rds(cod_all_predictions, "cod_predictions.rds")


#### USA State Polygon Data

USA <- map_data("state")
write_rds(USA, "usa_states.rds")