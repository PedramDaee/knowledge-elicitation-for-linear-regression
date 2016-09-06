function [fa, si, converged] = linreg_sns_ep(y, x, pr, op, w_feedbacks, gamma_feedbacks, si)
% -- Likelihood (y are data, f are feedbacks):
%    p(y_i|x_i,w,sigma2) = N(y_i|w'x_i, sigma2)
%    p(f_w_j|w_j,eta2) = N(f_w_j|w_j, eta2)
%    p(f_gamma_j|gamma_j) = I(gamma_j=1) Bernoulli(f_gamma_j|p_u) + I(gamma_j=0) Bernoulli(f_gamma_j|1-p_u)
% -- Prior:
%    p(w_j|gamma_j=1) = Normal(w_j|0, tau2)
%    p(w_j|gamma_j=0) = delta(w_j)
%    p(gamma_j|rho) = Bernoulli(gamma_j|rho)
%    p(sigma2^-1) = Gamma(sigma2^-1|a,b) or fixed sigma2
% -- Approximation;
%    q(w) = Normal(w|Mean_w, Var_w), Var_w = Tau_w^-1
%    q(gamma) = \prod Bernoulli(gamma_j|p_gamma_j)
%    q(sigma2^-1) = Gamma(sigma2^-1|a,b)
%
%    sigma2 is updated using VB (if not fixed), other terms using EP.
%
% Inputs:
% y                target values (n x 1)
% x                covariates (n x m)
% pr               prior and other fixed model parameters (struct)
% op               options for the EP algorithm (struct)
% w_feedbacks      values (1st column) and indices (2nd column) of feedback (n_w_feedbacks x 2)
% gamma_feedbacks  values (1st column, 0/1) and indices (2nd column) of feedback (n_gamma_feedbacks x 2)
%
% Outputs:
% fa         EP posterior approximation (struct)
% si         EP site terms (struct)
% converged  did EP converge or hit max_iter (1/0)
%
% Tomi Peltola, tomi.peltola@aalto.fi

if nargin < 5
    w_feedbacks = [];
end

if nargin < 6
    gamma_feedbacks = [];
end

[n, m] = size(x);
pr.n = n;
pr.m = m;
pr.p_u_nat = log(pr.p_u) - log1p(-pr.p_u);
pr.yy = y' * y; % precompute
pr.xy = x' * y; % precompute
pr.xx = x' * x; % precompute
n_w_feedbacks = size(w_feedbacks, 1);
n_gamma_feedbacks = size(gamma_feedbacks, 1);

%% initialize (if si is given, prior sites are not re-initialized, but likelihood is)
if nargin < 7 || isempty(si)
    si.prior.w.mu = zeros(m, 1);
    si.prior.w.tau = (1 / pr.tau2) * ones(m, 1);
    si.prior.gamma.p_nat = zeros(m, 1);
end
S_f = zeros(m, m);
F_f = zeros(m, 1);
if n_w_feedbacks > 0
    for i = 1:n_w_feedbacks
        S_f(w_feedbacks(i, 2), w_feedbacks(i, 2)) = 1;
        F_f(w_feedbacks(i, 2)) = w_feedbacks(i, 1);
    end
end
si.wf.w.Tau = (1 / pr.eta2) * S_f;
si.wf.w.Mu = (1 / pr.eta2) * F_f;
if isfield(pr, 'sigma2_prior') && pr.sigma2_prior
    si.lik.sigma2.a = 0.5 * n;
    si.lik.sigma2.b = 0.5 * pr.yy;
    sigma2_imean = (pr.sigma2_a + si.lik.sigma2.a) / (pr.sigma2_b + si.lik.sigma2.b);
    si.lik.w.Tau = sigma2_imean * pr.xx;
    si.lik.w.Mu = sigma2_imean * pr.xy;
else
    si.lik.w.Tau = (1 / pr.sigma2) * pr.xx;
    si.lik.w.Mu = (1 / pr.sigma2) * pr.xy;
    pr.sigma2_prior = 0;
end
si.gf.gamma.p_nat = zeros(m, 1);

if isfield(pr, 'rho_prior') && pr.rho_prior
    rho_ = pr.rho_a / (pr.rho_a + pr.rho_b);
    si.prior.gamma.rho_nat = log(rho_) - log1p(-rho_);
    si.prior.rho.a = zeros(m, 1);
    si.prior.rho.b = zeros(m, 1);
else
    si.prior.gamma.rho_nat = log(pr.rho) - log1p(-pr.rho);
    pr.rho_prior = 0;
end

% TODO: name the si terms better (according to the terms that they
% approximate, e.g., si.gamma_g_rho.rho_nat, which would be the rho site of
% p(gamma|rho) term. Drop prior/lik as unnecessary?

% full approximation
fa = compute_full_approximation(si, pr);

% convergence diagnostics
conv.P_gamma_old = Inf * ones(m, 1);
conv.z_old = Inf * ones(m, 1);

%% loop parallel EP
for iter = 1:op.max_iter
    %% w prior updates
    % cavity
    ca_prior = compute_w_prior_cavity(fa, si.prior, pr);
    
    % moments of tilted dists
    [ti_prior, z_w] = compute_w_prior_tilt(ca_prior, pr);
    
    % site updates
    si.prior = update_w_prior_sites(si.prior, ca_prior, ti_prior, op);
    
    % full approx update
    fa = compute_full_approximation_w(fa, si, pr);
    fa = compute_full_approximation_gamma(fa, si, pr);

    %% gamma prior updates, EP for gamma, VB for rho
    if pr.rho_prior
        % VB
        si.prior.rho.a = (1 - op.damp) * si.prior.rho.a + op.damp * fa.gamma.p;
        si.prior.rho.b = (1 - op.damp) * si.prior.rho.b + op.damp * (1 - fa.gamma.p);
        %si.prior.rho.a = fa.gamma.p;
        %si.prior.rho.b = (1 - fa.gamma.p);
        
        fa = compute_full_approximation_rho(fa, si, pr);
        
        % EP
        cav_nat = fa.gamma.p_nat - si.prior.gamma.rho_nat;
        cav_a_m_cav_nat = (fa.rho.a - si.prior.rho.a - 1 + eps) .* cav_nat;
        cav_b = fa.rho.b - si.prior.rho.b - 1 + eps;
        ti_mean = cav_a_m_cav_nat ./ (cav_a_m_cav_nat + cav_b);
        ti_mean = max(min(ti_mean, 1-eps), eps);
        
        si.prior.gamma.rho_nat = (1 - op.damp) * si.prior.gamma.rho_nat + op.damp * (log(ti_mean) - log1p(-ti_mean) - cav_nat);
        
        fa = compute_full_approximation_gamma(fa, si, pr);
    end

    %% sigma2 and (the associated) likelihood VB update
    if pr.sigma2_prior
        % sigma2 update
        tr_tmp = x / fa.w.Tau_chol';

        % TODO: should we damp VB updates?
        si.lik.sigma2.b = (1 - op.damp) * si.lik.sigma2.b + op.damp * (0.5 * (pr.yy - 2 * (fa.w.Mean' * pr.xy) + tr_tmp(:)' * tr_tmp(:) + fa.w.Mean' * pr.xx * fa.w.Mean));
        %si.lik.sigma2.b = 0.5 * (pr.yy - 2 * (fa.w.Mean' * pr.xy) + tr_tmp(:)' * tr_tmp(:) + fa.w.Mean' * pr.xx * fa.w.Mean);

        fa = compute_full_approximation_sigma2(fa, si, pr);

        % likelihood update
        si.lik.w.Tau = fa.sigma2.imean * pr.xx;
        si.lik.w.Mu = fa.sigma2.imean * pr.xy;

        % full approx update
        fa = compute_full_approximation_w(fa, si, pr);
    end
    
    %% gamma feedback updates
    if n_gamma_feedbacks > 0
        % cavity
        ca_gf = compute_gf_cavity(fa, si.gf);

        % moments of tilted dists
        ti_gf = compute_gf_tilt(ca_gf, pr, gamma_feedbacks);

        % site updates
        si.gf = update_gf_sites(si.gf, ca_gf, ti_gf, gamma_feedbacks, op);

        % full approx update (update only gamma part as only those sites have been updated)
        fa = compute_full_approximation_gamma(fa, si, pr);
    end

    %% show progress and check for convergence
    [converged, conv] = report_progress_and_check_convergence(conv, iter, z_w, fa, op);
    if converged
        if op.verbosity > 0
            fprintf(1, 'EP converged on iteration %d\n', iter);
        end
        break
    end
    
    %% update damp
    op.damp = op.damp * op.damp_decay;
end

if op.verbosity > 0 && converged == 0
    fprintf(1, 'EP hit maximum number of iterations\n');
end

end


function ca = compute_gf_cavity(fa, si)

ca.gamma.p_nat = fa.gamma.p_nat - si.gamma.p_nat;

end


function ti = compute_gf_tilt(ca, pr, feedbacks)

% feedbacks: first is value, second index.
% Computes only those with feedback:
ti.gamma.mean = 1 ./ (1 + exp(-(ca.gamma.p_nat(feedbacks(:,2)) + (2 * feedbacks(:, 1) - 1) .* pr.p_u_nat)));
ti.gamma.mean = max(min(ti.gamma.mean, 1-eps), eps);

end


function [si] = update_gf_sites(si, ca, ti, feedbacks, op)

si.gamma.p_nat(feedbacks(:,2)) = (1 - op.damp) * si.gamma.p_nat(feedbacks(:,2)) + op.damp * (log(ti.gamma.mean) - log1p(-ti.gamma.mean) - ca.gamma.p_nat(feedbacks(:,2)));

end


function ca = compute_w_prior_cavity(fa, si, pr)

m = pr.m;

tmp = fa.w.Tau_chol \ eye(m);
var_w = sum(tmp.^2)';

denom = (1 - si.w.tau .* var_w);
ca.w.tau = denom ./ var_w;
ca.w.mean = (fa.w.Mean - var_w .* si.w.mu) ./ denom;

ca.gamma.p_nat = fa.gamma.p_nat - si.gamma.p_nat;
ca.gamma.p = 1 ./ (1 + exp(-ca.gamma.p_nat));

end


function [ti, z] = compute_w_prior_tilt(ca, pr)

t = ca.w.tau + 1 ./ pr.tau2;

g_var = 1 ./ ca.w.tau; % for gamma0
mcav2 = ca.w.mean.^2;
log_z_gamma0 = log1p(-ca.gamma.p) - 0.5 * log(g_var) - 0.5 * mcav2 ./ g_var;
g_var = pr.tau2 + g_var; % for gamma1
log_z_gamma1 = log(ca.gamma.p) - 0.5 * log(g_var) - 0.5 * mcav2 ./ g_var;
z_gamma0 = exp(log_z_gamma0 - log_z_gamma1);
z_gamma1 = ones(size(log_z_gamma1));
z = 1 + z_gamma0;

ti.w.mean = z_gamma1 .* (ca.w.tau .* ca.w.mean) ./ t ./ z;
e2_w_tilt = z_gamma1 .* (1 ./ t + 1 ./ t.^2 .* (ca.w.tau .* ca.w.mean).^2) ./ z;
ti.w.var = e2_w_tilt - ti.w.mean.^2;

ti.gamma.mean = z_gamma1 ./ z;
ti.gamma.mean = max(min(ti.gamma.mean, 1-eps), eps);

end


function [si, nonpositive_cavity_vars, nonpositive_site_var_proposals] = update_w_prior_sites(si, ca, ti, op)

nonpositive_site_var_proposals = false;

% skip negative cavs
update_inds = ca.w.tau(:) > 0;
nonpositive_cavity_vars = ~all(update_inds);

new_tau_w_site = 1 ./ ti.w.var - ca.w.tau;

switch op.robust_updates
    case 0
    case 1
        inds_tmp = new_tau_w_site(:) > 0;
        nonpositive_site_var_proposals = ~all(inds_tmp);
        update_inds = update_inds & inds_tmp;
    case 2
        inds = new_tau_w_site(:) <= 0;
        new_tau_w_site(inds) = op.min_site_prec;
        ti.w.var(inds) = 1./(op.min_site_prec + ca.w.tau(inds));
end
new_mu_w_site = ti.w.mean ./ ti.w.var - ca.w.tau .* ca.w.mean;
si.w.tau(update_inds) = (1 - op.damp) * si.w.tau(update_inds) + op.damp * new_tau_w_site(update_inds);
si.w.mu(update_inds) = (1 - op.damp) * si.w.mu(update_inds) + op.damp * new_mu_w_site(update_inds);

si.gamma.p_nat(update_inds) = (1 - op.damp) * si.gamma.p_nat(update_inds) + op.damp * (log(ti.gamma.mean(update_inds)) - log1p(-ti.gamma.mean(update_inds)) - ca.gamma.p_nat(update_inds));

end


function fa = compute_full_approximation(si, pr)

fa = struct;
fa = compute_full_approximation_w(fa, si, pr);
fa = compute_full_approximation_gamma(fa, si, pr);
if pr.sigma2_prior
    fa = compute_full_approximation_sigma2(fa, si, pr);
end
if pr.rho_prior
    fa = compute_full_approximation_rho(fa, si, pr);
end

end


function fa = compute_full_approximation_rho(fa, si, pr)

% These are Beta distribution parameters in the common parametrization;
% pr params are also, while si params are natural parameters.
fa.rho.a = sum(si.prior.rho.a) + pr.rho_a;
fa.rho.b = sum(si.prior.rho.b) + pr.rho_b;

end


function fa = compute_full_approximation_sigma2(fa, si, pr)

% a and b are in the common parametrization of Gamma (the one with mean = a/b)
fa.sigma2.imean = (pr.sigma2_a + si.lik.sigma2.a) / (pr.sigma2_b + si.lik.sigma2.b); % note: approx is for sigma2^-1

end


function fa = compute_full_approximation_w(fa, si, pr)

% m x m and m x 1
fa.w.Tau = si.lik.w.Tau + si.wf.w.Tau + diag(si.prior.w.tau);
fa.w.Tau_chol = chol(fa.w.Tau, 'lower');
fa.w.Mu = si.lik.w.Mu + si.wf.w.Mu + si.prior.w.mu;
fa.w.Mean = fa.w.Tau_chol' \ (fa.w.Tau_chol \ fa.w.Mu);

end


function fa = compute_full_approximation_gamma(fa, si, pr)

fa.gamma.p_nat = si.prior.gamma.p_nat + si.gf.gamma.p_nat + si.prior.gamma.rho_nat;
fa.gamma.p = 1 ./ (1 + exp(-fa.gamma.p_nat));

end


function [converged, conv] = report_progress_and_check_convergence(conv, iter, z, fa, op)

conv_z = mean(abs(z(:) - conv.z_old(:)));
conv_P_gamma = mean(abs(fa.gamma.p(:) - conv.P_gamma_old(:)));

if op.verbosity > 0 && mod(iter, op.verbosity) == 0
    fprintf(1, '%d, conv = [%.2e %.2e], damp = %.2e\n', iter, conv_z, conv_P_gamma, op.damp);
end

%converged = conv_z < op.threshold && conv_P_gamma < op.threshold;
converged = conv_P_gamma < op.threshold;

conv.z_old = z;
conv.P_gamma_old = fa.gamma.p;

end