CREATE DATABASE ecom_analytics;
USE ecom_analytics;

SELECT COUNT(*) FROM customers;   -- should show 1,500
SELECT COUNT(*) FROM orders;      -- should show 8,486
SELECT COUNT(*) FROM campaigns;   -- should show 11,314
SELECT COUNT(*) FROM products;    -- should show 200

-- ============================================================
--  E-Commerce Customer Marketing & Campaign ROI Analytics
--  All queries written for MySQL 8.0
--  Tables: customers | orders | campaigns | products
-- ============================================================


-- ── Q1: Campaign ROI by Channel ──────────────────────────────────
-- WHY: The foundation metric — how much did each campaign type cost
-- vs generate? Reveals that Paid Social has the worst ROI despite
-- receiving the most budget.
-- INTERVIEW TIP: "Cost per conversion is the number that changes
-- the budget conversation — not total spend, not total revenue."

SELECT
    campaign_type,
    COUNT(*)                                            AS total_sends,
    SUM(converted)                                      AS conversions,
    ROUND(SUM(converted) * 100.0 / COUNT(*), 2)         AS conversion_rate_pct,
    ROUND(SUM(campaign_cost), 0)                        AS total_cost,
    ROUND(SUM(revenue_generated), 0)                    AS total_revenue,
    ROUND(SUM(revenue_generated) - SUM(campaign_cost), 0) AS net_roi,
    ROUND((SUM(revenue_generated) - SUM(campaign_cost))
          / SUM(campaign_cost) * 100, 1)                AS roi_pct,
    ROUND(SUM(campaign_cost) / NULLIF(SUM(converted), 0), 2) AS cost_per_conversion
FROM campaigns
GROUP BY campaign_type
ORDER BY roi_pct DESC;


-- ── Q2: Revenue per Customer by Channel — SUM OVER (Window) ─────
-- WHY: Total channel revenue is misleading — Paid Social looks best
-- until you divide by customer count. RANK() OVER makes the ranking
-- explicit without a separate query.
-- INTERVIEW TIP: "Window functions let me rank AND aggregate in the
-- same query — I don't need a subquery just to add a rank column."

WITH customer_revenue AS (
    SELECT
        c.customer_id,
        c.acquisition_channel,
        c.segment,
        ROUND(SUM(o.net_revenue), 2)    AS total_revenue,
        ROUND(SUM(o.net_margin), 2)     AS total_margin,
        COUNT(o.order_id)               AS order_count,
        ROUND(AVG(o.order_value), 2)    AS avg_order_value,
        SUM(o.is_returned)              AS returns
    FROM customers c
    LEFT JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.acquisition_channel, c.segment
)
SELECT
    acquisition_channel,
    COUNT(customer_id)                                          AS customers,
    ROUND(AVG(total_revenue), 0)                                AS avg_rev_per_customer,
    ROUND(AVG(total_margin), 0)                                 AS avg_margin_per_customer,
    ROUND(AVG(order_count), 1)                                  AS avg_orders,
    ROUND(AVG(avg_order_value), 0)                              AS avg_order_value,
    ROUND(SUM(returns) * 100.0 / NULLIF(SUM(order_count), 0), 1) AS return_rate_pct,
    RANK() OVER (ORDER BY AVG(total_revenue) DESC)              AS revenue_rank
FROM customer_revenue
GROUP BY acquisition_channel
ORDER BY avg_rev_per_customer DESC;


-- ── Q3: Month-over-Month Revenue — LAG() Window Function ────────
-- WHY: LAG() retrieves the previous row's value without a self-join.
-- Cumulative revenue (running total) uses ROWS BETWEEN UNBOUNDED
-- PRECEDING AND CURRENT ROW — a standard analyst pattern.
-- INTERVIEW TIP: "LAG() is cleaner than a self-join for MoM — one
-- pass, no duplication, easy to extend to 3-month rolling average."

