%% Reproduction of the water-level forecasts driven by rainfall nowcasts (Seveso at Palazzolo)
%
% For each event (September and October 2023) and each lead time L = 10...60 min this script computes
% the water level at Palazzolo at t+L with the trained LSTM networks, using as rainfall between the
% issue time t and t+L:
%   - LDCast       : LDCast nowcasts
%   - GPTCast      : GPTCast nowcasts
%   - RadarObs     : observed radar rainfall ("perfect nowcast" benchmark)
%   - Gauges       : observed rain-gauge rainfall (forcing used in training)
%   - NoRain       : zero rainfall (LSTM without rainfall forecast)
% and the persistence benchmark (level at t+L = observed level at t).
%
% Outputs (folder "output"): simulated hydrographs (csv + xlsx), metrics (NSE, KGE, KGE', PRE, PTE)
% and two figures. See README.md.

close all

root = fileparts(mfilename('fullpath'));
if isempty(root), root = pwd; end
if ~exist('out_dir', 'var'), out_dir = fullfile(root, 'output'); end
if ~isfolder(fullfile(out_dir, 'simulations')), mkdir(fullfile(out_dir, 'simulations')); end

%% Settings

M = load(fullfile(root, 'model', 'lstm_networks.mat'));
nets = M.nets;   % one network per lead time
cfg  = M.cfg;    % input window lengths and normalisation constants

% Times: model inputs are aligned in UTC+1 (time base of the rain-gauge and water-level data);
% radar and nowcast files are in UTC. Outputs are reported in local time, as in the paper.
events = struct( ...
    'name',        {'sep_2023', 'oct_2023'}, ...
    'title',       {'15 Sep 2023', '31 Oct 2023'}, ...
    'local_shift', {hours(1), hours(0)}, ...             % UTC+1 -> local time
    'tz_label',    {'CEST/UTC+2', 'CET/UTC+1'}, ...
    'xlim_local',  {[datetime(2023,9,14,21,0,0), datetime(2023,9,15,19,0,0)], ...
                    [datetime(2023,10,30,20,0,0), datetime(2023,10,31,21,0,0)]}, ...
    'ylim',        {[-10 400], [0 450]});

nowcasts = ["LDCast", "GPTCast"];
inputs   = ["Persistence", "NoRain", "Gauges", "RadarObs", "LDCast", "GPTCast"];

alert_levels = [160 200 245];   % yellow, orange, red alert thresholds [cm]

%% Simulations

Sim = struct();
for e = 1:numel(events)
    ev = events(e).name;
    D  = readtable(fullfile(root, 'data', ev, 'observed_series.csv'));
    t  = D.datetime_UTC1;
    P  = [D.rain_upper_mm, D.rain_middle_mm, D.rain_lower_mm];
    H  = D.level_cm;

    R = read_rain(fullfile(root, 'data', ev, 'radar_observed.csv'));
    Fc = struct();
    for m = nowcasts
        Fc.(m) = cell(numel(cfg.lead_times_min), 1);
        for k = 1:numel(cfg.lead_times_min)
            Fc.(m){k} = read_rain(fullfile(root, 'data', ev, m, sprintf('%s_leadtime_%d.csv', m, cfg.lead_times_min(k))));
        end
    end
    t_first = R.time(1);    % first and last valid time of the nowcasts
    t_last  = R.time(end);

    for i = 1:numel(cfg.lead_times_min)
        L    = i;                                   % lead time in 10-min steps
        lead = minutes(cfg.lead_times_min(i));

        X  = build_inputs(H, P, L, cfg);
        tv = t(cfg.n_max_past + L:end);             % valid time of each forecast
        ti = tv - lead;                             % issue time

        % forecasts whose rainfall between t and t+L is fully covered by the nowcasts
        rows = find(tv >= t_first + lead - minutes(10) & tv <= t_last);

        out = table(tv(rows), 'VariableNames', {'time'});
        out.Observed    = H(ismember(t, tv(rows)));
        out.Persistence = H(ismember_ordered(ti(rows), t));
        out.NoRain      = simulate(nets{i}, remove_rain(X, rows, L, cfg), rows, cfg);
        out.Gauges      = simulate(nets{i}, X, rows, cfg);
        out.RadarObs    = simulate(nets{i}, insert_rain(X, rows, ti(rows), repmat({R}, L, 1), L, cfg), rows, cfg);
        for m = nowcasts
            out.(m) = simulate(nets{i}, insert_rain(X, rows, ti(rows), Fc.(m)(1:L), L, cfg), rows, cfg);
        end

        Sim.(ev){i} = out;
    end
end

%% Export simulations (local time)

for e = 1:numel(events)
    ev = events(e).name;
    for i = 1:numel(cfg.lead_times_min)
        out = Sim.(ev){i};
        out.time = out.time + events(e).local_shift;
        out.time.Format = 'yyyy-MM-dd HH:mm';
        out = renamevars(out, 'time', 'time_local');
        writetable(out, fullfile(out_dir, 'simulations', sprintf('%s_leadtime_%d.csv', ev, cfg.lead_times_min(i))));
        writetable(out, fullfile(out_dir, 'simulations.xlsx'), 'Sheet', sprintf('%s_t%d', ev, cfg.lead_times_min(i)));
    end
end

%% Metrics

metric_names = ["NSE", "r", "beta", "alpha", "gamma", "KGE", "KGE_prime", "PRE_percent", "PTE_min"];
Metrics = table();
for e = 1:numel(events)
    ev = events(e).name;
    for s = inputs
        for i = 1:numel(cfg.lead_times_min)
            out = Sim.(ev){i};
            row = [table(string(ev), s, cfg.lead_times_min(i), height(out), ...
                'VariableNames', {'event', 'input', 'lead_time_min', 'n_steps'}), ...
                array2table(metrics(out.(s), out.Observed), 'VariableNames', metric_names)];
            Metrics = [Metrics; row]; %#ok<AGROW>
        end
    end
end
writetable(Metrics, fullfile(out_dir, 'metrics.csv'));
writetable(Metrics, fullfile(out_dir, 'metrics.xlsx'));
disp(Metrics(:, ["event", "input", "lead_time_min", "NSE", "KGE", "PRE_percent", "PTE_min"]))

%% Figure 1: hydrographs for all lead times (paper style)

lead_colors = {[0.58 0.40 0.74], [0 0 1], [0 0.85 0.95], [1 0.65 0], [0.95 0.15 0.15], [0.13 0.55 0.13]};
alert_colors = {[1 0.84 0], [1 0.55 0], [1 0 0]};

fig = figure('Color', 'w', 'Position', [30 30 1700 1250]);
tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
labels = ["(a)", "(b)"; "(c)", "(d)"];   % (a), (b): LDCast, GPTCast in September; (c), (d): October
for e = 1:numel(events)
    ev = events(e).name; sh = events(e).local_shift;
    D  = readtable(fullfile(root, 'data', ev, 'observed_series.csv'));
    for m = 1:numel(nowcasts)
        ax = nexttile; hold on; grid on; box on;
        h = gobjects(0); names = strings(0);
        for i = 1:numel(cfg.lead_times_min)
            out = Sim.(ev){i};
            h(end+1) = plot(out.time + sh, out.(nowcasts(m)), 'Color', lead_colors{i}, 'LineWidth', 1.2); %#ok<SAGROW>
            names(end+1) = sprintf('Lead time: %d min', cfg.lead_times_min(i)); %#ok<SAGROW>
        end
        h(end+1) = plot(D.datetime_UTC1 + sh, D.level_cm, 'k', 'LineWidth', 2.5); names(end+1) = "Observed";
        for k = 1:3
            h(end+1) = yline(alert_levels(k), '--', 'Color', alert_colors{k}, 'LineWidth', 1.5); %#ok<SAGROW>
        end
        names = [names, "Yellow Alert", "Orange Alert", "Red Alert"];

        xlim(events(e).xlim_local); ylim(events(e).ylim);
        xticks(events(e).xlim_local(1):hours(1):events(e).xlim_local(2));
        ax.XAxis.TickLabelFormat = 'yyyy-MM-dd HH:mm'; xtickangle(90); ax.FontSize = 8;
        ylabel('Water Level [cm]', 'FontSize', 10);
        xlabel({sprintf('Date and Hour (%s)', events(e).tz_label), ['\fontsize{18}\fontname{Times New Roman}' char(labels(e, m))]}, ...
            'Interpreter', 'tex', 'FontSize', 10);
        legend(h, names, 'Location', 'northeast', 'FontSize', 9);
    end
end
exportgraphics(fig, fullfile(out_dir, 'figure_hydrographs_all_lead_times.png'), 'Resolution', 300);

%% Figure 2: benchmarks at t+20, t+40, t+60

leads_fig = [20 40 60];
panel = ["(a)", "(b)"; "(c)", "(d)"; "(e)", "(f)"];
ldcast_color  = [0 0.447 0.741];       % same colour in all panels
gptcast_color = [0.466 0.674 0.188];
fig = figure('Color', 'w', 'Position', [50 50 1400 1350]);
tl = tiledlayout(numel(leads_fig), numel(events), 'TileSpacing', 'compact', 'Padding', 'compact');
for r = 1:numel(leads_fig)
    i = find(cfg.lead_times_min == leads_fig(r));
    for e = 1:numel(events)
        ev = events(e).name; sh = events(e).local_shift;
        D  = readtable(fullfile(root, 'data', ev, 'observed_series.csv'));
        out = Sim.(ev){i};
        ax = nexttile; hold on; grid on; box on;
        t0 = out.time(1) - minutes(30); t1 = out.time(end) + minutes(30);
        sel = D.datetime_UTC1 >= t0 & D.datetime_UTC1 <= t1;
        h = gobjects(0);
        h(end+1) = plot(D.datetime_UTC1(sel) + sh, D.level_cm(sel), 'k', 'LineWidth', 2.5);
        h(end+1) = plot(out.time + sh, out.Persistence, ':', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.8);
        h(end+1) = plot(out.time + sh, out.NoRain, '-.', 'Color', [0.8 0 0.8], 'LineWidth', 1.4);
        h(end+1) = plot(out.time + sh, out.RadarObs, '-', 'Color', [0.55 0.27 0.07], 'LineWidth', 1.8);
        h(end+1) = plot(out.time + sh, out.LDCast, '-', 'Color', ldcast_color, 'LineWidth', 1.8);
        h(end+1) = plot(out.time + sh, out.GPTCast, '--', 'Color', gptcast_color, 'LineWidth', 1.8);
        for k = 1:3
            h(end+1) = yline(alert_levels(k), '--', 'Color', alert_colors{k}, 'LineWidth', 1.2); %#ok<SAGROW>
        end
        xlim([t0 t1] + sh); ylim(events(e).ylim);
        ax.XAxis.TickLabelFormat = 'HH:mm';
        ylabel('Water Level [cm]');
        if r == numel(leads_fig), xlabel(sprintf('Date and Hour (%s)', events(e).tz_label)); end
        title(sprintf('%s %s - Lead time: %d min', panel(r, e), events(e).title, leads_fig(r)));
        if r == 1 && e == 1, hl = h; end
    end
end
lgd = legend(hl, ["Observed", "Persistence", "LSTM, no rainfall forecast", "LSTM + observed radar", ...
    "LSTM + LDCast", "LSTM + GPTCast", "Yellow Alert", "Orange Alert", "Red Alert"], ...
    'Orientation', 'horizontal', 'NumColumns', 3, 'FontSize', 15);
lgd.Layout.Tile = 'south';
exportgraphics(fig, fullfile(out_dir, 'figure_benchmarks.png'), 'Resolution', 300);

fprintf('Outputs written to %s\n', out_dir);

%% Local functions

function R = read_rain(file)
% radar / nowcast csv: two header lines, time (UTC, valid time) + areal rainfall of the 3 sectors [mm]
R = readtable(file, 'NumHeaderLines', 1, 'VariableNamingRule', 'preserve');
R = table(R{:,1} + hours(1), R{:,2}, R{:,3}, R{:,4}, 'VariableNames', {'time', 'upper', 'middle', 'lower'});
end

function X = build_inputs(H, P, L, cfg)
% one row per forecast: [past levels, upper rain (past + t..t+L), middle rain (...), lower rain (...)]
sc = @(v, a, b) (v - a) ./ (b - a);
h = sc(H, cfg.level_min, cfg.level_max);
p = sc(P, cfg.rain_min, cfg.rain_max);
nm = cfg.n_max_past; nh = cfg.n_past_level; np = cfg.n_past_rain;
n = numel(H) - (nm + L - 1);
X = nan(n, nh + sum(np) + 3*L);
for r = 1:n
    X(r,:) = [h(r+nm-nh:r+nm-1)', p(r+nm-np(1):r+nm+L-1, 1)', p(r+nm-np(2):r+nm+L-1, 2)', p(r+nm-np(3):r+nm+L-1, 3)'];
end
end

function X = insert_rain(X, rows, t_issue, sources, L, cfg)
% replaces the rainfall between the issue time and t+L with the given source:
% column k of each sector block (k = 1...L) receives the rainfall valid at t_issue + k*10 min,
% taken from sources{k} (for nowcasts: the lead-time-k nowcast)
sc = @(v, a, b) (v - a) ./ (b - a);
block_end = cfg.n_past_level + cumsum(cfg.n_past_rain + L);
for k = 1:L
    S = sources{k};
    [found, idx] = ismember(t_issue + minutes(10*k), S.time);
    assert(all(found), 'Missing rainfall at some valid times');
    v = sc([S.upper(idx), S.middle(idx), S.lower(idx)], cfg.rain_min, cfg.rain_max);
    for s = 1:3
        X(rows, block_end(s) - L + k) = v(:, s);
    end
end
end

function X = remove_rain(X, rows, L, cfg)
% sets the rainfall between the issue time and t+L to zero (no rainfall forecast)
block_end = cfg.n_past_level + cumsum(cfg.n_past_rain + L);
for s = 1:3
    X(rows, block_end(s) - L + 1:block_end(s)) = (0 - cfg.rain_min(s)) / (cfg.rain_max(s) - cfg.rain_min(s));
end
end

function q = simulate(net, X, rows, cfg)
% the LSTM processes the rows as one sequence: the days before the event warm up its state
Q = cfg.level_min + (cfg.level_max - cfg.level_min) * predict(net, X);
q = Q(rows);
end

function idx = ismember_ordered(a, b)
[found, idx] = ismember(a, b);
assert(all(found));
end

function m = metrics(s, o)
c     = corrcoef(s, o);   % Pearson correlation (base MATLAB, no Statistics Toolbox needed)
r     = c(1, 2);
beta  = mean(s) / mean(o);
alpha = std(s) / std(o);
gamma = (std(s)/mean(s)) / (std(o)/mean(o));
nse   = 1 - sum((s - o).^2) / sum((o - mean(o)).^2);
kge   = 1 - sqrt((r-1)^2 + (beta-1)^2 + (alpha-1)^2);
kge2  = 1 - sqrt((r-1)^2 + (beta-1)^2 + (gamma-1)^2);
[~, is] = max(s); [~, io] = max(o);
pre   = (max(s) - max(o)) / max(o) * 100;
pte   = (is - io) * 10;
m     = [nse r beta alpha gamma kge kge2 pre pte];
end
