# Reproducibility package: water-level forecasts driven by rainfall nowcasts (Seveso at Palazzolo)

This package reproduces the hydrological results of the manuscript: the water level forecasts at Palazzolo
(Seveso river) for the September 2023 and October 2023 events, obtained by driving LSTM networks with
LDCast and GPTCast rainfall nowcasts at lead times of 10 to 60 min, the benchmarks (persistence, LSTM
without rainfall forecast and LSTM forced with observed rainfall), the evaluation metrics and the figures.

> **Note:** the LSTM model is the subject of a separate, not yet published study. The trained networks are
> provided only to reproduce the results of this manuscript during peer review. Please do not redistribute
> them or use them for other purposes. The networks are excluded from the MIT License of this repository
> (see [LICENSE](../LICENSE)).

## Requirements

- MATLAB R2024a (tested) with the Deep Learning Toolbox.

## How to run

Open MATLAB in this folder and run:

```matlab
run_reproduction
```

The script writes all outputs to `output/`. The folder `reference_output/` contains
the outputs produced by the authors, for comparison.

## Contents

```
run_reproduction.m           single script: simulations, benchmarks, metrics, figures
model/lstm_networks.mat      nets: trained networks, one per lead time (10, 20, ..., 60 min)
                             cfg:  input window lengths and min-max normalisation constants
data/<event>/                event = sep_2023, oct_2023
  observed_series.csv        10-min observed series (UTC+1): areal mean rainfall of the three
                             catchment sectors from rain gauges [mm] and water level at Palazzolo [cm]
  radar_observed.csv         10-min observed radar rainfall of the three sectors [mm] (UTC)
  LDCast/, GPTCast/          10-min rainfall nowcasts of the three sectors [mm] for each lead time (UTC)
reference_output/            outputs of run_reproduction.m produced by the authors
```

## Model inputs and simulated configurations

The catchment is divided into three sectors (upper, middle, lower). For each lead time L, a dedicated
network forecasts the water level at Palazzolo at t+L. The input at issue time t includes the following,
all min-max normalised with the constants in `cfg`:

- the observed water levels before t;
- the areal rainfall of each sector before t (rain gauges);
- the areal rainfall of each sector between t and t+L, at 10-min steps.

The rainfall between t and t+L is taken from a different source in each configuration:

| Configuration | Rainfall between t and t+L |
|---|---|
| `LDCast`, `GPTCast` | nowcast issued at t: the value at t+k·10 min is the nowcast with lead time k·10 min, valid at t+k·10 min |
| `RadarObs` | observed radar rainfall ("perfect nowcast" benchmark) |
| `Gauges` | observed rain-gauge rainfall (the forcing used to train the networks) |
| `NoRain` | zero rainfall (the same networks without any rainfall forecast) |
| `Persistence` | no model: the forecast for t+L is the water level observed at t |

The time stamps in the radar and nowcast files are valid times in UTC. They are converted to UTC+1, the
time base of the rain-gauge and water-level series.

**Warm-up.** The networks process the 10-min series as a continuous sequence. Each `observed_series.csv`
therefore starts 10 days before the event, so that the internal state of the network is fully spun up.
Results do not change if a longer warm-up is used.

**Evaluation window.** For each lead time, the metrics are computed over the forecasts whose whole interval
between t and t+L is covered by the nowcasts: 60 − L/10 + 1 time steps. All configurations, including
persistence, use the same window.

## Outputs

| File | Content |
|---|---|
| `simulations/<event>_leadtime_<L>.csv`, `simulations.xlsx` | Observed and forecasted water levels [cm] for each configuration. Time is the valid time t+L in local time: CEST (UTC+2) for September, CET (UTC+1) for October. |
| `metrics.csv`, `metrics.xlsx` | Evaluation metrics (see below) |
| `figure_hydrographs_all_lead_times.png` | Forecasted hydrographs for all lead times (nowcast-driven runs): Figure 12 of the manuscript |
| `figure_benchmarks.png` | Nowcast-driven runs compared with the benchmarks at 20, 40 and 60 min: Figure 13 of the manuscript |

In `metrics.csv`, the rows with `lead_time_min` = 20, 40 and 60 give the values reported in the manuscript:
KGE of the LDCast and GPTCast runs (Table 2), PTE (Table 3), PRE (Table 4), and KGE and NSE of all
configurations (Table 5). The manuscript rounds KGE and NSE to two decimals and PRE and PTE to integers.

The metrics, with s = forecasted and o = observed water level:

- **NSE**: Nash–Sutcliffe efficiency.
- **r**: linear correlation coefficient.
- **beta** = mean(s)/mean(o).
- **alpha** = std(s)/std(o).
- **gamma** = CV(s)/CV(o), where CV is the coefficient of variation.
- **KGE** = 1 − sqrt((r−1)² + (beta−1)² + (alpha−1)²).
- **KGE'** = 1 − sqrt((r−1)² + (beta−1)² + (gamma−1)²).
- **PRE**: relative error on the peak water level [%].
- **PTE**: peak timing error [min]. Positive values mean the forecasted peak is late.

The alert thresholds shown in the figures are 160, 200 and 245 cm (yellow, orange and red).