WITH monthly AS (
    SELECT
        order_month,
        ROUND(SUM(net_revenue), 0)      AS revenue,
        ROUND(SUM(net_margin), 0)       AS margin,
        COUNT(DISTINCT customer_id)     AS active_customers,
        COUNT(order_id)                 AS orders
    FROM orders
    GROUP BY order_month
)
SELECT
    order_month,
    revenue,
    margin,
    active_customers,
    orders,
    LAG(revenue) OVER (ORDER BY order_month)    AS prev_month_revenue,
    ROUND(
        (revenue - LAG(revenue) OVER (ORDER BY order_month))
        * 100.0
        / NULLIF(LAG(revenue) OVER (ORDER BY order_month), 0)
    , 1)                                         AS mom_growth_pct,
    ROUND(SUM(revenue) OVER (
        ORDER BY order_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 0)                                        AS cumulative_revenue
FROM monthly
ORDER BY order_month;


-- ── Q4: Purchase Frequency Cohorts — CTEs + OVER() ───────────────
-- WHY: The Pareto principle in action — the top 34% of customers
-- (Loyal, 7+ orders) generate 55% of revenue. The two OVER()
-- window functions calculate % share in the same GROUP BY pass.
-- INTERVIEW TIP: "SUM(x) OVER () with no partition gives a grand
-- total — dividing by it gives percentage share cleanly."

WITH customer_orders AS (
    SELECT
        c.customer_id,
        c.acquisition_channel,
        c.segment,
        DATE_FORMAT(c.signup_date, '%Y-%m')      AS cohort_month,
        COUNT(o.order_id)                         AS order_count,
        ROUND(SUM(o.net_revenue), 2)              AS lifetime_revenue,
        MIN(o.order_date)                         AS first_order,
        MAX(o.order_date)                         AS last_order,
        ROUND(DATEDIFF(MAX(o.order_date),
                       MIN(o.order_date)) / 30.0, 1) AS active_months
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.acquisition_channel, c.segment,
             DATE_FORMAT(c.signup_date, '%Y-%m')
),
frequency_bands AS (
    SELECT *,
        CASE
            WHEN order_count = 1  THEN '1. One-time buyer'
            WHEN order_count <= 3 THEN '2. Occasional (2-3)'
            WHEN order_count <= 6 THEN '3. Regular (4-6)'
            ELSE                       '4. Loyal (7+)'
        END AS frequency_band
    FROM customer_orders
)
SELECT
    frequency_band,
    COUNT(*)                                            AS customers,
    ROUND(AVG(order_count), 1)                          AS avg_orders,
    ROUND(AVG(lifetime_revenue), 0)                     AS avg_lifetime_revenue,
    ROUND(AVG(active_months), 1)                        AS avg_active_months,
    ROUND(COUNT(*) * 100.0 /
          SUM(COUNT(*)) OVER (), 1)                     AS pct_of_customers,
    ROUND(SUM(lifetime_revenue) * 100.0 /
          SUM(SUM(lifetime_revenue)) OVER (), 1)        AS pct_of_revenue
FROM frequency_bands
GROUP BY frequency_band
ORDER BY frequency_band;


-- ── Q5: Top Products by Margin — RANK() OVER PARTITION ──────────
-- WHY: RANK() OVER (PARTITION BY category) gives rank within each
-- product category AND overall rank in the same query. This is the
-- difference between PARTITION (rank within group) and no partition
-- (rank across everything).
-- INTERVIEW TIP: "PARTITION BY is like GROUP BY for window functions
-- — it resets the rank counter for each category."

WITH product_sales AS (
    SELECT
        p.product_id,
        p.product_name,
        p.category,
        p.margin_pct,
        p.return_rate,
        COUNT(o.order_id)                           AS units_sold,
        ROUND(SUM(o.net_revenue), 0)                AS net_revenue,
        ROUND(SUM(o.net_margin), 0)                 AS net_margin,
        ROUND(SUM(o.is_returned) * 100.0
              / NULLIF(COUNT(o.order_id), 0), 1)    AS actual_return_rate
    FROM products p
    JOIN orders o ON p.product_id = o.product_id
    GROUP BY p.product_id, p.product_name,
             p.category, p.margin_pct, p.return_rate
)
SELECT
    product_id,
    category,
    units_sold,
    net_revenue,
    net_margin,
    actual_return_rate,
    ROUND(margin_pct * 100, 1)                              AS margin_pct,
    RANK() OVER (PARTITION BY category ORDER BY net_margin DESC) AS rank_in_category,
    RANK() OVER (ORDER BY net_margin DESC)                  AS overall_rank
FROM product_sales
ORDER BY net_margin DESC
LIMIT 20;


-- ── Q6: Return Rate Impact on Net Revenue ────────────────────────
-- WHY: Gross revenue tells you what customers spent. Net revenue tells
-- you what you kept. The gap is the cost of your return policy.
-- RANK() OVER shows which categories have the worst return problem.
-- INTERVIEW TIP: "Revenue lost to returns is often invisible in
-- top-line reporting — this query makes it explicit and rankable."

SELECT
    category,
    COUNT(order_id)                                     AS total_orders,
    ROUND(SUM(order_value), 0)                          AS gross_revenue,
    ROUND(SUM(net_revenue), 0)                          AS net_revenue,
    ROUND(SUM(gross_margin), 0)                         AS gross_margin,
    ROUND(SUM(net_margin), 0)                           AS net_margin,
    SUM(is_returned)                                    AS returns,
    ROUND(SUM(is_returned) * 100.0 / COUNT(order_id), 1) AS return_rate_pct,
    ROUND(SUM(order_value) - SUM(net_revenue), 0)       AS revenue_lost_to_returns,
    RANK() OVER (
        ORDER BY SUM(is_returned) * 1.0 / COUNT(order_id) DESC
    )                                                   AS return_rank
FROM orders
GROUP BY category
ORDER BY revenue_lost_to_returns DESC;


-- ── Q7: Campaign Conversion Funnel — Chained CTEs ────────────────
-- WHY: Each CTE isolates one stage of the funnel — sends, opens,
-- clicks, conversions. Chaining them with JOINs builds the full
-- funnel in one readable query. This is the standard way senior
-- analysts structure multi-step funnel analysis.
-- INTERVIEW TIP: "I chain CTEs when each step depends on the
-- previous — it's more readable than nested subqueries and easier
-- to debug because you can run each CTE independently."

WITH sends AS (
    SELECT campaign_type, COUNT(*) AS total_sends
    FROM campaigns
    GROUP BY campaign_type
),
opens AS (
    SELECT campaign_type, SUM(opened) AS total_opens
    FROM campaigns
    GROUP BY campaign_type
),
clicks AS (
    SELECT campaign_type, SUM(clicked) AS total_clicks
    FROM campaigns
    GROUP BY campaign_type
),
conversions AS (
    SELECT
        campaign_type,
        SUM(converted)                      AS total_conversions,
        ROUND(SUM(revenue_generated), 0)    AS revenue
    FROM campaigns
    GROUP BY campaign_type
)
SELECT
    s.campaign_type,
    s.total_sends,
    o.total_opens,
    ROUND(o.total_opens * 100.0 / s.total_sends, 1)         AS open_rate_pct,
    c.total_clicks,
    ROUND(c.total_clicks * 100.0 / s.total_sends, 1)        AS click_rate_pct,
    cv.total_conversions,
    ROUND(cv.total_conversions * 100.0 / s.total_sends, 1)  AS conversion_rate_pct,
    cv.revenue,
    ROUND(cv.revenue / NULLIF(cv.total_conversions, 0), 0)  AS revenue_per_conversion
FROM sends s
JOIN opens o        ON s.campaign_type = o.campaign_type
JOIN clicks c       ON s.campaign_type = c.campaign_type
JOIN conversions cv ON s.campaign_type = cv.campaign_type
ORDER BY conversion_rate_pct DESC;


-- ── Q8: RFM Customer Scoring — NTILE() Window Function ──────────
-- WHY: NTILE(5) divides customers into 5 equal buckets ranked by
-- recency, frequency, and monetary value. Combining the three scores
-- into named segments creates an actionable marketing audience list.
-- INTERVIEW TIP: "RFM is the industry-standard segmentation model
-- for e-commerce. NTILE() is the cleanest SQL implementation —
-- no hardcoded thresholds, it adapts to any dataset size."

WITH rfm_base AS (
    SELECT
        c.customer_id,
        c.acquisition_channel,
        c.segment,
        DATEDIFF('2024-03-31', MAX(o.order_date))   AS recency_days,
        COUNT(o.order_id)                            AS frequency,
        ROUND(SUM(o.net_revenue), 2)                 AS monetary
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.acquisition_channel, c.segment
),
rfm_scores AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days ASC)   AS r_score,
        NTILE(5) OVER (ORDER BY frequency DESC)     AS f_score,
        NTILE(5) OVER (ORDER BY monetary DESC)      AS m_score
    FROM rfm_base
),
rfm_segments AS (
    SELECT *,
        r_score + f_score + m_score AS rfm_total,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
            WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal Customers'
            WHEN r_score >= 4 AND f_score <= 2 THEN 'New Customers'
            WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
            WHEN r_score <= 2 AND f_score <= 2 THEN 'Lost Customers'
            ELSE                                    'Potential Loyalists'
        END AS rfm_segment
    FROM rfm_scores
)
SELECT
    rfm_segment,
    COUNT(*)                                                AS customers,
    ROUND(AVG(recency_days), 0)                             AS avg_recency_days,
    ROUND(AVG(frequency), 1)                                AS avg_orders,
    ROUND(AVG(monetary), 0)                                 AS avg_revenue,
    ROUND(SUM(monetary), 0)                                 AS total_revenue,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)      AS pct_customers
FROM rfm_segments
GROUP BY rfm_segment
ORDER BY avg_revenue DESC;


-- ── Q9: First vs Repeat Purchase — ROW_NUMBER() ──────────────────
-- WHY: ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY date)
-- numbers each customer's orders chronologically. Row 1 = first
-- purchase, everything else = repeat. This splits revenue into
-- acquisition vs retention without any date hardcoding.
-- INTERVIEW TIP: "ROW_NUMBER() is how I identify first purchases
-- without knowing the exact date — it's date-agnostic and works
-- on any dataset."

WITH ranked_orders AS (
    SELECT
        order_id,
        customer_id,
        order_date,
        order_month,
        net_revenue,
        net_margin,
        acquisition_channel,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY order_date ASC
        ) AS order_rank
    FROM orders
),
order_type AS (
    SELECT *,
        CASE
            WHEN order_rank = 1 THEN 'First Purchase'
            ELSE                    'Repeat Purchase'
        END AS purchase_type
    FROM ranked_orders
)
SELECT
    purchase_type,
    acquisition_channel,
    COUNT(*)                                                AS orders,
    ROUND(AVG(net_revenue), 0)                              AS avg_order_value,
    ROUND(SUM(net_revenue), 0)                              AS total_revenue,
    ROUND(AVG(net_margin), 0)                               AS avg_margin,
    ROUND(
        SUM(net_revenue) * 100.0
        / SUM(SUM(net_revenue)) OVER (PARTITION BY acquisition_channel)
    , 1)                                                    AS pct_of_channel_revenue
FROM order_type
GROUP BY purchase_type, acquisition_channel
ORDER BY acquisition_channel, purchase_type;


-- ── Q10: Channel Attribution — DENSE_RANK() ──────────────────────
-- WHY: DENSE_RANK() across 4 different dimensions simultaneously
-- (revenue per customer, quality/return rate, volume, margin) gives
-- a multi-dimensional channel scorecard in one query.
-- The key insight: Referral ranks 1st on 3 of 4 dimensions but
-- gets the least investment — the strongest budget reallocation
-- argument in the entire project.
-- INTERVIEW TIP: "DENSE_RANK() vs RANK() — DENSE_RANK() doesn't
-- skip numbers after ties. For a 6-channel comparison with no ties
-- it doesn't matter, but I use DENSE_RANK() by default because
-- it's safer with larger datasets."

WITH channel_summary AS (
    SELECT
        c.acquisition_channel,
        COUNT(DISTINCT c.customer_id)               AS customers,
        COUNT(o.order_id)                           AS total_orders,
        ROUND(SUM(o.net_revenue), 0)                AS total_net_revenue,
        ROUND(SUM(o.net_margin), 0)                 AS total_net_margin,
        ROUND(AVG(o.net_revenue), 0)                AS avg_order_value,
        ROUND(SUM(o.is_returned) * 100.0
              / COUNT(o.order_id), 1)               AS return_rate_pct,
        ROUND(SUM(o.net_revenue)
              / COUNT(DISTINCT c.customer_id), 0)   AS revenue_per_customer,
        ROUND(SUM(o.net_margin)
              / COUNT(DISTINCT c.customer_id), 0)   AS margin_per_customer
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY c.acquisition_channel
)
SELECT
    acquisition_channel,
    customers,
    total_orders,
    total_net_revenue,
    total_net_margin,
    return_rate_pct,
    revenue_per_customer,
    margin_per_customer,
    DENSE_RANK() OVER (ORDER BY revenue_per_customer DESC) AS rev_per_cust_rank,
    DENSE_RANK() OVER (ORDER BY return_rate_pct ASC)       AS quality_rank,
    DENSE_RANK() OVER (ORDER BY total_net_revenue DESC)    AS volume_rank,
    DENSE_RANK() OVER (ORDER BY margin_per_customer DESC)  AS margin_rank
FROM channel_summary
ORDER BY revenue_per_customer DESC;
